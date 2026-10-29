import Foundation
import AVFoundation
import MeteoraCore
import os

/// What to record.
enum RecordingSource: String, CaseIterable, Identifiable, Sendable {
    case microphone, system, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return "Микрофон"
        case .system: return "Звук Mac"
        case .both: return "Оба"
        }
    }
    var usesMicrophone: Bool { self != .system }
    var usesSystemAudio: Bool { self != .microphone }
}

enum RecorderError: LocalizedError {
    case microphoneNotFound
    case microphoneUnavailable(String)
    case systemAudioUnsupported
    case systemAudio(OSStatus)
    case encoderUnavailable
    case encoding(String)
    case folder(String)

    var errorDescription: String? {
        switch self {
        case .microphoneNotFound:
            return "Микрофон не найден. Подключите его или выберите другой."
        case .microphoneUnavailable(let name):
            return "Не удалось включить «\(name)». Возможно, он занят другим приложением или отключился."
        case .systemAudioUnsupported:
            return "Запись звука Mac доступна в macOS 14.2 и новее."
        case .systemAudio(let status):
            return "Не удалось подключиться к звуку Mac (код \(status))."
        case .encoderUnavailable:
            return "На этом Mac недоступен кодировщик звука."
        case .encoding(let s):
            return "Не удалось записать звук: \(s)"
        case .folder(let s):
            return "Не удалось создать файл записи: \(s)"
        }
    }
}

/// Events from the engine to the UI. Delivered on background queues.
enum RecordingEvent: Sendable {
    /// Meter value 0…1 (−60…0 dBFS), about 16 times a second.
    case level(Float)
    /// True after ~10 s of digital silence from the system-audio tap — either
    /// nothing is playing, or access was not granted.
    case systemSilent(Bool)
    case microphoneFailed(String)
    case failed(String)
}

let recorderLog = Logger(subsystem: "com.musamusaev.meteora", category: "recorder")

// MARK: - Input conversion

/// Converts whatever a source delivers (any rate, channels, layout) to the
/// pipeline's 48 kHz mono Float32. Runs on the processing queue.
final class InputConverter {
    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var output: AVAudioPCMBuffer

    init?(from format: AVAudioFormat) {
        inputFormat = format
        let target = RecordingFormat.pcm
        if format.commonFormat == .pcmFormatFloat32, format.sampleRate == target.sampleRate, format.channelCount == 1 {
            converter = nil // already in shape
        } else {
            guard let c = AVAudioConverter(from: format, to: target) else { return nil }
            c.downmix = true // mix all channels instead of keeping the first
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        }
        output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8_192)!
    }

    /// Converts one buffer and passes the result (possibly in pieces) to `body`.
    func convert(_ buffer: AVAudioPCMBuffer, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        guard buffer.frameLength > 0 else { return }
        guard let converter else {
            body(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            return
        }
        let needed = AVAudioFrameCount(Double(buffer.frameLength) * RecordingFormat.sampleRate / inputFormat.sampleRate) + 256
        if output.frameCapacity < needed {
            output = AVAudioPCMBuffer(pcmFormat: RecordingFormat.pcm, frameCapacity: needed)!
        }
        run(converter, input: buffer, final: false, body)
    }

    /// Pushes out what the resampler still holds (end of recording).
    func flush(_ body: (UnsafeBufferPointer<Float>) -> Void) {
        guard let converter else { return }
        run(converter, input: nil, final: true, body)
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, final: Bool,
                     _ body: (UnsafeBufferPointer<Float>) -> Void) {
        var given = false
        while true {
            output.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: output, error: &err) { _, outStatus in
                if let input, !given {
                    given = true
                    outStatus.pointee = .haveData
                    return input
                }
                outStatus.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                recorderLog.error("conversion failed: \(err?.localizedDescription ?? "?", privacy: .public)")
                return
            }
            if output.frameLength > 0 {
                body(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            if status != .haveData { return }
        }
    }
}

// MARK: - Processing core

/// Conversion, mixing, metering and encoding. Every method must be called on
/// `queue` (a serial queue that is never a real-time audio thread). The
/// self-test drives this directly with synthetic audio.
final class RecordingCore: @unchecked Sendable {
    enum Input: Int, Sendable { case microphone = 0, system = 1 }

    let queue: DispatchQueue
    let sink: RecordingSink
    var onEvent: (@Sendable (RecordingEvent) -> Void)?
    private(set) var framesWritten: Int64 = 0

    private var mixer: FrameMixer
    private var converters: [Int: InputConverter] = [:]
    private let frame: UnsafeMutableBufferPointer<Float>
    private var paused = false
    private var failed = false
    private var meterPeak: Float = 0
    private var meterFrames = 0
    private var systemSamples = 0
    private var systemHeard = false
    private var systemSilenceReported = false

    var durationSeconds: Double { Double(framesWritten) / RecordingFormat.sampleRate }

    init(inputs: Set<Input>, sink: RecordingSink, queue: DispatchQueue) {
        self.queue = queue
        self.sink = sink
        mixer = FrameMixer(inputs: Set(inputs.map(\.rawValue)), frameSize: RecordingFormat.frameSize)
        frame = .allocate(capacity: RecordingFormat.frameSize)
        frame.initialize(repeating: 0)
    }

    deinit { frame.deallocate() }

    func ingest(_ buffer: AVAudioPCMBuffer, from input: Input) {
        guard !paused, !failed else { return }
        let key = input.rawValue
        if converters[key] == nil || converters[key]?.inputFormat != buffer.format {
            converters[key] = InputConverter(from: buffer.format)
        }
        guard let converter = converters[key] else { return }
        converter.convert(buffer) { samples in
            if input == .system { watchSystemSilence(samples) }
            mixer.push(key, samples)
        }
        pump()
    }

    /// While paused, incoming audio is dropped and the file timeline simply
    /// continues after the pause.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        mixer.reset()
        converters = [:] // resampler state from before the pause is stale
        if value {
            sink.flush()
            onEvent?(.level(0))
        }
    }

    /// Drains everything and closes the file.
    func finish() throws -> URL {
        if !paused {
            for (key, converter) in converters {
                converter.flush { mixer.push(key, $0) }
            }
            pump()
            while !failed, mixer.nextFinalFrame(into: frame) { emit() }
        }
        try sink.finish()
        if mixer.droppedSamples > 0 || mixer.paddedSamples > 0 {
            recorderLog.info("mixer: dropped \(self.mixer.droppedSamples), padded \(self.mixer.paddedSamples) samples")
        }
        return sink.url
    }

    private func pump() {
        while !failed, mixer.nextFrame(into: frame) { emit() }
    }

    private func emit() {
        let samples = UnsafeBufferPointer(frame)
        do {
            try sink.append(samples)
        } catch {
            failed = true
            onEvent?(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        framesWritten += Int64(samples.count)
        meterPeak = max(meterPeak, FrameMixer.peak(samples))
        meterFrames += 1
        if meterFrames >= 3 { // every 60 ms
            onEvent?(.level(FrameMixer.meterLevel(peak: meterPeak)))
            meterPeak = 0
            meterFrames = 0
        }
    }

    private func watchSystemSilence(_ samples: UnsafeBufferPointer<Float>) {
        if !systemHeard, samples.contains(where: { abs($0) > 1e-6 }) {
            systemHeard = true
            if systemSilenceReported { onEvent?(.systemSilent(false)) }
        }
        systemSamples += samples.count
        if !systemHeard, !systemSilenceReported, systemSamples > Int(RecordingFormat.sampleRate) * 10 {
            systemSilenceReported = true
            onEvent?(.systemSilent(true))
        }
    }
}

// MARK: - Engine

/// Owns the capture sources and the processing core. Its methods return
/// immediately; the work runs in order on a private control queue and
/// completions are called there.
final class RecordingEngine: @unchecked Sendable {
    let source: RecordingSource
    let core: RecordingCore
    var onEvent: (@Sendable (RecordingEvent) -> Void)? {
        didSet { core.onEvent = onEvent }
    }

    private let control = DispatchQueue(label: "com.musamusaev.meteora.recorder.control", qos: .userInitiated)
    private var microphone: MicrophoneCapture?
    private var system: CaptureSource?
    private var stopped = false

    init(source: RecordingSource, sink: RecordingSink) {
        self.source = source
        var inputs: Set<RecordingCore.Input> = []
        if source.usesMicrophone { inputs.insert(.microphone) }
        if source.usesSystemAudio { inputs.insert(.system) }
        let queue = DispatchQueue(label: "com.musamusaev.meteora.recorder.processing", qos: .userInitiated)
        core = RecordingCore(inputs: inputs, sink: sink, queue: queue)
    }

    func start(microphoneID: String?, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        control.async { [self] in
            do {
                if source.usesSystemAudio { try startSystemAudio() }
                if source.usesMicrophone { try startMicrophone(microphoneID) }
                completion(.success(()))
            } catch {
                stopSources()
                completion(.failure(error))
            }
        }
    }

    func pause() {
        control.async { [self] in
            core.queue.sync { core.setPaused(true) }
            // Release the microphone so the system's orange indicator goes
            // off while paused. The tap keeps running; its audio is dropped.
            microphone?.stop()
            microphone = nil
        }
    }

    /// Resumes, possibly with a different microphone than before.
    func resume(microphoneID: String?, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        control.async { [self] in
            do {
                if source.usesMicrophone, microphone == nil { try startMicrophone(microphoneID) }
                core.queue.sync { core.setPaused(false) }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        control.async { [self] in completion(finishNow()) }
    }

    /// Blocking stop, for app termination.
    func stopAndWait() -> Result<URL, Error> {
        control.sync { finishNow() }
    }

    // MARK: Control-queue internals

    private func finishNow() -> Result<URL, Error> {
        stopSources()
        guard !stopped else { return .success(core.sink.url) }
        stopped = true
        let core = self.core
        return core.queue.sync { Result { try core.finish() } }
    }

    private func startMicrophone(_ id: String?) throws {
        guard let device = AudioInputCatalog.captureDevice(id: id) else { throw RecorderError.microphoneNotFound }
        let core = self.core
        let mic = try MicrophoneCapture(device: device, deliveryQueue: core.queue) { buffer in
            core.ingest(buffer, from: .microphone) // already on core.queue
        }
        mic.onRuntimeError = { [weak self] message in
            self?.core.onEvent?(.microphoneFailed(message))
        }
        try mic.start()
        microphone = mic
        recorderLog.info("microphone: \(mic.deviceName, privacy: .public)")
    }

    private func startSystemAudio() throws {
        guard #available(macOS 14.2, *) else { throw RecorderError.systemAudioUnsupported }
        let core = self.core
        let tap = SystemAudioCapture { buffer in
            core.queue.async { core.ingest(buffer, from: .system) }
        }
        tap.onRouteChange = { [weak self] in self?.restartSystemAudio() }
        try tap.start()
        system = tap
    }

    private func restartSystemAudio() {
        control.async { [self] in
            guard !stopped, #available(macOS 14.2, *), let tap = system as? SystemAudioCapture else { return }
            do {
                try tap.restart()
                recorderLog.info("system audio: output changed, tap rebuilt")
            } catch {
                core.onEvent?(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    private func stopSources() {
        microphone?.stop()
        microphone = nil
        system?.stop()
        system = nil
    }
}
