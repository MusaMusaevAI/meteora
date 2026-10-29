import Foundation
import MeteoraCore

/// CI check of auto-folders, without the Open panel: a temporary watched
/// folder in ~/Downloads (the sandbox allows it), a recording copied in
/// slowly like a download in progress, then: detection, waiting until the
/// file settles, processing (if the speech model is installed), the files
/// written, the ledger, and that a copy of the same recording and a rescan
/// don't process it again.
extension AutoFolderStore {
    static func runSelfTest(fixtures: URL, output: URL) async -> [String: Any] {
        var report: [String: Any] = [:]
        var errors: [String] = []
        let fm = FileManager.default
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        let t0 = Date()
        func since(_ d: Date?) -> Double? { d.map { (($0.timeIntervalSince(t0)) * 10).rounded() / 10 } }

        // 1. The fixture: a file, or the best candidate in a folder.
        guard let fixture = pickFixture(fixtures) else {
            report["ok"] = false
            report["errors"] = ["no supported media fixture in \(fixtures.path)"]
            return report
        }
        report["fixture"] = fixture.lastPathComponent
        report["fixtureBytes"] = fileSize(fixture)

        // 2. A watched folder that needs no panel, and a private state folder.
        let stamp = Int(Date().timeIntervalSince1970)
        let folderURL = Folders.realHome.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Meteora autofolders selftest \(stamp)", isDirectory: true)
        let stateDir = output.appendingPathComponent("autofolders-state", isDirectory: true)
        try? fm.removeItem(at: stateDir)
        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            report["ok"] = false
            report["errors"] = ["can't create \(folderURL.path): \(error.localizedDescription)"]
            return report
        }
        defer { try? fm.removeItem(at: folderURL) }

        let store = AutoFolderStore(stateDirectory: stateDir, postsNotifications: false, stableSeconds: 6)
        var events: [(String, String, Date)] = []
        store.testObserver = { event, url in events.append((event, url.lastPathComponent, Date())) }
        func first(_ event: String, _ name: String) -> Date? { events.first { $0.0 == event && $0.1 == name }?.2 }
        func count(_ event: String, _ name: String? = nil) -> Int {
            events.filter { $0.0 == event && (name == nil || $0.1 == name) }.count
        }

        guard let folder = store.addAccessibleFolder(folderURL, formats: [.txt, .srt], output: .default) else {
            report["ok"] = false
            report["errors"] = ["addAccessibleFolder failed"]
            return report
        }
        report["bookmark"] = folder.bookmark != nil
        store.start()
        report["statusIdle"] = store.statusLine

        // 3. Write the recording in 16 chunks over ~8 s, like a download.
        let ext = fixture.pathExtension.lowercased()
        let name = "Запись 29.10.26 14-05-31.\(ext)"
        let target = folderURL.appendingPathComponent(name)
        let speech = SpeechModelController.shared.isInstalled
        report["speechModelInstalled"] = speech
        let copyStart = Date()
        var growingStatus: String?
        do {
            let data = try Data(contentsOf: fixture)
            fm.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            let chunks = 16
            let step = max(1, (data.count + chunks - 1) / chunks)
            var offset = 0
            var i = 0
            while offset < data.count {
                let end = min(data.count, offset + step)
                try handle.write(contentsOf: data.subdata(in: offset..<end))
                try? handle.synchronize()
                offset = end
                i += 1
                if i == chunks / 2 { growingStatus = store.statusLine }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try handle.close()
        } catch {
            errors.append("copy: \(error.localizedDescription)")
        }
        let copyEnd = Date()
        report["statusWhileGrowing"] = growingStatus ?? ""

        // 4. Wait for the outcome.
        let deadline = Date().addingTimeInterval(speech ? 600 : 40)
        while Date() < deadline {
            if speech, count("done", name) + count("failed", name) > 0 { break }
            if !speech, first("ready", name) != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let detected = first("detected", name)
        let ready = first("ready", name)
        let started = first("started", name)
        let done = first("done", name)
        report["timings"] = [
            "copyStart": since(copyStart) ?? -1, "copyEnd": since(copyEnd) ?? -1,
            "detected": since(detected) ?? -1, "ready": since(ready) ?? -1,
            "started": since(started) ?? -1, "done": since(done) ?? -1,
            "waitedAfterLastWrite": ready.map { (($0.timeIntervalSince(copyEnd)) * 10).rounded() / 10 } ?? -1,
            "processingSeconds": (started != nil && done != nil) ? ((done!.timeIntervalSince(started!)) * 10).rounded() / 10 : -1,
        ] as [String: Any]

        if detected == nil { errors.append("file not detected") }
        if detected.map({ $0 > copyEnd }) == true { errors.append("detected only after the copy ended (watcher missed growth)") }
        if let ready {
            if ready < copyEnd { errors.append("treated as complete while still being written") }
            if ready.timeIntervalSince(copyEnd) < store.stableSeconds - 1.5 { errors.append("did not wait for the file to settle") }
        } else {
            errors.append("file never became ready")
        }

        // 5. Processing, files and ledger.
        let outDir = folderURL.appendingPathComponent(OutputPlacement.defaultSubfolder, isDirectory: true)
        let base = sanitizedBaseName(target)
        var written: [String: Int] = [:]
        if speech {
            if done == nil {
                let failure = store.recent.first { !$0.succeeded }?.message ?? "no result"
                errors.append("processing did not finish: \(failure)")
            }
            for f in [ExportFormat.txt, .srt] {
                let file = outDir.appendingPathComponent(base + "." + f.fileExtension)
                let bytes = Int(fileSize(file))
                written[f.rawValue] = bytes
                if bytes == 0 { errors.append("\(f.rawValue) not written") }
            }
            report["written"] = written
            let ledgerFile = stateDir.appendingPathComponent("autofolders-ledger.json")
            let ledgerText = (try? String(contentsOf: ledgerFile, encoding: .utf8)) ?? ""
            let ledgerOK = ledgerText.contains("\"done\"") && ledgerText.contains(target.lastPathComponent)
            report["ledgerRecorded"] = ledgerOK
            if !ledgerOK { errors.append("ledger has no done entry") }
            report["statusAfter"] = store.statusLine
            report["recent"] = store.recent.map { "\($0.succeeded ? "ok" : "fail"): \($0.title) — \($0.message)" }
            // Keep the files for the CI artifact.
            let keep = output.appendingPathComponent("autofolders-output", isDirectory: true)
            try? fm.removeItem(at: keep)
            try? fm.copyItem(at: outDir, to: keep)
        } else {
            report["transcription"] = "skipped: speech model not installed (detection and settling checked)"
            report["statusWithoutModel"] = store.statusLine
        }

        // 6. Not again: a rescan, and a copy of the same recording.
        if speech, done != nil {
            let startedBefore = count("started")
            store.rescanNow()
            let copyName = "Запись 29.10.26 14-05-31 (копия).\(ext)"
            let copy = folderURL.appendingPathComponent(copyName)
            do {
                try fm.copyItem(at: target, to: copy)
            } catch {
                errors.append("second copy: \(error.localizedDescription)")
            }
            let until = Date().addingTimeInterval(store.stableSeconds + 8)
            while Date() < until, count("duplicate", copyName) == 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            store.rescanNow()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let duplicate = count("duplicate", copyName) > 0
            let reprocessed = count("started") - startedBefore
            report["secondCopy"] = ["detected": first("detected", copyName) != nil, "skippedAsDuplicate": duplicate,
                                    "newProcessingRuns": reprocessed] as [String: Any]
            if !duplicate { errors.append("copy of a processed recording was not recognised") }
            if reprocessed != 0 { errors.append("processed again (\(reprocessed) runs)") }
        }

        // 7. Pause / resume bookkeeping (no processing needed).
        store.pause()
        let pausedLine = store.statusLine
        store.resume()
        report["pauseStatus"] = pausedLine
        if !pausedLine.contains("пауз") { errors.append("pause status line: \(pausedLine)") }

        store.shutdown()
        report["events"] = events.map { "\(since($0.2) ?? -1) \($0.0) \($0.1)" }
        report["seconds"] = since(Date()) ?? -1
        report["errors"] = errors
        report["ok"] = errors.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("autofolders.json"))
        }
        return report
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    /// A file → itself. A folder → a recording with speech if there is one
    /// (WAV, then M4A/MP3/MP4, then WebM).
    private static func pickFixture(_ url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return MediaFormats.isSupported(url) ? url : nil }
        let items = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { MediaFormats.isSupported($0) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for ext in ["wav", "m4a", "mp3", "mp4", "webm"] {
            if let f = items.first(where: { $0.pathExtension.lowercased() == ext }) { return f }
        }
        return items.first
    }
}
