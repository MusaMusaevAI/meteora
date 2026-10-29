import Foundation
import AVFoundation
import ActivityKit
import SwiftUI
import UIKit

/// Records a meeting from the microphone into AAC .m4a (48 kHz mono,
/// 64 kbit/s ≈ 29 MB per hour). Keeps recording with the screen locked or
/// another app in front (background audio), shows a Live Activity on the
/// lock screen and in the Dynamic Island, and survives interruptions
/// (a call pauses it; it resumes when the call ends).
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    enum State: Equatable { case idle, recording, paused, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var fileURL: URL?
    /// The finished file, until the list picks it up.
    @Published var finished: Recording?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastActivityUpdate = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false

    var isActive: Bool { state == .recording || state == .paused }

    private override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: RecordingControl.stop, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.stop() } }
        })
        observers.append(nc.addObserver(forName: RecordingControl.togglePause, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePause() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            MainActor.assumeIsolated { self?.interruption(type, shouldResume: opts?.contains(.shouldResume) ?? false) }
        })
    }

    // MARK: Controls

    func start() async {
        guard !isActive else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            state = .failed("Нет доступа к микрофону. Разрешите его в Настройках → Meteora.")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            state = .failed("Не удалось включить микрофон: \(error.localizedDescription)")
            return
        }
        let name = Self.fileName()
        let shared = SharedFolder.shared
        let dir = (shared.saveRecordingsHere ? shared.url : nil) ?? Library.documents
        let url = Library.uniqueURL(in: dir, name: name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw RecordingError.couldNotStart }
            recorder = r
        } catch {
            state = .failed("Не удалось начать запись: \(error.localizedDescription)")
            return
        }
        fileURL = url
        elapsed = 0
        state = .recording
        UIApplication.shared.isIdleTimerDisabled = false
        startMeter()
        startActivity(title: url.deletingPathExtension().lastPathComponent)
        Haptics.tap()
    }

    func togglePause() {
        guard let r = recorder else { return }
        switch state {
        case .recording:
            r.pause()
            state = .paused
        case .paused:
            try? AVAudioSession.sharedInstance().setActive(true)
            r.record()
            state = .recording
        default: return
        }
        updateActivity(force: true)
        Haptics.tap()
    }

    func stop() async {
        guard let r = recorder, let url = fileURL else { return }
        r.stop()
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        state = .idle
        level = 0
        await endActivity()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let shared = SharedFolder.shared
        let place: Recording.Place = (shared.url.map { url.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL } ?? false)
            ? .shared : .local
        finished = await Library.shared.add(at: url, place: place, path: url.lastPathComponent)
        Haptics.success()
    }

    /// Deletes the file being recorded (the «Удалить» choice).
    func discard() async {
        guard let r = recorder, let url = fileURL else { return }
        r.stop()
        r.deleteRecording()
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        state = .idle
        level = 0
        try? FileManager.default.removeItem(at: url)
        await endActivity()
    }

    // MARK: Meter and timer

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = r.currentTime
        if state == .recording {
            r.updateMeters()
            let db = Double(r.averagePower(forChannel: 0))
            let v = max(0, min(1, (db + 50) / 45))
            level = level * 0.6 + v * 0.4
        } else {
            level = 0
        }
        updateActivity(force: false)
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            if state == .recording {
                state = .paused
                resumeAfterInterruption = true
                updateActivity(force: true)
            }
        case .ended:
            if resumeAfterInterruption, shouldResume, state == .paused {
                try? AVAudioSession.sharedInstance().setActive(true)
                recorder?.record()
                state = .recording
                updateActivity(force: true)
            }
            resumeAfterInterruption = false
        default: break
        }
    }

    static func fileName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yy HH-mm-ss"
        return "Запись \(f.string(from: date)).m4a"
    }

    enum RecordingError: Error { case couldNotStart }

    // MARK: Live Activity

    private var activityState: RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            startedAt: Date().addingTimeInterval(-elapsed),
            pausedElapsed: state == .paused ? elapsed : nil,
            level: level)
    }

    private func startActivity(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: activityState, staleDate: nil)
        activity = try? Activity.request(attributes: RecordingActivityAttributes(title: title), content: content)
    }

    /// The timer runs by itself on the lock screen; updates carry only the
    /// meter and pause state, at most every 1.5 s.
    private func updateActivity(force: Bool) {
        guard let activity else { return }
        guard force || Date().timeIntervalSince(lastActivityUpdate) > 1.5 else { return }
        lastActivityUpdate = Date()
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endActivity() async {
        guard let activity else { return }
        let content = ActivityContent(state: activityState, staleDate: nil)
        await activity.end(content, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
