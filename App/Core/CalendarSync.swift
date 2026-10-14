import EventKit
import UIKit

/// Two-way link with Apple Calendar.
/// - Open tasks with a date get an event in a dedicated "PickUp" calendar.
/// - Moving that event in Calendar moves the task's date; editing the task moves the event.
/// - Events from the person's other calendars are shown in "Bugün".
@MainActor
final class CalendarSync {
    static let shared = CalendarSync()

    let eventStore = EKEventStore()
    private let calendarKey = "pickup.calendarID"
    private static let eventLength: TimeInterval = 30 * 60

    /// Called when Calendar data changes outside the app.
    var onExternalChange: (() -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
    }

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        if granted { eventStore.reset() }
        return granted
    }

    /// The "PickUp" calendar, created in the default account (usually iCloud) on first use.
    func pickupCalendar() -> EKCalendar? {
        guard isAuthorized else { return nil }
        if let id = UserDefaults.standard.string(forKey: calendarKey),
           let calendar = eventStore.calendar(withIdentifier: id) {
            return calendar
        }
        if let existing = eventStore.calendars(for: .event)
            .first(where: { $0.title == "PickUp" && $0.allowsContentModifications }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: calendarKey)
            return existing
        }
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "PickUp"
        calendar.cgColor = UIColor.systemIndigo.cgColor
        calendar.source = eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first { $0.sourceType == .local }
        guard calendar.source != nil else { return nil }
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarKey)
            return calendar
        } catch {
            return nil
        }
    }

    /// Brings events in line with tasks. Returns task edits to apply (new event ids, or a date
    /// the person changed in Calendar).
    ///
    /// Every event carries its task in `url` (pickup://task/<id>), so a lost event id never
    /// leads to a second event; extra copies of a task's event are removed. Running it again
    /// without task changes changes nothing, which also stops the loop through
    /// `EKEventStoreChanged`.
    func sync(_ tasks: [TaskItem]) -> [(TaskItem, (inout TaskItem) -> Void)] {
        // An empty list means the tasks are not loaded yet, not that every event is stale.
        guard !tasks.isEmpty, let calendar = pickupCalendar() else { return [] }
        var edits: [(TaskItem, (inout TaskItem) -> Void)] = []
        var changed = false

        // Every PickUp event from a year back to two years ahead (EventKit caps the span at
        // four years), grouped by task.
        let now = Date.now
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-365 * 86_400),
            end: now.addingTimeInterval(2 * 365 * 86_400),
            calendars: [calendar]
        )
        var byTask: [String: [EKEvent]] = [:]
        var unlinked: [EKEvent] = []
        for event in eventStore.events(matching: predicate) {
            if let id = Self.taskID(of: event) {
                byTask[id, default: []].append(event)
            } else {
                unlinked.append(event)
            }
        }

        func remove(_ event: EKEvent) {
            if (try? eventStore.remove(event, span: .thisEvent, commit: false)) != nil { changed = true }
        }

        for task in tasks {
            var candidates = byTask.removeValue(forKey: task.id) ?? []
            if let id = task.calendarEventId, !candidates.contains(where: { $0.eventIdentifier == id }),
               let byID = eventStore.event(withIdentifier: id), byID.calendar?.calendarIdentifier == calendar.calendarIdentifier {
                candidates.append(byID)
                unlinked.removeAll { $0.eventIdentifier == id }
            }
            // Events made before the link existed: same title, no link (the old duplicates).
            let legacy = unlinked.filter { $0.title == task.title }
            unlinked.removeAll { $0.title == task.title }
            candidates += legacy

            guard task.status.isOpen, task.deletedAt == nil, let due = task.dueAt else {
                candidates.forEach(remove)
                if task.calendarEventId != nil, task.deletedAt == nil {
                    edits.append((task, { $0.calendarEventId = nil }))
                }
                continue
            }

            // Keep the event the task points at (or the first), drop the rest.
            let keep = candidates.first { $0.eventIdentifier == task.calendarEventId } ?? candidates.first
            for event in candidates where event !== keep { remove(event) }

            if let event = keep {
                let movedInCalendar = abs(event.startDate.timeIntervalSince(due)) > 59
                    && (event.lastModifiedDate ?? .distantPast) > task.updatedAt
                if movedInCalendar {
                    let start = event.startDate ?? due
                    edits.append((task, { $0.dueAt = start }))
                } else if abs(event.startDate.timeIntervalSince(due)) > 59 || event.title != task.title
                            || Self.taskID(of: event) != task.id {
                    event.title = task.title
                    event.startDate = due
                    event.endDate = due.addingTimeInterval(Self.eventLength)
                    event.url = Self.link(task.id)
                    if (try? eventStore.save(event, span: .thisEvent, commit: false)) != nil { changed = true }
                }
                if task.calendarEventId != event.eventIdentifier, let id = event.eventIdentifier {
                    edits.append((task, { $0.calendarEventId = id }))
                }
            } else {
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = task.title
                event.startDate = due
                event.endDate = due.addingTimeInterval(Self.eventLength)
                event.url = Self.link(task.id)
                if (try? eventStore.save(event, span: .thisEvent, commit: false)) != nil {
                    changed = true
                    if let id = event.eventIdentifier {
                        edits.append((task, { $0.calendarEventId = id }))
                    }
                }
            }
        }

        // Linked events whose task no longer exists in the app.
        for events in byTask.values { events.forEach(remove) }

        if changed { try? eventStore.commit() }
        return edits
    }

    private static func link(_ taskID: String) -> URL? {
        URL(string: "pickup://task/\(taskID)")
    }

    private static func taskID(of event: EKEvent) -> String? {
        guard let url = event.url, url.scheme == "pickup", url.host == "task" else { return nil }
        return url.pathComponents.dropFirst().first
    }

    /// Removes a deleted task's event.
    func removeEvent(_ identifier: String?) {
        guard isAuthorized, let identifier, let event = eventStore.event(withIdentifier: identifier) else { return }
        try? eventStore.remove(event, span: .thisEvent, commit: true)
    }

    /// Events on `day` from every calendar except PickUp's own (those are tasks already).
    func events(on day: Date) -> [EKEvent] {
        events(on: day, days: 1)
    }

    /// Events in the `days` days starting at `day`, from every calendar except PickUp's own.
    func events(on day: Date, days: Int) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let ownID = UserDefaults.standard.string(forKey: calendarKey)
        let calendars = eventStore.calendars(for: .event).filter { $0.calendarIdentifier != ownID }
        guard !calendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
}
