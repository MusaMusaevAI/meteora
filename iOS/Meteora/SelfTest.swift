import SwiftUI
import UIKit
import MeteoraCore

/// CI self-test in the simulator (METEORA_SELFTEST=1). Walks through the
/// app with the fixtures in Documents/Fixtures, snapshots every screen into
/// Documents/selftest/*.png and writes Documents/selftest/report.json.
@MainActor
final class SelfTest {
    static let shared = SelfTest()
    static var isRunning: Bool { ProcessInfo.processInfo.environment["METEORA_SELFTEST"] == "1" }

    /// RecorderView draws a running recording without a microphone.
    var recorderPreview: (elapsed: TimeInterval, level: Double)?
    private var session: MeetingSession?
    private var report: [String: Any] = [:]
    private var errors: [String] = []
    private let started = Date()
    private let out = Library.documents.appendingPathComponent("selftest", isDirectory: true)

    func sessionOpened(_ s: MeetingSession) { session = s }

    func run() async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        mark("start")
        let router = Router.shared
        let env = ProcessInfo.processInfo.environment
        let withLLM = env["METEORA_SELFTEST_LLM"] == "1"
        await sleep(1.5)

        // 1. Onboarding, every page.
        for page in 0..<5 {
            router.onboardingPage = page
            router.showOnboarding = true
            await sleep(page == 0 ? 2.2 : 3.0)
            snapshot("00-onboarding-\(page)")
            router.showOnboarding = false
            await sleep(0.8)
        }
        setDark(true)
        router.onboardingPage = 1
        router.showOnboarding = true
        await sleep(3.0)
        snapshot("00-onboarding-1-dark")
        router.showOnboarding = false
        await sleep(0.8)
        setDark(false)

        // 2. Empty library.
        snapshot("01-empty")

        // 3. Import fixtures.
        mark("import")
        let fixtures = Library.documents.appendingPathComponent("Fixtures", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? []).sorted()
        var imported: [String: Any] = [:]
        var speech: Recording?
        for n in names {
            let r = await Library.shared.importFile(fixtures.appendingPathComponent(n))
            if let r {
                imported[n] = ["duration": r.duration, "video": r.hasVideo,
                               "date": r.meetingDate.map { "\($0)" } ?? "none"] as [String: Any]
            } else {
                imported[n] = "failed"
            }
            if r == nil { errors.append("import \(n) failed") }
            if n.hasPrefix("speech"), let r { speech = r }
        }
        report["imported"] = imported
        await sleep(1)
        snapshot("02-library")
        setDark(true); await sleep(0.8); snapshot("02-library-dark"); setDark(false)

        // 4. Every recording opens and plays.
        mark("playback")
        var playback: [String: Any] = [:]
        for r in Library.shared.items {
            router.open(r.id)
            let ok = await wait(60) { self.session?.id == r.id && self.session?.isLoading == false }
            guard ok, let s = session else { errors.append("open \(r.path): timeout"); continue }
            var entry: [String: Any] = ["duration": s.duration]
            if let e = s.loadError { entry["error"] = e; errors.append("open \(r.path): \(e)") }
            if s.player != nil {
                s.togglePlay()
                await sleep(1.5)
                entry["advancedTo"] = s.currentTime
                s.togglePlay()
                if s.currentTime < 0.5 { errors.append("playback \(r.path) did not advance (\(s.currentTime))") }
            } else if s.loadError == nil {
                errors.append("playback \(r.path): no player")
            }
            playback[r.path] = entry
            router.path = []
            await sleep(0.8)
        }
        report["playback"] = playback

        // 5. Transcription, speakers, summary on the speech fixture.
        if let r = speech {
            mark("transcribe")
            router.open(r.id)
            _ = await wait(60) { self.session?.id == r.id && self.session?.isLoading == false }
            snapshot("03-meeting")
            if let s = session {
                let t0 = Date()
                await s.transcribe()
                var asr: [String: Any] = ["seconds": Date().timeIntervalSince(t0), "segments": s.segments.count]
                asr["text"] = s.segments.map(\.text).joined(separator: " ")
                if let e = s.jobError { asr["error"] = e; errors.append("transcribe: \(e)") }
                if s.segments.isEmpty { errors.append("transcribe: no segments") }
                report["asr"] = asr
                await sleep(1)
                snapshot("04-transcript")
                setDark(true); await sleep(0.8); snapshot("04-transcript-dark"); setDark(false)

                mark("speakers")
                let t1 = Date()
                await s.separateSpeakers(count: nil)
                report["speakers"] = ["seconds": Date().timeIntervalSince(t1), "speakers": s.speakers,
                                      "error": s.jobError ?? ""] as [String: Any]
                if let e = s.jobError { errors.append("speakers: \(e)") }
                s.jobError = nil

                mark("export")
                do {
                    let files = try s.exportFiles([.docx, .pdf, .txt, .md, .srt])
                    report["export"] = files.map { u -> String in
                        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        if size == 0 { errors.append("export \(u.lastPathComponent) is empty") }
                        return "\(u.lastPathComponent): \(size)"
                    }
                } catch {
                    errors.append("export: \(error.localizedDescription)")
                }

                if withLLM {
                    mark("summary")
                    let t2 = Date()
                    await s.summarize()
                    var llm: [String: Any] = ["seconds": Date().timeIntervalSince(t2)]
                    if let sum = s.summary {
                        llm["title"] = sum.title
                        llm["summary"] = sum.summary
                        llm["keyPoints"] = sum.keyPoints
                    }
                    if let e = s.jobError { llm["error"] = e; errors.append("summary: \(e)") }
                    report["llm"] = llm
                }
                NotificationCenter.default.post(name: SelfTestHooks.showSummaryTab, object: nil)
                await sleep(1)
                snapshot("05-summary")
                NotificationCenter.default.post(name: SelfTestHooks.showTranscriptTab, object: nil)
            }
            router.path = []
            await sleep(0.8)
        } else {
            errors.append("no speech fixture")
        }

        // 6. Recorder (drawn without a microphone) and the Live Activity.
        mark("recorder")
        recorderPreview = (elapsed: 754, level: 0.55)
        router.showRecorder = true
        await sleep(1.5)
        snapshot("06-recorder")
        router.showRecorder = false
        recorderPreview = nil
        await sleep(0.8)
        renderLiveActivity()

        // 7. Settings.
        router.showSettings = true
        await sleep(1.2)
        snapshot("08-settings")
        router.showSettings = false
        await sleep(0.8)
        snapshot("09-library-final")

        report["seconds"] = Date().timeIntervalSince(started)
        report["errors"] = errors
        report["ok"] = errors.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("report.json"))
        }
        mark("finish")
    }

    // MARK: Helpers

    private func renderLiveActivity() {
        let state = RecordingActivityAttributes.ContentState(startedAt: Date().addingTimeInterval(-754), pausedElapsed: nil, level: 0.6)
        let view = RecordingLockScreenView(title: "Запись 29.10.26 14-05-31", state: state)
            .foregroundStyle(.white)
            .frame(width: 370)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(red: 0.08, green: 0.09, blue: 0.10)))
            .environment(\.colorScheme, .dark)
            .padding(10)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        if let img = renderer.uiImage, let png = img.pngData() {
            try? png.write(to: out.appendingPathComponent("07-live-activity.png"))
        } else {
            errors.append("live activity render failed")
        }
    }

    private func snapshot(_ name: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            errors.append("snapshot \(name): no window")
            return
        }
        let r = UIGraphicsImageRenderer(bounds: window.bounds)
        let img = r.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? img.pngData()?.write(to: out.appendingPathComponent(name + ".png"))
    }

    private func setDark(_ dark: Bool) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows { w.overrideUserInterfaceStyle = dark ? .dark : .light }
        }
    }

    private func mark(_ stage: String) {
        let line = "\(String(format: "%.1f", Date().timeIntervalSince(started))) \(stage)\n"
        let f = out.appendingPathComponent("progress.txt")
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: f)
        }
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func wait(_ seconds: Double, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            await sleep(0.1)
        }
        return cond()
    }
}

enum SelfTestHooks {
    static let showSummaryTab = Notification.Name("selftest.summaryTab")
    static let showTranscriptTab = Notification.Name("selftest.transcriptTab")
}
