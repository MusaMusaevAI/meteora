import XCTest
import AVFoundation
import PDFKit
@testable import MeteoraCore

final class ParserTests: XCTestCase {
    func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    func testParsesTelemostLikeRecording() throws {
        let (info, _) = try WebMDemuxer.analyze(url: fixture("slides.webm"))
        XCTAssertEqual(info.duration, 40, accuracy: 0.2)
        XCTAssertEqual(info.video?.codecID, "V_VP8")
        XCTAssertEqual(info.video?.width, 1280)
        XCTAssertEqual(info.video?.height, 800)
        XCTAssertEqual(info.audio?.codecID, "A_OPUS")
        XCTAssertEqual(info.audio?.channels, 2)
        XCTAssertEqual(info.audio?.sampleRate, 48000)
        XCTAssertEqual(info.videoPackets.filter(\.isKey).count, 8)
        XCTAssertEqual(info.audioPacketCount, 4000, accuracy: 5)
    }

    func testParsesLiveStreamWithUnknownSizes() throws {
        let (info, _) = try WebMDemuxer.analyze(url: fixture("live.webm"))
        XCTAssertEqual(info.duration, 40, accuracy: 0.3)
        XCTAssertGreaterThan(info.videoPackets.count, 700)
        XCTAssertEqual(info.audioPacketCount, 4000, accuracy: 5)
    }

    func testParsesVP9() throws {
        let (info, _) = try WebMDemuxer.analyze(url: fixture("vp9.webm"))
        XCTAssertEqual(info.video?.codecName, "VP9")
        XCTAssertEqual(info.audioPacketCount, 2000, accuracy: 5) // 20 ms packets
    }

    func testAudioOnly() throws {
        let (info, _) = try WebMDemuxer.analyze(url: fixture("audio-only.webm"))
        XCTAssertNil(info.video)
        XCTAssertTrue(info.isAudioOnly)
        XCTAssertEqual(info.audio?.channels, 1)
        XCTAssertEqual(info.duration, 12, accuracy: 0.2)
    }

    func testRejectsNonWebM() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("not.webm")
        try Data("hello world, definitely not a video".utf8).write(to: tmp)
        XCTAssertThrowsError(try WebMDemuxer.analyze(url: tmp))
        try Data().write(to: tmp)
        XCTAssertThrowsError(try WebMDemuxer.analyze(url: tmp))
    }

    func testVorbisIsRejectedGracefully() throws {
        let (info, demuxer) = try WebMDemuxer.analyze(url: fixture("vorbis.webm"))
        XCTAssertThrowsError(try OpusTrackDecoder(demuxer: demuxer, info: info.audio!))
    }

    // MARK: Robustness — the parser must never crash on hostile input.

    func testTruncatedFilesNeverCrash() throws {
        let data = try Data(contentsOf: fixture("slides.webm"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trunc.webm")
        var cuts = Array(stride(from: 0, to: 4096, by: 37))
        cuts += Array(stride(from: 4096, to: data.count, by: data.count / 40))
        for cut in cuts {
            try data.prefix(cut).write(to: tmp)
            if let (info, d) = try? WebMDemuxer.analyze(url: tmp), let a = info.audio {
                if let dec = try? OpusTrackDecoder(demuxer: d, info: a) { _ = try? dec.analyze() }
            }
        }
    }

    func testBitFlipsNeverCrash() throws {
        let original = try Data(contentsOf: fixture("slides.webm")).prefix(160_000)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz.webm")
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0 ..< 400 {
            var d = Data(original)
            let flips = 1 + Int(rng.next() % 8)
            for _ in 0 ..< flips {
                let i = Int(rng.next() % UInt64(min(d.count, 8192)))  // headers live at the start
                d[i] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            }
            if rng.next() % 3 == 0 {  // also hit cluster/block headers further in
                let i = 8192 + Int(rng.next() % UInt64(d.count - 8192))
                d[i] = UInt8(truncatingIfNeeded: rng.next())
            }
            try d.write(to: tmp)
            if let (info, demuxer) = try? WebMDemuxer.analyze(url: tmp), let a = info.audio,
               let dec = try? OpusTrackDecoder(demuxer: demuxer, info: a) {
                _ = try? dec.decode { _ in }
            }
        }
    }

    func testLacing() throws {
        // Xiph lacing, 3 frames of sizes 2, 300, 1
        var x = Data([2])               // count - 1
        x += [2]                        // size 2
        x += [255, 45]                  // size 300
        x += Data(repeating: 1, count: 2) + Data(repeating: 2, count: 300) + Data([3])
        let frames = try WebMDemuxer.splitLacing(x, lacing: 1)
        XCTAssertEqual(frames.map(\.count), [2, 300, 1])

        // Fixed lacing, 2 frames
        let f = try WebMDemuxer.splitLacing(Data([1, 9, 9, 8, 8]), lacing: 2)
        XCTAssertEqual(f.map(\.count), [2, 2])

        // EBML lacing, 3 frames: 4, 6 (+2), rest 1
        var e = Data([2])
        e += [0x84]            // first size 4
        e += [0xC1]            // signed delta +2 (1-byte vint 65, bias 63)
        e += Data(repeating: 0, count: 4 + 6 + 1)
        XCTAssertEqual(try WebMDemuxer.splitLacing(e, lacing: 3).map(\.count), [4, 6, 1])

        // Hostile sizes must throw, not crash
        XCTAssertThrowsError(try WebMDemuxer.splitLacing(Data([3, 255, 255, 255, 255]), lacing: 1))
        XCTAssertThrowsError(try WebMDemuxer.splitLacing(Data([2, 0x81, 0xFF, 0]), lacing: 3))
        XCTAssertThrowsError(try WebMDemuxer.splitLacing(Data([2, 1, 2, 3, 4]), lacing: 2))
    }

    func testVint() throws {
        XCTAssertEqual(try WebMDemuxer.readVint(Data([0x81]), at: 0).0, 1)
        XCTAssertEqual(try WebMDemuxer.readVint(Data([0x40, 0x02]), at: 0).0, 2)
        XCTAssertNil(try WebMDemuxer.readVint(Data([0xFF]), at: 0).0)   // unknown size
        XCTAssertNil(try WebMDemuxer.readVint(Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), at: 0).0)
        XCTAssertThrowsError(try WebMDemuxer.readVint(Data([0x00]), at: 0))
        XCTAssertThrowsError(try WebMDemuxer.readVint(Data([0x40]), at: 0))
    }

    func testHTTPRange() {
        XCTAssertEqual(HTTPRange.parse(nil, size: 100), .some(nil))
        XCTAssertEqual(HTTPRange.parse("bytes=0-", size: 100), .some(0 ... 99))
        XCTAssertEqual(HTTPRange.parse("bytes=10-19", size: 100), .some(10 ... 19))
        XCTAssertEqual(HTTPRange.parse("bytes=90-500", size: 100), .some(90 ... 99))
        XCTAssertEqual(HTTPRange.parse("bytes=-10", size: 100), .some(90 ... 99))
        XCTAssertNil(HTTPRange.parse("bytes=100-", size: 100) as ClosedRange<UInt64>??)
        XCTAssertNil(HTTPRange.parse("bytes=5-1", size: 100) as ClosedRange<UInt64>??)
        XCTAssertNil(HTTPRange.parse("bytes=0-1,5-6", size: 100) as ClosedRange<UInt64>??)
        XCTAssertNil(HTTPRange.parse("items=0-1", size: 100) as ClosedRange<UInt64>??)
        XCTAssertNil(HTTPRange.parse("bytes=-0", size: 100) as ClosedRange<UInt64>??)
        XCTAssertNil(HTTPRange.parse("bytes=99999999999999999999999-", size: 100) as ClosedRange<UInt64>??)
    }
}

final class AudioTests: XCTestCase {
    func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    func testOpusSampleCount() {
        XCTAssertEqual(OpusPacket.sampleCount(Data([0xFC])), 960)       // CELT FB 20 ms
        XCTAssertEqual(OpusPacket.sampleCount(Data([(30 << 3)])), 480)  // CELT FB 10 ms
        XCTAssertEqual(OpusPacket.sampleCount(Data([(30 << 3) | 1])), 960) // two 10 ms frames
        XCTAssertEqual(OpusPacket.sampleCount(Data([(16 << 3)])), 120)  // CELT NB 2.5 ms
        XCTAssertEqual(OpusPacket.sampleCount(Data([(13 << 3)])), 960)  // Hybrid 20 ms
        XCTAssertEqual(OpusPacket.sampleCount(Data([(3 << 3) | 3, 2])), 5760) // 2 × 60 ms
        XCTAssertNil(OpusPacket.sampleCount(Data([(3 << 3) | 3, 3])))   // 180 ms > 120 ms
        XCTAssertNil(OpusPacket.sampleCount(Data([(3 << 3) | 3])))      // missing count byte
        XCTAssertNil(OpusPacket.sampleCount(Data()))
    }

    func testDecodeAndAnalyze() throws {
        let (info, d) = try WebMDemuxer.analyze(url: fixture("slides.webm"))
        let dec = try OpusTrackDecoder(demuxer: d, info: info.audio!)
        let a = try dec.analyze()
        XCTAssertEqual(a.decodedDuration, 40, accuracy: 0.15)
        XCTAssertGreaterThan(a.peak, 0.05)
        XCTAssertGreaterThan(a.activeRMS, 0.005)
        XCTAssertEqual(a.envelope.count, 400, accuracy: 3)
        // There is silence between phrases: the envelope must show it.
        XCTAssertLessThan(a.envelope[100 ..< 110].max()!, 0.2)
    }

    func testExportBothQualities() throws {
        let (info, d) = try WebMDemuxer.analyze(url: fixture("slides.webm"))
        let dec = try OpusTrackDecoder(demuxer: d, info: info.audio!)
        let analysis = try dec.analyze()
        for q in AudioQuality.allCases {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(q.rawValue).m4a")
            try? FileManager.default.removeItem(at: out)
            try AudioExporter.export(decoder: dec, analysis: analysis, options: .init(quality: q, normalize: true), to: out)
            let f = try AVAudioFile(forReading: out)
            XCTAssertEqual(f.fileFormat.sampleRate, q.sampleRate)
            XCTAssertEqual(Int(f.fileFormat.channelCount), q.channels(source: 2))
            XCTAssertEqual(Double(f.length) / f.fileFormat.sampleRate, 40, accuracy: 0.3)
        }
    }

    func testMonoAudioOnlyExport() throws {
        let (info, d) = try WebMDemuxer.analyze(url: fixture("audio-only.webm"))
        let dec = try OpusTrackDecoder(demuxer: d, info: info.audio!)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mono.m4a")
        try? FileManager.default.removeItem(at: out)
        try AudioExporter.export(decoder: dec, analysis: nil, options: .init(quality: .high, normalize: false), to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(f.length) / f.fileFormat.sampleRate, 12, accuracy: 0.3)
    }

    func testCancelledExportLeavesNoFile() throws {
        let (info, d) = try WebMDemuxer.analyze(url: fixture("slides.webm"))
        let dec = try OpusTrackDecoder(demuxer: d, info: info.audio!)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cancel.m4a")
        try? FileManager.default.removeItem(at: out)
        XCTAssertThrowsError(try AudioExporter.export(decoder: dec, analysis: nil, options: .init(quality: .medium, normalize: false),
                                                      to: out, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testLimiter() {
        XCTAssertEqual(AudioExporter.limit(0.5), 0.5)
        XCTAssertLessThanOrEqual(AudioExporter.limit(5), 1)
        XCTAssertGreaterThanOrEqual(AudioExporter.limit(-5), -1)
    }
}

final class SceneTests: XCTestCase {
    func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    func testPlannerUsesKeyframesAndFindsSpikes() throws {
        let (info, _) = try WebMDemuxer.analyze(url: fixture("slides.webm"))
        let primary = ScenePlanner.primaryTimes(packets: info.videoPackets, duration: info.duration)
        XCTAssertEqual(primary.prefix(8).map { ($0 * 10).rounded() / 10 }, [0, 5, 10, 15, 20, 25, 30, 35])
        let spikes = ScenePlanner.spikes(packets: info.videoPackets, width: 1280, height: 800)
        XCTAssertTrue(spikes.contains { abs($0 - 9.5) < 0.1 }, "slide change at 9.5 s: \(spikes)")
        XCTAssertTrue(spikes.contains { abs($0 - 21) < 0.1 }, "brief slide at 21 s: \(spikes)")
        XCTAssertFalse(spikes.contains { abs($0 - 5.05) < 0.1 }, "post-keyframe refresh must be ignored")
        let secondary = ScenePlanner.secondaryTimes(primary: primary, spikes: spikes)
        XCTAssertTrue(secondary.contains { $0 > 21 && $0 < 23 })
    }

    func testDecodePlanFindsPrecedingKeyframe() {
        let packets = (0 ..< 100).map { VideoPacket(time: Double($0) * 0.1, size: 1000, isKey: $0 % 25 == 0) }
        let index = DecodePlan.Index(packets)
        let plan = index.packets(for: 3.05)
        XCTAssertEqual(plan?.first?.time ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(plan?.last?.time ?? -1, 3.0, accuracy: 0.001)
        XCTAssertTrue(plan?.first?.isKey == true)
        XCTAssertNil(DecodePlan.Index([VideoPacket(time: 1, size: 1, isKey: false)]).packets(for: 2))
        XCTAssertEqual(DecodePlan.packets(for: 3.05, in: packets)?.count, plan?.count)
    }

    func testDecodePlanStaysBoundedOnHugeDamagedGOP() {
        // One keyframe, then a million tiny packets: every lookup must stay
        // fast and the plan must fall back to the keyframe alone.
        var packets = [VideoPacket(time: 0, size: 10, isKey: true)]
        packets += (1 ..< 1_000_000).map { VideoPacket(time: Double($0) * 0.001, size: 1, isKey: false) }
        let start = Date()
        let index = DecodePlan.Index(packets)
        for i in 0 ..< 5000 {
            let plan = index.packets(for: Double(i) * 0.2)
            XCTAssertLessThanOrEqual(plan?.count ?? 0, DecodePlan.maxPacketsPerPlan)
        }
        XCTAssertEqual(index.packets(for: 900)?.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testPlannerFillsLongGaps() {
        let packets = [VideoPacket(time: 0, size: 100, isKey: true)] +
            (1 ..< 1200).map { VideoPacket(time: Double($0) * 0.05, size: 100, isKey: false) }
        let t = ScenePlanner.primaryTimes(packets: packets, duration: 60)
        XCTAssertGreaterThanOrEqual(t.count, 4)
        for (a, b) in zip(t, t.dropFirst()) { XCTAssertLessThanOrEqual(b - a, ScenePlanner.maxGap + 0.001) }
    }

    func thumb(_ v: UInt8, block: Int? = nil) -> FrameThumb {
        var px = [UInt8](repeating: v, count: FrameThumb.width * FrameThumb.height)
        for i in px.indices { px[i] = UInt8(truncatingIfNeeded: Int(v) + (i % 7) * 3) }
        if let block { for i in 0 ..< block { px[i] = 255 &- px[i] } }
        return FrameThumb(luma: px)!
    }

    func testCollector() {
        let c = SceneCollector(threshold: 0.06)
        XCTAssertNil(c.consider(time: 0, thumb: FrameThumb(luma: [UInt8](repeating: 0, count: FrameThumb.width * FrameThumb.height))!, spikes: []), "black frame")
        XCTAssertEqual(c.consider(time: 1, thumb: thumb(40), spikes: []), 1)
        XCTAssertNil(c.consider(time: 5, thumb: thumb(40, block: 20), spikes: []), "small change (cursor)")
        XCTAssertEqual(c.consider(time: 10, thumb: thumb(160), spikes: [7.5]), 7.5, "dated by spike")
        XCTAssertNil(c.consider(time: 15, thumb: thumb(40), spikes: []), "already captured slide")
    }

    func testOCRRecognizesRussian() throws {
        let src = CGImageSourceCreateWithURL(fixture("slide.png") as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let text = TextRecognizer.recognize(img)
        XCTAssertTrue(text.contains("квартала") || text.contains("Итоги"), text)
        XCTAssertTrue(text.contains("12 480") || text.contains("12480"), text)
    }

    func testReports() throws {
        let src = CGImageSourceCreateWithURL(fixture("slide.png") as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let frames = [SceneFrame(id: 1, time: 9.5, image: img, text: "Итоги квартала\n```code```"),
                      SceneFrame(id: 2, time: 3725, image: img, text: "")]
        let meta = ReportExporter.Meta(title: "Встреча # 1", sourceName: "a`b.webm", duration: 4000)
        let pdf = ReportExporter.pdfData(frames, meta: meta)
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 3)
        XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("Итоги квартала") ?? false)
        let md = ReportExporter.markdown(frames, meta: meta, imageNames: [1: "x.png"])
        XCTAssertTrue(md.contains("## 0:00:09 — кадр 1"))
        XCTAssertTrue(md.contains("1:02:05"))
        XCTAssertFalse(md.contains("```code```"), "fences inside OCR text must be neutralised")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID())")
        try ReportExporter.writeFolder(frames, meta: meta, to: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("кадры.md").path))
    }

    func testHelpers() {
        XCTAssertEqual(Timecode.string(65), "1:05")
        XCTAssertEqual(Timecode.string(3725), "1:02:05")
        XCTAssertEqual(Timecode.fileSafe(3725), "01-02-05")
        XCTAssertEqual(sanitizedBaseName(URL(fileURLWithPath: "/tmp/Встреча в Телемосте 26.10.26 13-59-23 — запись.webm")),
                       "Встреча в Телемосте 26.10.26 13-59-23 — запись")
        XCTAssertFalse(sanitizedBaseName(URL(fileURLWithPath: "/tmp/..webm")).hasPrefix("."))
        XCTAssertFalse(sanitizedBaseName(URL(fileURLWithPath: "/tmp/a:b|c?.webm")).contains(":"))
        XCTAssertGreaterThan(textSimilarity("Итоги квартала ПДС", "итоги квартала пдс 2026"), 0.6)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Regression tests for findings of the security review (PoC files).
final class SecurityRegressionTests: XCTestCase {
    func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    func testTimestampOverflowDoesNotCrash() {
        // Used to trap on Int64 subtraction of first/last timestamps.
        if let (info, _) = try? WebMDemuxer.analyze(url: fixture("overflow-crash.webm")) {
            XCTAssertLessThanOrEqual(info.duration, WebMDemuxer.maxDuration)
        }
    }

    func testSilenceBombIsBounded() throws {
        guard let (info, d) = try? WebMDemuxer.analyze(url: fixture("silence-bomb.webm")), let a = info.audio,
              let dec = try? OpusTrackDecoder(demuxer: d, info: a) else { return }
        let start = Date()
        var total: Int64 = 0
        _ = try? dec.decode { buf in total += Int64(buf.frameLength) }
        XCTAssertLessThan(Double(total) / 48_000, 3 * 3600, "decoded audio must stay bounded")
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
        XCTAssertLessThan(ScenePlanner.primaryTimes(packets: info.videoPackets, duration: 1e12).count, ScenePlanner.maxSamples + 2)
    }

    func testFileNamesAreSafe() {
        let evil = URL(fileURLWithPath: "/tmp/x\n\n<img src=x onerror=alert(1)>![](https:evil.example)\u{202E}gpj.webm")
        let name = sanitizedBaseName(evil)
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains("<"))
        XCTAssertFalse(name.contains("\u{202E}"))
        let md = ReportExporter.markdown([], meta: .init(title: name, sourceName: evil.lastPathComponent, duration: 10), imageNames: [:])
        XCTAssertFalse(md.contains("<img"))
        XCTAssertFalse(md.contains("](https"))
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "Встреча ", count: 60) + ".webm")
        XCTAssertLessThanOrEqual(sanitizedBaseName(long).utf8.count, 150)
    }

    func testFIFOIsRejected() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fifo-\(UUID()).webm").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { unlink(path) }
        XCTAssertThrowsError(try ByteSource(url: URL(fileURLWithPath: path)))
    }
}

final class TranscriptTests: XCTestCase {
    let tr = Transcript(sourceName: "Встреча.webm", duration: 3700, engine: "test", segments: [
        TranscriptSegment(start: 1.5, end: 4.25, text: "Добрый день, коллеги."),
        TranscriptSegment(start: 3661, end: 3665.5, text: "Итоги <b>квартала</b>](http://x)"),
    ])

    func testSRT() {
        let srt = TranscriptExporter.srt(tr)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:01,500 --> 00:00:04,250\nДобрый день, коллеги.\n\n2\n01:01:01,000 --> 01:01:05,500\n"))
    }

    func testPlainText() {
        XCTAssertTrue(TranscriptExporter.plainText(tr).hasPrefix("[0:00:01] Добрый день, коллеги.\n[1:01:01]"))
    }

    func testMarkdownMergesSpeechAndFramesSafely() throws {
        let img = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: CGDataProvider(data: Data(count: 16) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let frames = [SceneFrame(id: 1, time: 2, image: img, text: "Слайд")]
        let md = TranscriptExporter.markdown(tr, frames: frames, meta: .init(title: "Встреча", sourceName: "Встреча.webm", duration: 3700))
        let speech = try XCTUnwrap(md.range(of: "Добрый день"))
        let frame = try XCTUnwrap(md.range(of: "Кадр 1"))
        XCTAssertLessThan(speech.lowerBound, frame.lowerBound, "speech at 1.5 s comes before the frame at 2 s")
        XCTAssertFalse(md.contains("<b>"))
        XCTAssertFalse(md.contains("](http"))
    }

    func testSegmentLookup() {
        XCTAssertEqual(tr.segmentIndex(at: 2), 0)
        XCTAssertNil(tr.segmentIndex(at: 100))
        XCTAssertEqual(tr.segmentIndex(at: 3662), 1)
        XCTAssertEqual(tr.wordCount, 5)
    }

    func testTinySizes() {
        XCTAssertEqual(FileSizeText.string(300), "< 1 КБ")
    }
}
