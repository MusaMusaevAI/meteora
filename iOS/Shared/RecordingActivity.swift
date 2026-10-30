import ActivityKit
import AppIntents
import Foundation
import SwiftUI

/// Live Activity of a recording: lock screen and Dynamic Island. Shared by
/// the app (starts and updates it) and the widget extension (draws it).
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Running: the timer counts from here (pauses already subtracted).
        var startedAt: Date
        /// Paused: the recorded time, frozen.
        var pausedElapsed: TimeInterval?
        /// Input level 0…1, a coarse meter (updates are rate-limited by iOS).
        var level: Double

        var isPaused: Bool { pausedElapsed != nil }
    }

    /// File name shown under the timer.
    var title: String
}

/// Buttons in the Live Activity. A LiveActivityIntent runs in the app's own
/// process, where the recorder listens for these notifications; in the
/// widget process nothing listens, so nothing happens there.
enum RecordingControl {
    static let stop = Notification.Name("com.musamusaev.meteora.recording.stop")
    static let togglePause = Notification.Name("com.musamusaev.meteora.recording.togglePause")
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Остановить запись"
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: RecordingControl.stop, object: nil) }
        return .result()
    }
}

struct TogglePauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Пауза или продолжить"
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: RecordingControl.togglePause, object: nil) }
        return .result()
    }
}

// MARK: - Views (also rendered inside the app: onboarding and self-test)

enum ActivityPalette {
    static let accent = Color(red: 0x9D / 255, green: 0xB8 / 255, blue: 0xD3 / 255)
    static let record = Color(red: 0xE3 / 255, green: 0x6B / 255, blue: 0x5A / 255)
    static let nacre = [0xBCD4EC, 0xD6CDEE, 0xEBC6D6, 0xF1E2CC].map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }
}

/// «00:12:34» that ticks by itself (no updates needed while running).
struct ActivityTimer: View {
    var state: RecordingActivityAttributes.ContentState
    var body: some View {
        if let frozen = state.pausedElapsed {
            Text(Self.format(frozen)).monospacedDigit()
        } else {
            Text(timerInterval: state.startedAt ... Date.distantFuture, countsDown: false).monospacedDigit()
        }
    }
    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The red dot (pulsing while recording) or a pause glyph.
struct RecordingDot: View {
    var paused: Bool
    var size: CGFloat = 10
    var body: some View {
        if paused {
            Image(systemName: "pause.fill").font(.system(size: size, weight: .bold)).foregroundStyle(.secondary)
        } else {
            Circle().fill(ActivityPalette.record).frame(width: size, height: size)
                .shadow(color: ActivityPalette.record.opacity(0.7), radius: size * 0.4)
        }
    }
}

/// A short level meter: five bars.
struct LevelBars: View {
    var level: Double
    var paused: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let h = max(0.18, min(1, level * 1.6 - Double(abs(i - 2)) * 0.18))
                Capsule()
                    .fill(paused ? Color.secondary.opacity(0.5) : ActivityPalette.accent)
                    .frame(width: 3, height: 18 * (paused ? 0.2 : h))
            }
        }
        .frame(height: 18)
    }
}

/// Lock screen / banner presentation.
struct RecordingLockScreenView: View {
    var title: String
    var state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: ActivityPalette.nacre, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(0.35)
                RecordingDot(paused: state.isPaused, size: 12)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.isPaused ? "Пауза" : "Идёт запись")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                ActivityTimer(state: state).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(title).privacySensitive().font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            LevelBars(level: state.level, paused: state.isPaused)
            VStack(spacing: 8) {
                Button(intent: TogglePauseRecordingIntent()) {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(Color.white.opacity(0.14)))
                Button(intent: StopRecordingIntent()) {
                    Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(ActivityPalette.record))
            }
        }
        .padding(16)
    }
}
