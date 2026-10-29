import XCTest
@testable import MeteoraCore

/// The recorder's WebM muxer must produce files our own demuxer (and
/// therefore WebKit, which reads the same structure) opens.
final class WebMWriterTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("meteora-test-\(UUID().uuidString)-\(name)")
    }

    /// Synthetic "Opus" packet: a valid TOC byte (SILK WB 20 ms, one frame)
    /// followed by arbitrary bytes — the container doesn't care.
    private func packet(_ i: Int) -> Data {
        var d = Data([0x48])
        d.append(contentsOf: (0 ..< (40 + i % 37)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })
        return d
    }

    func testWritesReadableOpusWebM() throws {
        let url = tempURL("rec.webm")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try WebMOpusWriter(url: url, channels: 1, preSkip: 312)
        var written: [Data] = []
        for i in 0 ..< 150 { // 150 × 20 ms = 3 s
            let p = packet(i)
            written.append(p)
            try w.append(p, samples: 960)
        }
        XCTAssertEqual(w.duration, 3, accuracy: 1e-9)
        try w.finish()

        let (info, demuxer) = try WebMDemuxer.analyze(url: url)
        XCTAssertNil(info.video)
        XCTAssertEqual(info.audio?.codecID, "A_OPUS")
        XCTAssertEqual(info.audio?.channels, 1)
        XCTAssertEqual(info.audio?.sampleRate, 48_000)
        XCTAssertEqual(info.audio?.codecDelayNs, 6_500_000)
        XCTAssertEqual(info.audio?.codecPrivate.prefix(8), Data("OpusHead".utf8))
        XCTAssertEqual(info.audio?.codecPrivate.count, 19)
        XCTAssertEqual(info.audioPacketCount, 150)
        XCTAssertEqual(info.duration, 3, accuracy: 0.001)
        XCTAssertTrue(info.hasCues)
        XCTAssertEqual(info.writingApp, "Meteora")

        // Payloads and timestamps survive the round trip.
        var read: [Data] = []
        var times: [Double] = []
        try demuxer.forEachAudioPacket { t, p in read.append(p); times.append(t) }
        XCTAssertEqual(read, written)
        XCTAssertEqual(times.first ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(times.last ?? -1, 2.98, accuracy: 1e-9)
    }

    func testLongRecordingSpansManyClusters() throws {
        let url = tempURL("long.webm")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try WebMOpusWriter(url: url)
        // 75 s with a 10 s pause-free gap of empty packets in the middle.
        for i in 0 ..< 3_750 {
            try w.append((1_500 ..< 2_000).contains(i) ? Data() : packet(i), samples: 960)
        }
        try w.finish()
        let (info, demuxer) = try WebMDemuxer.analyze(url: url)
        XCTAssertEqual(info.audioPacketCount, 3_250)
        XCTAssertEqual(info.duration, 75, accuracy: 0.001)
        var last = -1.0
        var monotonic = true
        try demuxer.forEachAudioPacket { t, _ in
            if t <= last { monotonic = false }
            last = t
        }
        XCTAssertTrue(monotonic)
        XCTAssertEqual(last, 74.98, accuracy: 1e-9)
    }

    func testStereoAndHeader() throws {
        let url = tempURL("stereo.webm")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try WebMOpusWriter(url: url, channels: 2, preSkip: 0)
        try w.append(packet(1), samples: 960)
        try w.finish()
        let (info, _) = try WebMDemuxer.analyze(url: url)
        XCTAssertEqual(info.audio?.channels, 2)
        XCTAssertEqual(info.audio?.codecPrivate[9], 2)
        XCTAssertThrowsError(try w.append(packet(2), samples: 960))
        XCTAssertThrowsError(try WebMOpusWriter(url: tempURL("bad.webm"), channels: 3))
    }

    /// A crash before `finish()` leaves a live-stream style file (unknown
    /// segment size, no cues, zero duration) that still opens.
    func testUnfinishedFileIsReadable() throws {
        let url = tempURL("crash.webm")
        let copy = tempURL("crash-copy.webm")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        let w = try WebMOpusWriter(url: url)
        for i in 0 ..< 500 { try w.append(packet(i), samples: 960) } // 10 s
        try w.flush()
        try FileManager.default.copyItem(at: url, to: copy) // snapshot "at the crash"
        try w.finish()

        let (info, _) = try WebMDemuxer.analyze(url: copy)
        XCTAssertEqual(info.audioPacketCount, 500)
        XCTAssertFalse(info.hasCues)
        XCTAssertEqual(info.duration, 9.98, accuracy: 0.001) // from packet timestamps
        XCTAssertEqual(info.audio?.codecID, "A_OPUS")

        // A torn last cluster (crash in the middle of a write) is cut off cleanly.
        let data = try Data(contentsOf: copy)
        try data.prefix(data.count - 300).write(to: copy)
        let (torn, _) = try WebMDemuxer.analyze(url: copy)
        XCTAssertGreaterThan(torn.audioPacketCount, 400)
        XCTAssertLessThan(torn.audioPacketCount, 500)
    }

    func testEBMLEncoding() {
        XCTAssertEqual(WebMOpusWriter.sizeVint(0), Data([0x80]))
        XCTAssertEqual(WebMOpusWriter.sizeVint(126), Data([0xFE]))
        XCTAssertEqual(WebMOpusWriter.sizeVint(127), Data([0x40, 0x7F])) // 0xFF would mean "unknown"
        XCTAssertEqual(WebMOpusWriter.sizeVint(300), Data([0x41, 0x2C]))
        XCTAssertEqual(WebMOpusWriter.vint8(5), Data([0x01, 0, 0, 0, 0, 0, 0, 5]))
        XCTAssertEqual(WebMOpusWriter.idBytes(0x1A45DFA3), Data([0x1A, 0x45, 0xDF, 0xA3]))
        XCTAssertEqual(WebMOpusWriter.idBytes(0xA3), Data([0xA3]))
        XCTAssertEqual(WebMOpusWriter.uint(0xD7, 1), Data([0xD7, 0x81, 0x01]))
        XCTAssertEqual(WebMOpusWriter.uint(0xD7, 0), Data([0xD7, 0x81, 0x00]))
        XCTAssertEqual(WebMOpusWriter.void(totalSize: 2), Data([0xEC, 0x80]))
        XCTAssertEqual(WebMOpusWriter.void(totalSize: 96).count, 96)
        XCTAssertEqual(WebMOpusWriter.void(totalSize: 300).count, 300)
        let head = WebMOpusWriter.opusHead(channels: 1, preSkip: 312, inputRate: 48_000)
        XCTAssertEqual(Array(head.suffix(11)), [1, 1, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00, 0, 0, 0])
    }
}

final class FrameMixerTests: XCTestCase {
    private func frames(_ m: inout FrameMixer, final: Bool = false) -> [[Float]] {
        var out: [[Float]] = []
        var buf = [Float](repeating: 0, count: m.frameSize)
        while buf.withUnsafeMutableBufferPointer({ final ? m.nextFinalFrame(into: $0) : m.nextFrame(into: $0) }) {
            out.append(buf)
        }
        return out
    }

    func testSingleInputPassesThrough() {
        var m = FrameMixer(inputs: [0], frameSize: 4)
        m.push(0, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        m.push(1, [1, 1, 1, 1]) // disabled input is ignored
        XCTAssertEqual(frames(&m), [[0.1, 0.2, 0.3, 0.4]])
        XCTAssertEqual(frames(&m, final: true), [[0.5, 0.6, 0, 0]])
        XCTAssertEqual(m.paddedSamples, 2)
    }

    func testTwoInputsAreSummedAndLimited() {
        var m = FrameMixer(inputs: [0, 1], frameSize: 2)
        m.push(0, [0.25, 0.6])
        XCTAssertTrue(frames(&m).isEmpty) // waits for the other input
        m.push(1, [0.25, 0.6])
        let f = frames(&m)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0][0], 0.5, accuracy: 1e-6)
        XCTAssertLessThan(f[0][1], 1) // 1.2 is softly limited
        XCTAssertGreaterThan(f[0][1], 0.89)
    }

    func testStalledInputIsPaddedWithSilence() {
        var m = FrameMixer(inputs: [0, 1], frameSize: 10, lagTolerance: 20)
        m.push(0, [Float](repeating: 0.1, count: 25))
        XCTAssertTrue(frames(&m).isEmpty) // within tolerance: wait
        m.push(0, [Float](repeating: 0.1, count: 10)) // now 35 ≥ 10 + 20
        let f = frames(&m)
        XCTAssertEqual(f.count, 1) // one frame, then back within tolerance
        XCTAssertEqual(f[0], [Float](repeating: 0.1, count: 10))
        XCTAssertEqual(m.backlog(0), 25)
    }

    func testOverflowDropsOldest() {
        var m = FrameMixer(inputs: [0, 1], frameSize: 4, lagTolerance: 1_000, maxBacklog: 8)
        m.push(1, (0 ..< 12).map { Float($0) / 100 })
        XCTAssertEqual(m.backlog(1), 8)
        XCTAssertEqual(m.droppedSamples, 4)
        m.push(0, [0, 0, 0, 0])
        XCTAssertEqual(frames(&m).first?[0] ?? -1, 0.04, accuracy: 1e-6)
    }

    func testMeterScale() {
        XCTAssertEqual(FrameMixer.meterLevel(peak: 0), 0)
        XCTAssertEqual(FrameMixer.meterLevel(peak: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(FrameMixer.meterLevel(peak: 0.0316), 0.5, accuracy: 0.01) // −30 dBFS
        XCTAssertEqual(FrameMixer.softLimit(0.5), 0.5)
        XCTAssertLessThanOrEqual(FrameMixer.softLimit(10), 1)
    }
}
