import AppKit
import AVFoundation
import SwiftUI
import MeteoraCore
import MeteoraASR

/// End-to-end check used by CI on a real macOS machine:
/// `Meteora --selftest <input.webm> <output-dir>`.
/// Exercises parsing, playback in WebKit, audio decode/export, key-frame
/// detection, OCR and report export inside the real sandboxed app, then
/// writes `report.json` and screenshots of the UI and quits.
@MainActor
final class SelfTest {
    let model: MeetingModel
    let input: URL
    let output: URL
    private var report: [String: Any] = [:]
    private var errors: [String] = []

    let asrWav: URL?

    init(model: MeetingModel, input: URL, output: URL, asrWav: URL? = nil) {
        self.model = model
        self.input = input
        self.output = output
        self.asrWav = asrWav
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        report["entitlements_sandboxed"] = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        _ = await wait(15) { !NSApp.windows.isEmpty }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        report["windows"] = NSApp.windows.map { "\($0.className) visible=\($0.isVisible) onScreen=\($0.occlusionState.contains(.visible)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        report["screens"] = NSScreen.screens.count
        report["activationPolicy"] = NSApp.activationPolicy().rawValue
        // Onboarding (static artwork so the screenshot shows it)
        for (i, step) in [0, 2].enumerated() {
            OnboardingWindow.show(model: model, step: step, stillsOnly: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            snapshotWindow(titled: "Знакомство с Meteora", as: "00-onboarding-\(step)")
            if i == 0 {
                setAppearance(.darkAqua); try? await Task.sleep(nanoseconds: 500_000_000)
                snapshotWindow(titled: "Знакомство с Meteora", as: "00-onboarding-\(step)-dark")
                setAppearance(.aqua)
            }
            OnboardingWindow.close()
        }
        NSApp.windows.first { $0.contentView is NSHostingView<ContentView> }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        snapshotWindow("01-empty")
        setAppearance(.darkAqua); try? await Task.sleep(nanoseconds: 400_000_000)
        snapshotWindow("02-empty-dark")
        setAppearance(.aqua)

        // 1. Parse
        let t0 = Date()
        model.open(input)
        if !(await wait(60) { self.model.loadState == .ready || self.isFailed }) || isFailed {
            errors.append("load: \(model.loadState)")
            return finish()
        }
        if let info = model.info {
            report["parse"] = [
                "seconds": Date().timeIntervalSince(t0),
                "duration": info.duration,
                "video": info.video.map { "\($0.codecID) \($0.width)x\($0.height)" } ?? "none",
                "audio": info.audio.map { "\($0.codecID) \($0.channels)ch \($0.sampleRate)" } ?? "none",
                "videoPackets": info.videoPackets.count,
                "keyframes": info.videoPackets.filter(\.isKey).count,
                "audioPackets": info.audioPacketCount,
                "hasCues": info.hasCues,
            ] as [String: Any]
        }

        // 2. Playback in WebKit
        if let player = model.player {
            let ok = await wait(30) { player.isReady || player.mediaErrorCode != 0 }
            report["playback"] = ["ready": player.isReady, "mediaError": player.mediaErrorCode,
                                  "videoSize": "\(Int(player.videoSize.width))x\(Int(player.videoSize.height))",
                                  "webDuration": player.duration, "waitedOK": ok] as [String: Any]
            if !player.isReady { errors.append("playback not ready, code \(player.mediaErrorCode)") }
            report["jsInfo"] = await player.debugInfo()
            report["webDiagnostics"] = player.diagnostics
            if player.isReady {
                player.play()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let advanced = player.currentTime
                player.pause()
                report["playbackAdvancedTo"] = advanced
                if model.hasVideo, advanced < 0.3 { errors.append("playback did not advance (\(advanced))") }
            }
        }

        // 3. Audio analysis + export
        if model.info?.audio != nil {
            let t1 = Date()
            _ = await wait(300) { self.model.audioAnalysis != nil || self.model.audioError != nil }
            var audio: [String: Any] = ["analysisSeconds": Date().timeIntervalSince(t1)]
            if let a = model.audioAnalysis {
                audio["decodedDuration"] = a.decodedDuration
                audio["peak"] = a.peak
                audio["activeRMS"] = a.activeRMS
                audio["envelopePoints"] = a.envelope.count
            }
            if let e = model.audioError { errors.append("audio: \(e)") }
            for q in AudioQuality.allCases {
                model.quality = q
                let dest = output.appendingPathComponent("audio-\(q.rawValue).m4a")
                let t2 = Date()
                let ok = await model.exportAudio(to: dest, reveal: false)
                var entry: [String: Any] = ["ok": ok, "seconds": Date().timeIntervalSince(t2)]
                if ok, let f = try? AVAudioFile(forReading: dest) {
                    entry["duration"] = Double(f.length) / f.fileFormat.sampleRate
                    entry["sampleRate"] = f.fileFormat.sampleRate
                    entry["channels"] = f.fileFormat.channelCount
                    entry["bytes"] = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                } else {
                    errors.append("audio export \(q.rawValue) failed: \(model.toast?.message ?? "?")")
                }
                audio[q.rawValue] = entry
            }
            report["audio"] = audio
        }

        // 3b. Speech model download + on-device transcription
        if ProcessInfo.processInfo.environment["METEORA_SELFTEST_ASR"] == "1" {
            var asr: [String: Any] = [:]
            let speech = SpeechModelController.shared
            let t4 = Date()
            if !speech.isInstalled {
                let ok = await speech.download()
                asr["downloadSeconds"] = Date().timeIntervalSince(t4)
                asr["downloadOK"] = ok
                if !ok { errors.append("model download: \(speech.error ?? "?")") }
            }
            asr["installed"] = speech.isInstalled
            asr["runtime"] = SpeechRecognizer.runtimeVersion
            asr["vadBundled"] = SpeechModelController.vadModelURL != nil
            if speech.isInstalled, let wav = asrWav, let vad = SpeechModelController.vadModelURL {
                do {
                    let samples = try Self.readMono16k(wav)
                    let t5 = Date()
                    let rec = try SpeechRecognizer(store: .shared, vadModel: vad)
                    let segs = rec.transcribe(samples16k: samples)
                    asr["wavSeconds"] = Double(samples.count) / 16_000
                    asr["wavDecodeSeconds"] = Date().timeIntervalSince(t5)
                    asr["wavText"] = segs.map(\.text).joined(separator: " ")
                    if segs.isEmpty { errors.append("ASR: no text from Russian sample") }
                } catch {
                    errors.append("ASR wav: \(error)")
                }
            }
            if speech.isInstalled, model.canTranscribe {
                let t6 = Date()
                await model.transcribe()
                let segs = model.displayedSegments
                asr["recordingSeconds"] = Date().timeIntervalSince(t6)
                asr["recordingSegments"] = segs.count
                asr["recordingSample"] = segs.prefix(3).map { "[\(Timecode.string($0.start))] \($0.text)" }
                asr["error"] = model.transcribeError ?? ""
                if let e = model.transcribeError { errors.append("ASR recording: \(e)") }
                if let tr = model.transcript {
                    try? TranscriptExporter.srt(tr).write(to: output.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
                }
            }
            report["asr"] = asr
        }

        // 4. Key frames + OCR + reports
        if model.hasVideo, let player = model.player, player.isReady {
            for thorough in [false, true] {
                model.thorough = thorough
                model.textOnly = false
                let t3 = Date()
                await model.analyzeScenes()
                let frames = model.frames.map(\.frame)
                report[thorough ? "scenesThorough" : "scenes"] = [
                    "seconds": Date().timeIntervalSince(t3),
                    "count": frames.count,
                    "times": frames.map { ($0.time * 10).rounded() / 10 },
                    "letters": frames.map(\.letterCount),
                    "webCodecs": model.usedDecoder,
                    "snapshotFallback": player.usesSnapshotFallback,
                    "snapshotRetries": player.snapshotRetries,
                    "error": model.sceneError ?? "",
                ] as [String: Any]
            }
            let frames = model.frames.map(\.frame)
            if frames.isEmpty { errors.append("no key frames found") }
            let meta = ReportExporter.Meta(title: model.title, sourceName: input.lastPathComponent, duration: model.info?.duration ?? 0)
            do {
                try ReportExporter.pdfData(frames, meta: meta).write(to: output.appendingPathComponent("frames.pdf"))
                try ReportExporter.writeFolder(frames, meta: meta, to: output.appendingPathComponent("frames"))
                if let first = frames.first {
                    report["ocrSample"] = String(first.text.prefix(300))
                }
            } catch {
                errors.append("report export: \(error)")
            }
            if let f = model.frames.dropFirst(min(2, max(0, model.frames.count - 1))).first {
                model.selectedFrame = f.id
                player.seek(to: f.frame.time)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            if let img = try? await player.grabFrame(), let data = ReportExporter.pngData(img) {
                try? data.write(to: output.appendingPathComponent("player-frame.png"))
            }
        }

        // 5. Documents in every format
        if model.canExportDocuments {
            var ex: [String: Any] = [:]
            let dir = output.appendingPathComponent("exports", isDirectory: true)
            let meta = ReportExporter.Meta(title: model.title, sourceName: input.lastPathComponent, duration: model.info?.duration ?? 0)
            for f in ExportFormat.allCases {
                do {
                    let r = try TranscriptExporter.export(model.transcript, frames: model.frames.map(\.frame), meta: meta,
                                                          format: f, options: .standard, baseName: model.title)
                    let u = try TranscriptExporter.write(r, to: dir, baseName: model.title, format: f)
                    ex[f.rawValue] = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                } catch {
                    errors.append("export \(f.rawValue): \(error)")
                }
            }
            report["exports"] = ex
            model.exportSheetShown = true
            try? await Task.sleep(nanoseconds: 900_000_000)
            snapshotSheet("06-export")
            model.exportSheetShown = false
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // 6. Batch window (not started)
        BatchQueue.shared.add([input])
        BatchWindow.show()
        try? await Task.sleep(nanoseconds: 900_000_000)
        snapshotWindow(titled: "Пакетная обработка", as: "07-batch")
        NSApp.windows.first { $0.title == "Пакетная обработка" }?.close()
        NSApp.windows.first { $0.contentView is NSHostingView<ContentView> }?.makeKeyAndOrderFront(nil)

        model.toast = Toast(message: "Звук сохранён: пример уведомления", revealURL: output)
        try? await Task.sleep(nanoseconds: 600_000_000)
        snapshotWindow("03-loaded")
        setAppearance(.darkAqua); try? await Task.sleep(nanoseconds: 600_000_000)
        snapshotWindow("04-loaded-dark")
        setAppearance(.aqua)
        if let model = Optional(model) {
            StorageWindow.show(model: model)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            report["storage"] = StorageModel.scan().map { "\($0.section.title): \($0.title) — \($0.bytes)" }
            snapshotWindow("05-storage", storage: true)
        }
        finish()
    }

    private var isFailed: Bool { if case .failed = model.loadState { return true }; return false }

    private func wait(_ seconds: Double, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }

    private func setAppearance(_ name: NSAppearance.Name) {
        NSApp.appearance = NSAppearance(named: name)
    }

    /// Renders the window's view hierarchy (WebKit video surfaces may come
    /// out black — the actual video frame is saved separately).
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: inBuf)
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / inFmt.sampleRate) + 4096)!
        var given = false
        var err: NSError?
        _ = conv.convert(to: outBuf, error: &err) { _, s in
            if given { s.pointee = .endOfStream; return nil }
            given = true; s.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    private func snapshotWindow(_ name: String, storage: Bool = false) {
        guard let window = NSApp.windows.first(where: {
            storage ? $0.contentView is NSHostingView<StorageView> : $0.contentView is NSHostingView<ContentView>
        }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            errors.append("no window for snapshot \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private func snapshotSheet(_ name: String) {
        guard let main = NSApp.windows.first(where: { $0.contentView is NSHostingView<ContentView> }),
              let sheet = main.attachedSheet,
              let view = sheet.contentView?.superview ?? sheet.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            errors.append("no sheet for snapshot \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private func snapshotWindow(titled title: String, as name: String) {
        guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            errors.append("no window for snapshot \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private func finish() {
        if let player = model.player { report["webDiagnosticsFinal"] = player.diagnostics }
        report["errors"] = errors
        report["ok"] = errors.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("report.json"))
        }
        exit(errors.isEmpty ? 0 : 1)
    }
}
