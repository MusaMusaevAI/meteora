import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MeteoraWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// Recording on the lock screen and in the Dynamic Island.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(title: context.attributes.title, state: context.state)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.10).opacity(0.86))
                .activitySystemActionForegroundColor(ActivityPalette.accent)
                .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        RecordingDot(paused: context.state.isPaused, size: 10)
                        Text(context.state.isPaused ? "Пауза" : "Запись")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityTimer(state: context.state)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .frame(maxWidth: 110, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        LevelBars(level: context.state.level, paused: context.state.isPaused)
                        Text(context.attributes.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button(intent: TogglePauseRecordingIntent()) {
                            Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                        Button(intent: StopRecordingIntent()) {
                            Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .background(Circle().fill(ActivityPalette.record))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                RecordingDot(paused: context.state.isPaused, size: 9)
                    .padding(.leading, 2)
            } compactTrailing: {
                ActivityTimer(state: context.state)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: 52)
                    .foregroundStyle(ActivityPalette.accent)
            } minimal: {
                RecordingDot(paused: context.state.isPaused, size: 9)
            }
            .keylineTint(ActivityPalette.record)
        }
    }
}
