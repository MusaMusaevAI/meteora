import Foundation
import AVFoundation
import MeteoraCore

extension MeetingRecorder {
    /// CI check that needs no microphone and asks for no permission:
    /// encoder availability, a 3 s 440 Hz tone through the real
    /// resampler → mixer → Opus encoder → WebM writer into
    /// `output/recording-test.webm`, read back with WebMDemuxer and decoded
    /// with OpusTrackDecoder; a two-source mix; the list of inputs and
    /// whether process taps (system audio) are available.
    static func runSelfTest(output: URL) async -> [String: Any] {
        var report: [String: Any] = [:]
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        report["opusEncoderAvailable"] = OpusWebMSink.isEncoderAvailable
        report["processTapsAvailable"] = AudioInputCatalog.systemAudioAvailable
        report["microphoneAuthorization"] = authorizationName(AVCaptureDevice.authorizationStatus(for: .audio))
        report["inputDevices"] = AudioInputCatalog.discoverDevices().map { "\($0.name) [\($0.kind.rawValue)]" }
        report["defaultInput"] = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"

        // The file name must round-trip through the journal's date parser.
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 29
        components.hour = 14; components.minute = 5; components.second = 31
        let date = Calendar.current.date(from: components) ?? Date()
        let name = RecordingFolder.newFileURL(in: output, date: date, fileExtension: "webm").lastPathComponent
        let parsed = MeetingJournal.parseTelemostDate((name as NSString).deletingPathExtension)
        let nameOK = name == "Запись 29.10.26 14-05-31.webm" && parsed == date
        report["fileName"] = ["name": name, "parsedBack": nameOK] as [String: Any]

        let url = output.appendingPathComponent("recording-test.webm")
        let tone = await Task.detached(priority: .userInitiated) { RecordingSelfTestRunner.encodeTone(to: url) }.value
        report["tone"] = tone.dictionary
        let mix = await Task.detached(priority: .userInitiated) { RecordingSelfTestRunner.mixTwoSources() }.value
        report["mix"] = mix.dictionary
        let m4aURL = output.appendingPathComponent("recording-test.m4a")
        let aac = await Task.detached(priority: .userInitiated) { RecordingSelfTestRunner.encodeToneAAC(to: m4aURL) }.value
        report["toneM4A"] = aac.dictionary
        report["defaultFormat"] = RecordingFileFormat.current.rawValue

        report["ok"] = tone.ok && mix.ok && nameOK && aac.ok
        return report
    }

    private static func authorizationName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}

struct RecordingSelfTestResult: Sendable {
    var ok = false
    var error: String?
    var values: [String: Double] = [:]
    var notes: [String: String] = [:]

    var dictionary: [String: Any] {
        var d: [String: Any] = ["ok": ok]
        if let error { d["error"] = error }
        for (k, v) in values { d[k] = v }
        for (k, v) in notes { d[k] = v }
        return d
    }
}

enum RecordingSelfTestRunner {
    /// 3 s of 440 Hz at 44.1 kHz stereo (like many USB microphones), so the
    /// resampler and the downmix are exercised too.
    static func encodeTone(to url: URL, seconds: Double = 3) -> RecordingSelfTestResult {
        var r = RecordingSelfTestResult()
        let started = Date()
        do {
            try? FileManager.default.removeItem(at: url)
            let sink = try OpusWebMSink(url: url)
            r.notes["format"] = sink.formatName
            let queue = DispatchQueue(label: "com.musamusaev.meteora.recorder.selftest")
            let core = RecordingCore(inputs: [.microphone], sink: sink, queue: queue)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
            let total = Int(seconds * 44_100)
            let finished: Result<URL, Error> = queue.sync {
                var produced = 0
                while produced < total {
                    let n = min(1_024, total - produced)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                    buffer.frameLength = AVAudioFrameCount(n)
                    let channels = buffer.floatChannelData!
                    for i in 0 ..< n {
                        let v = Float(0.3 * sin(2 * Double.pi * 440 * Double(produced + i) / 44_100))
                        channels[0][i] = v
                        channels[1][i] = v
                    }
                    core.ingest(buffer, from: .microphone)
                    produced += n
                }
                return Result { try core.finish() }
            }
            _ = try finished.get()
            r.values["encodeSeconds"] = Date().timeIntervalSince(started)

            // Read back with our demuxer, decode with the system Opus decoder.
            let (info, demuxer) = try WebMDemuxer.analyze(url: url)
            guard let audio = info.audio else { throw MediaError.noAudio }
            r.notes["codec"] = audio.codecID
            r.values["packets"] = Double(info.audioPacketCount)
            r.values["containerDuration"] = info.duration
            r.values["hasCues"] = info.hasCues ? 1 : 0
            r.values["fileBytes"] = Double(info.fileSize)

            let decoder = try OpusTrackDecoder(demuxer: demuxer, info: audio)
            var samples = 0
            var measured = 0
            var sumSquares = 0.0
            var crossings = 0
            var previous: Float = 0
            let skip = 4_800 // the first 100 ms (encoder warm-up)
            try decoder.decode { buffer in
                let p = buffer.floatChannelData![0]
                for i in 0 ..< Int(buffer.frameLength) {
                    let v = p[i]
                    if samples >= skip {
                        sumSquares += Double(v * v)
                        if (previous < 0) != (v < 0) { crossings += 1 }
                        measured += 1
                    }
                    previous = v
                    samples += 1
                }
            }
            let decoded = Double(samples) / 48_000
            let rms = measured > 0 ? (sumSquares / Double(measured)).squareRoot() : 0
            let frequency = measured > 0 ? Double(crossings) / 2 / (Double(measured) / 48_000) : 0
            r.values["decodedDuration"] = decoded
            r.values["rms"] = rms
            r.values["frequency"] = frequency
            r.ok = audio.codecID == "A_OPUS"
                && abs(info.duration - seconds) < 0.1
                && abs(decoded - seconds) < 0.1
                && rms > 0.05
                && abs(frequency - 440) < 20
        } catch {
            r.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return r
    }

    /// The same tone through the AAC sink; read back with AVAudioFile.
    static func encodeToneAAC(to url: URL, seconds: Double = 3) -> RecordingSelfTestResult {
        var r = RecordingSelfTestResult()
        do {
            let sink = try AACFileSink(url: url)
            r.notes["format"] = sink.formatName
            let queue = DispatchQueue(label: "com.musamusaev.meteora.recorder.selftest-aac")
            let core = RecordingCore(inputs: [.microphone], sink: sink, queue: queue)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            let total = Int(seconds * 48_000)
            let finished: Result<URL, Error> = queue.sync {
                var produced = 0
                while produced < total {
                    let n = min(1_024, total - produced)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                    buffer.frameLength = AVAudioFrameCount(n)
                    let p = buffer.floatChannelData![0]
                    for i in 0 ..< n { p[i] = Float(0.3 * sin(2 * Double.pi * 440 * Double(produced + i) / 48_000)) }
                    core.ingest(buffer, from: .microphone)
                    produced += n
                }
                return Result { try core.finish() }
            }
            _ = try finished.get()
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let p = buf.floatChannelData![0]
            let rate = file.processingFormat.sampleRate
            var sum = 0.0, crossings = 0, measured = 0
            var previous: Float = 0
            for i in Int(rate * 0.1) ..< Int(buf.frameLength) {
                let v = p[i]
                sum += Double(v * v)
                if (previous < 0) != (v < 0) { crossings += 1 }
                previous = v
                measured += 1
            }
            let rms = measured > 0 ? (sum / Double(measured)).squareRoot() : 0
            let frequency = measured > 0 ? Double(crossings) / 2 / (Double(measured) / rate) : 0
            r.values["duration"] = duration
            r.values["rms"] = rms
            r.values["frequency"] = frequency
            r.values["bytes"] = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            r.ok = abs(duration - seconds) < 0.15 && rms > 0.05 && abs(frequency - 440) < 20
        } catch {
            r.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return r
    }

    /// Microphone (440 Hz, 48 kHz mono, 480-sample chunks) and system audio
    /// (660 Hz, 48 kHz stereo, 512-sample chunks, starting 150 ms late) mixed
    /// for 1 s into a counting sink.
    static func mixTwoSources() -> RecordingSelfTestResult {
        var r = RecordingSelfTestResult()
        let sink = CountingSink()
        let queue = DispatchQueue(label: "com.musamusaev.meteora.recorder.selftest-mix")
        let core = RecordingCore(inputs: [.microphone, .system], sink: sink, queue: queue)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        func tone(_ format: AVAudioFormat, frequency: Double, offset: Int, count: Int) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            b.frameLength = AVAudioFrameCount(count)
            let channels = Int(format.channelCount)
            let p = b.floatChannelData![0] // interleaved: one buffer holds all channels
            for i in 0 ..< count {
                let v = Float(0.5 * sin(2 * Double.pi * frequency * Double(offset + i) / 48_000))
                if format.isInterleaved {
                    for c in 0 ..< channels { p[i * channels + c] = v }
                } else {
                    p[i] = v
                }
            }
            return b
        }
        let result: Result<URL, Error> = queue.sync {
            var mic = 0, system = 0
            while mic < 48_000 || system < 48_000 - 7_200 {
                if mic < 48_000 {
                    core.ingest(tone(mono, frequency: 440, offset: mic, count: 480), from: .microphone)
                    mic += 480
                }
                if mic > 7_200, system < 48_000 - 7_200 {
                    core.ingest(tone(stereo, frequency: 660, offset: system, count: 512), from: .system)
                    system += 512
                }
            }
            return Result { try core.finish() }
        }
        if case .failure(let error) = result { r.error = error.localizedDescription }
        r.values["frames"] = Double(sink.frames)
        r.values["peak"] = Double(sink.peak)
        r.ok = result.isSuccess && (49 ... 52).contains(sink.frames) && sink.peak <= 1 && sink.peak > 0.5
        return r
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

/// A sink that only counts frames (self-test).
private final class CountingSink: RecordingSink {
    let url = URL(fileURLWithPath: "/dev/null")
    let formatName = "test"
    private(set) var frames = 0
    private(set) var peak: Float = 0

    func append(_ frame: UnsafeBufferPointer<Float>) throws {
        frames += 1
        peak = max(peak, FrameMixer.peak(frame))
    }

    func flush() {}
    func finish() throws {}
}
