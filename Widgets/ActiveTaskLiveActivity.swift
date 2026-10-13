import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The active task on the Lock Screen and in the Dynamic Island, with Park et and Bitti.
struct ActiveTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ActiveTaskAttributes.self) { context in
            LockScreenActivityView(taskID: context.attributes.taskID, state: context.state)
                .padding(16)
                .widgetURL(PickUpLink.now)
        } dynamicIsland: { context in
            let state = context.state
            let tint = AreaPalette.color(state.areaColor)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.areaSymbol ?? "bookmark")
                        .font(.title3)
                        .foregroundStyle(tint)
                        .accessibilityLabel(state.areaName ?? "Alan yok")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let next = state.nextStep {
                            Text("Sıradaki: \(next)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ActivityButtons(taskID: context.attributes.taskID)
                    }
                }
            } compactLeading: {
                Image(systemName: state.areaSymbol ?? "bookmark")
                    .foregroundStyle(tint)
                    .accessibilityLabel(state.title)
            } compactTrailing: {
                Text(state.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: state.areaSymbol ?? "bookmark")
                    .foregroundStyle(tint)
                    .accessibilityLabel(state.title)
            }
            .widgetURL(PickUpLink.now)
        }
    }
}

private struct LockScreenActivityView: View {
    let taskID: String
    let state: ActiveTaskAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(state.areaName ?? "Şimdi", systemImage: state.areaSymbol ?? "bookmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AreaPalette.color(state.areaColor))
                    .lineLimit(1)
                Spacer()
                Text(state.startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90, alignment: .trailing)
                    .accessibilityLabel(Text("Başlayalı \(state.startedAt, style: .relative)"))
            }
            Text(state.title)
                .font(.headline)
                .lineLimit(2)
            if let next = state.nextStep {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(next)
                        .lineLimit(1)
                    if state.stepsTotal > 0 {
                        Spacer(minLength: 4)
                        Text("\(state.stepsDone)/\(state.stepsTotal)")
                            .monospacedDigit()
                            .accessibilityLabel("\(state.stepsTotal) adımdan \(state.stepsDone) tanesi bitti")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sıradaki adım: \(next)")
            }
            ActivityButtons(taskID: taskID)
        }
    }
}

/// Park et opens the app to ask "nerede kaldın?"; Bitti completes the task in place.
private struct ActivityButtons: View {
    let taskID: String

    var body: some View {
        HStack(spacing: 10) {
            Link(destination: PickUpLink.park) {
                Label("Park et", systemImage: "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.background)
                    .background(Color.primary, in: Capsule())
            }
            Button(intent: CompleteTaskIntent(taskID: taskID)) {
                Label("Bitti", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(Color.primary)
        }
    }
}
