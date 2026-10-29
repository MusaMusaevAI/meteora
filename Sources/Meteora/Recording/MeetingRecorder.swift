import Foundation
import AppKit
import AVFoundation

/// Records a meeting on this Mac: the microphone, what the Mac plays, or
/// both mixed into one Opus track in a WebM file.
///
/// The app wires `onFinished` to open the file and transcribe it.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    enum State: Equatable {
        case idle
        /// Asking for permissions, the folder, starting devices.
        case starting
        case recording
        case paused
        /// Writing the end of the file.
        case finishing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Recorded time, pauses excluded.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Input level for the meter, 0…1.
    @Published private(set) var level: Float = 0
    /// What to record; remembered between launches.
    @Published var source: RecordingSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Keys.source) }
    }
    /// Chosen microphone (`AVCaptureDevice.uniqueID`); nil = the system default.
    @Published var deviceID: String? {
        didSet { UserDefaults.standard.set(deviceID, forKey: Keys.device) }
    }
    /// Something the user should know right now (a device went away…).
    @Published private(set) var notice: String?
    /// A soft hint: system audio has been silent for a while.
    @Published private(set) var systemAudioHint: String?
    @Published private(set) var folderName: String?
    /// The file being written.
    @Published private(set) var fileURL: URL?

    let catalog = AudioInputCatalog()

    /// Called with the finished file (WebM, or M4A if Opus is unavailable).
    var onFinished: ((URL) -> Void)?

    var isActive: Bool {
        switch state {
        case .starting, .recording, .paused, .finishing: return true
        case .idle, .failed: return false
        }
    }

    /// System audio needs macOS 14.2; on older systems only the microphone.
    var availableSources: [RecordingSource] {
        AudioInputCatalog.systemAudioAvailable ? RecordingSource.allCases : [.microphone]
    }

    /// Name of the microphone in use (or that will be used).
    var microphoneName: String { activeMicrophoneName ?? catalog.name(of: deviceID) }

    private enum Keys {
        static let source = "recorder.source"
        static let device = "recorder.deviceID"
    }

    private var engine: RecordingEngine?
    private var activeSource: RecordingSource = .microphone
    private var activeMicrophoneID: String?
    private var activeMicrophoneName: String?
    private var pendingFailure: String?
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?
    private var timer: Timer?
    private var statusItem: RecordingStatusItem?
    private var terminationObserver: NSObjectProtocol?

    init() {
        let saved = UserDefaults.standard.string(forKey: Keys.source).flatMap(RecordingSource.init(rawValue:)) ?? .microphone
        source = AudioInputCatalog.systemAudioAvailable ? saved : .microphone
        deviceID = UserDefaults.standard.string(forKey: Keys.device)
        folderName = RecordingFolder.displayName
        catalog.onDisconnect = { [weak self] id in self?.deviceDisconnected(id) }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.finishForTermination() }
        }
    }

    // MARK: Controls

    func start() async {
        guard !isActive else { return }
        notice = nil
        systemAudioHint = nil
        let source = availableSources.contains(self.source) ? self.source : .microphone
        state = .starting

        // 1. Microphone permission (the system asks once).
        var micID: String?
        if source.usesMicrophone {
            guard await Self.microphoneAccess() else {
                state = .failed("Нет доступа к микрофону. Разрешите его: Системные настройки → Конфиденциальность и безопасность → Микрофон.")
                return
            }
            catalog.refresh()
            if let chosen = deviceID, catalog.isConnected(chosen) {
                micID = chosen
            } else {
                if let chosen = deviceID {
                    notice = "«\(catalog.device(chosen)?.name ?? "Выбранный микрофон")» не подключён — используется микрофон по умолчанию."
                }
                micID = catalog.defaultDeviceID
            }
            guard micID != nil else {
                state = .failed(RecorderError.microphoneNotFound.localizedDescription)
                return
            }
        }

        // 2. Folder (asked once) and the file.
        guard let folder = RecordingFolder.ensure() else {
            state = .idle
            return
        }
        folderName = RecordingFolder.displayName
        let useOpus = OpusWebMSink.isEncoderAvailable
        if !useOpus { recorderLog.error("Opus encoder unavailable, falling back to AAC in .m4a") }
        let url = RecordingFolder.newFileURL(in: folder, fileExtension: useOpus ? "webm" : "m4a")
        let sink: RecordingSink
        do {
            if useOpus {
                sink = try OpusWebMSink(url: url)
            } else {
                sink = try AACFileSink(url: url)
            }
        } catch {
            RecordingFolder.forget()
            folderName = nil
            state = .failed("Не удалось создать файл в выбранной папке. Выберите папку заново. (\(error.localizedDescription))")
            return
        }

        // 3. Devices.
        let microphoneID = micID
        let engine = RecordingEngine(source: source, sink: sink)
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            engine.start(microphoneID: microphoneID) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result {
            _ = await withCheckedContinuation { continuation in
                engine.stop { continuation.resume(returning: $0) }
            }
            try? FileManager.default.removeItem(at: url)
            state = .failed(error.localizedDescription)
            return
        }

        self.engine = engine
        activeSource = source
        activeMicrophoneID = microphoneID
        activeMicrophoneName = microphoneID.flatMap { catalog.device($0)?.name }
        pendingFailure = nil
        fileURL = url
        accumulated = 0
        elapsed = 0
        runningSince = Date()
        state = .recording
        recorderLog.info("recording \(source.rawValue, privacy: .public) → \(url.lastPathComponent, privacy: .public), \(sink.formatName, privacy: .public)")
        startTimer()
        updateStatusItem()
    }

    func pause() {
        guard state == .recording, let engine else { return }
        if let since = runningSince { accumulated += Date().timeIntervalSince(since) }
        runningSince = nil
        elapsed = accumulated
        level = 0
        engine.pause()
        state = .paused
        updateStatusItem()
    }

    func resume() {
        guard state == .paused, let engine else { return }
        // The user may have picked another microphone while paused.
        let micID: String? = activeSource.usesMicrophone
            ? (deviceID.flatMap { catalog.isConnected($0) ? $0 : nil } ?? catalog.defaultDeviceID)
            : nil
        if activeSource.usesMicrophone, micID == nil {
            notice = RecorderError.microphoneNotFound.localizedDescription
            return
        }
        notice = nil
        engine.resume(microphoneID: micID) { [weak self] result in
            Task { @MainActor in self?.didResume(result, microphoneID: micID) }
        }
    }

    func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
    }

    func stop() {
        guard state == .recording || state == .paused, let engine else { return }
        if let since = runningSince { accumulated += Date().timeIntervalSince(since) }
        runningSince = nil
        elapsed = accumulated
        level = 0
        state = .finishing
        updateStatusItem()
        engine.stop { [weak self] result in
            Task { @MainActor in self?.didFinish(result) }
        }
    }

    /// Lets the user pick another folder.
    func chooseFolder() {
        if RecordingFolder.choose() != nil { folderName = RecordingFolder.displayName }
    }

    /// Clears a failure so the panel shows the start screen again.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: Engine callbacks

    private func didResume(_ result: Result<Void, Error>, microphoneID: String?) {
        guard state == .paused else { return }
        switch result {
        case .success:
            activeMicrophoneID = microphoneID
            activeMicrophoneName = microphoneID.flatMap { catalog.device($0)?.name }
            runningSince = Date()
            state = .recording
        case .failure(let error):
            notice = error.localizedDescription + " Выберите другой микрофон и продолжите."
        }
        updateStatusItem()
    }

    private func didFinish(_ result: Result<URL, Error>) {
        timer?.invalidate()
        timer = nil
        engine = nil
        activeMicrophoneID = nil
        activeMicrophoneName = nil
        level = 0
        systemAudioHint = nil
        switch result {
        case .success(let url):
            if let pendingFailure {
                // Writing broke off (e.g. the disk is full); what was written
                // before that is still a readable file.
                state = .failed(pendingFailure + " Записанное до этого момента сохранено.")
            } else {
                state = .idle
                notice = nil
            }
            pendingFailure = nil
            recorderLog.info("recording finished: \(url.lastPathComponent, privacy: .public), \(self.elapsed) s")
            updateStatusItem()
            onFinished?(url)
        case .failure(let error):
            state = .failed(error.localizedDescription)
            updateStatusItem()
        }
    }

    private func handle(_ event: RecordingEvent) {
        switch event {
        case .level(let value):
            if state == .recording { level = value }
        case .systemSilent(let silent):
            systemAudioHint = silent
                ? "Звук Mac пока не слышен. Если во встрече говорят, проверьте доступ: Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука."
                : nil
        case .microphoneFailed(let message):
            microphoneLost("Микрофон перестал отвечать (\(message)).")
        case .failed(let message):
            pendingFailure = message
            stop()
        }
    }

    private func deviceDisconnected(_ id: String) {
        guard isActive, activeSource.usesMicrophone, id == activeMicrophoneID else { return }
        microphoneLost("Микрофон «\(activeMicrophoneName ?? "выбранный")» отключился.")
    }

    private func microphoneLost(_ message: String) {
        guard state == .recording || state == .paused else { return }
        if state == .recording { pause() }
        notice = message + " Запись на паузе: выберите другой микрофон и нажмите «Продолжить»."
    }

    /// On quit: close the file properly (it would stay readable anyway).
    private func finishForTermination() {
        guard let engine, state == .recording || state == .paused || state == .finishing else { return }
        _ = engine.stopAndWait()
    }

    // MARK: Time and status item

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let since = runningSince else { return }
        elapsed = accumulated + Date().timeIntervalSince(since)
        statusItem?.update()
    }

    private func updateStatusItem() {
        if isActive {
            if statusItem == nil { statusItem = RecordingStatusItem(recorder: self) }
            statusItem?.update()
        } else {
            statusItem?.remove()
            statusItem = nil
        }
    }

    // MARK: Permissions

    static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// «12:34» or «1:02:03».
enum RecordingTime {
    static func string(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// For VoiceOver: «12 минут 34 секунды».
    static func spoken(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        var parts: [String] = []
        if s >= 3600 { parts.append(ru(s / 3600, "час", "часа", "часов")) }
        parts.append(ru((s % 3600) / 60, "минута", "минуты", "минут"))
        parts.append(ru(s % 60, "секунда", "секунды", "секунд"))
        return parts.joined(separator: " ")
    }
}
