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
    func sync(_ tasks: [TaskItem]) -> [(TaskItem, (inout TaskItem) -> Void)] {
        guard let calendar = pickupCalendar() else { return [] }
        var edits: [(TaskItem, (inout TaskItem) -> Void)] = []
        var changed = false

        for task in tasks {
            let existing = task.calendarEventId.flatMap { eventStore.event(withIdentifier: $0) }
            guard task.status.isOpen, task.deletedAt == nil, let due = task.dueAt else {
                if let existing {
                    try? eventStore.remove(existing, span: .thisEvent, commit: false)
                    changed = true
                }
                if task.calendarEventId != nil, task.deletedAt == nil {
                    edits.append((task, { $0.calendarEventId = nil }))
                }
                continue
            }

            if let event = existing {
                let movedInCalendar = abs(event.startDate.timeIntervalSince(due)) > 59
                    && (event.lastModifiedDate ?? .distantPast) > task.updatedAt
                if movedInCalendar {
                    let start = event.startDate ?? due
                    edits.append((task, { $0.dueAt = start }))
                } else if abs(event.startDate.timeIntervalSince(due)) > 59 || event.title != task.title {
                    event.title = task.title
                    event.startDate = due
                    event.endDate = due.addingTimeInterval(Self.eventLength)
                    try? eventStore.save(event, span: .thisEvent, commit: false)
                    changed = true
                }
            } else {
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = task.title
                event.startDate = due
                event.endDate = due.addingTimeInterval(Self.eventLength)
                if (try? eventStore.save(event, span: .thisEvent, commit: false)) != nil {
                    changed = true
                    let id = event.eventIdentifier
                    edits.append((task, { $0.calendarEventId = id }))
                }
            }
        }
        if changed { try? eventStore.commit() }
        return edits
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
