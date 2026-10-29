import XCTest
@testable import MeteoraCore

final class SpeakerAssignmentTests: XCTestCase {
    func seg(_ a: Double, _ b: Double, _ text: String = "Фраза.") -> TranscriptSegment {
        TranscriptSegment(start: a, end: b, text: text)
    }

    func turn(_ a: Double, _ b: Double, _ s: Int) -> SpeakerTurn { SpeakerTurn(start: a, end: b, speaker: s) }

    // MARK: Assignment

    func testMajorityOverlapWins() {
        let turns = [turn(0, 5, 0), turn(5, 10, 1)]
        let out = SpeakerAssignment.assign(turns, to: [seg(0.5, 4), seg(4.5, 9), seg(9.5, 12)])
        XCTAssertEqual(out.map(\.speaker), ["Спикер 1", "Спикер 2", "Спикер 2"])
        XCTAssertEqual(out.map(\.text), ["Фраза.", "Фраза.", "Фраза."])
    }

    func testOverlapIsSummedAcrossTurns() {
        // Speaker 1 has two pieces (1.5 s + 1.5 s) vs speaker 0 with 2 s.
        let turns = [turn(0, 2, 0), turn(2, 3.5, 1), turn(3.5, 5.5, 0), turn(5.5, 7, 1)]
        let out = SpeakerAssignment.assign(turns, to: [seg(0, 1), seg(1.5, 7)], minTurn: 0)
        // First phrase: speaker 0 → «Спикер 1». Second: 0 has 0.5 + 2 = 2.5 s,
        // 1 has 1.5 + 1.5 = 3 s → «Спикер 2».
        XCTAssertEqual(out.map(\.speaker), ["Спикер 1", "Спикер 2"])
    }

    func testNumberingFollowsFirstAppearanceInTranscript() {
        let turns = [turn(0, 5, 3), turn(5, 10, 0), turn(10, 15, 3), turn(15, 20, 7)]
        let out = SpeakerAssignment.assign(turns, to: [seg(1, 4), seg(6, 9), seg(11, 14), seg(16, 19)])
        XCTAssertEqual(out.map(\.speaker), ["Спикер 1", "Спикер 2", "Спикер 1", "Спикер 3"])
    }

    func testSpeakerWithoutPhrasesTakesNoNumber() {
        let turns = [turn(0, 5, 0), turn(20, 25, 1), turn(30, 35, 2)]
        let out = SpeakerAssignment.assign(turns, to: [seg(1, 4), seg(31, 34)])
        XCTAssertEqual(out.map(\.speaker), ["Спикер 1", "Спикер 2"])
    }

    func testNoOverlapUsesNearestTurnWithinLimit() {
        let turns = [turn(0, 5, 0), turn(10, 15, 1)]
        let out = SpeakerAssignment.assign(turns, to: [seg(6, 6.5), seg(8.5, 9.5), seg(30, 31)])
        XCTAssertEqual(out[0].speaker, "Спикер 1")  // 1 s after speaker 0
        XCTAssertEqual(out[1].speaker, "Спикер 2")  // 0.5 s before speaker 1
        XCTAssertNil(out[2].speaker)                // 15 s away from anyone
    }

    func testNoTurnsClearsSpeakers() {
        var s = seg(0, 1)
        s.speaker = "Старое"
        XCTAssertNil(SpeakerAssignment.assign([], to: [s])[0].speaker)
    }

    // MARK: Smoothing

    func testMicroTurnIsAbsorbed() {
        let out = SpeakerAssignment.smooth([turn(0, 5, 0), turn(5, 5.4, 1), turn(5.4, 10, 0)])
        XCTAssertEqual(out, [turn(0, 10, 0)])
    }

    func testFragmentsJoinBeforeMicroCheck() {
        // Two 0.4 s pieces of speaker 1 make one 0.9 s turn — not a micro-turn.
        let out = SpeakerAssignment.smooth([turn(0, 0.4, 1), turn(0.5, 0.9, 1), turn(1, 5, 0)])
        XCTAssertEqual(out, [turn(0, 0.9, 1), turn(1, 5, 0)])
    }

    func testLongPauseKeepsTurnsApart() {
        let out = SpeakerAssignment.smooth([turn(0, 2, 0), turn(4, 6, 0)])
        XCTAssertEqual(out, [turn(0, 2, 0), turn(4, 6, 0)])
    }

    func testAllMicroTurnsAreKept() {
        let out = SpeakerAssignment.smooth([turn(0, 0.3, 0), turn(2, 2.3, 1)])
        XCTAssertEqual(out.count, 2)
    }

    func testInvalidTurnsAreDropped() {
        let out = SpeakerAssignment.smooth([turn(3, 2, 0), turn(.nan, 1, 0), turn(0, 2, 1)])
        XCTAssertEqual(out, [turn(0, 2, 1)])
    }

    func testMicroTurnDoesNotStealPhrase() {
        // A 0.3 s blip of speaker 1 in the middle of speaker 0.
        let turns = [turn(0, 3, 0), turn(3, 3.3, 1), turn(3.3, 6, 0)]
        let out = SpeakerAssignment.assign(turns, to: [seg(3, 3.3)])
        XCTAssertEqual(out[0].speaker, "Спикер 1")
        XCTAssertEqual(SpeakerAssignment.speakers(in: out).count, 1)
    }

    // MARK: Renaming

    func testRename() {
        let turns = [turn(0, 5, 0), turn(5, 10, 1)]
        let out = SpeakerAssignment.assign(turns, to: [seg(1, 4), seg(6, 9)], names: ["Спикер 2": "  Анна\n "])
        XCTAssertEqual(out.map(\.speaker), ["Спикер 1", "Анна"])
    }

    func testRenameSwapAndIgnoreEmpty() {
        var a = seg(0, 1); a.speaker = "Спикер 1"
        var b = seg(1, 2); b.speaker = "Спикер 2"
        var c = seg(2, 3); c.speaker = "Спикер 3"
        let out = SpeakerAssignment.rename([a, b, c], ["Спикер 1": "Спикер 2", "Спикер 2": "Спикер 1", "Спикер 3": "   "])
        XCTAssertEqual(out.map(\.speaker), ["Спикер 2", "Спикер 1", "Спикер 3"])
    }

    func testTranscriptHelpers() {
        let tr = Transcript(sourceName: "x.webm", duration: 20, engine: "test",
                            segments: [seg(1, 4), seg(6, 9), seg(11, 14)])
        let labelled = tr.assigningSpeakers([turn(0, 5, 1), turn(5, 10, 0), turn(10, 15, 1)])
        XCTAssertEqual(labelled.speakers, ["Спикер 1", "Спикер 2"])
        let renamed = labelled.renamingSpeakers(["Спикер 1": "Мария"])
        XCTAssertEqual(renamed.segments.map(\.speaker), ["Мария", "Спикер 2", "Мария"])
        XCTAssertEqual(renamed.speakers, ["Мария", "Спикер 2"])
    }

    func testSpeakerSurvivesJSONRoundTrip() throws {
        var s = seg(0, 1); s.speaker = "Спикер 1"
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: data), s)
    }

    // MARK: Cross-window linking

    func item(_ w: Int, _ e: [Float], _ weight: Double = 10) -> SpeakerLinking.Item {
        SpeakerLinking.Item(window: w, embedding: e, weight: weight)
    }

    func testLinkingJoinsSameVoiceAcrossWindows() {
        let labels = SpeakerLinking.cluster([
            item(0, [1, 0, 0]), item(0, [0, 1, 0]),
            item(1, [0.9, 0.1, 0]), item(1, [0.1, 0.9, 0]),
            item(2, [0, 0.05, 1]),
        ])
        XCTAssertEqual(labels[0], labels[2])
        XCTAssertEqual(labels[1], labels[3])
        XCTAssertNotEqual(labels[0], labels[1])
        XCTAssertNotEqual(labels[4], labels[0])
        XCTAssertNotEqual(labels[4], labels[1])
        XCTAssertEqual(Set(labels), [0, 1, 2]) // dense ids
    }

    func testLinkingRespectsSameWindowSeparation() {
        // cos = 0.6 → distance 0.4: joined across windows, kept apart inside one.
        XCTAssertNotEqual(Set(SpeakerLinking.cluster([item(0, [1, 0]), item(0, [0.6, 0.8])])).count, 1)
        XCTAssertEqual(Set(SpeakerLinking.cluster([item(0, [1, 0]), item(1, [0.6, 0.8])])).count, 1)
        // cos = 0.8 → distance 0.2: an over-split inside one window is repaired.
        XCTAssertEqual(Set(SpeakerLinking.cluster([item(0, [1, 0]), item(0, [0.8, 0.6])])).count, 1)
    }

    func testLinkingWithKnownCount() {
        let items = [item(0, [1, 0, 0]), item(0, [0, 1, 0]), item(1, [0, 0, 1]), item(1, [0.95, 0.05, 0])]
        XCTAssertEqual(Set(SpeakerLinking.cluster(items, numSpeakers: 1)).count, 1)
        XCTAssertEqual(Set(SpeakerLinking.cluster(items, numSpeakers: 3)).count, 3)
        let three = SpeakerLinking.cluster(items, numSpeakers: 3)
        XCTAssertEqual(three[0], three[3])
        XCTAssertEqual(Set(SpeakerLinking.cluster(items, numSpeakers: 10)).count, 4)
    }

    func testLinkingEdgeCases() {
        XCTAssertEqual(SpeakerLinking.cluster([]), [])
        XCTAssertEqual(SpeakerLinking.cluster([item(0, [1, 0])]), [0])
        // Zero / non-finite embeddings never join anything automatically.
        XCTAssertEqual(Set(SpeakerLinking.cluster([item(0, [0, 0]), item(1, [.nan, 0]), item(2, [1, 0])])).count, 3)
    }

    // MARK: Clean-up (over-splitting)

    func sp(_ e: [Float]?, _ seconds: Double) -> SpeakerCleanup.Speaker {
        SpeakerCleanup.Speaker(embedding: e, seconds: seconds)
    }

    func cleanup(_ s: [SpeakerCleanup.Speaker], _ recording: Double = 120,
                 _ rules: SpeakerCleanup.Rules = SpeakerCleanup.Rules()) -> [Int] {
        SpeakerCleanup.plan(s, recordingSeconds: recording, rules: rules)
    }

    func testCleanupMergesSameVoiceKeepsDifferentOnes() {
        XCTAssertEqual(cleanup([sp([1, 0], 20), sp([0.8, 0.6], 15)]), [0, 0])      // cos 0.8
        XCTAssertEqual(cleanup([sp([1, 0], 20), sp([0, 1], 20)]), [0, 1])          // cos 0
        XCTAssertEqual(cleanup([sp([1, 0], 20), sp([0.5, 0.866], 20)]), [0, 1])    // cos 0.5
        XCTAssertEqual(cleanup([]), [])
        XCTAssertEqual(cleanup([sp([1, 0], 5)]), [0])
    }

    func testShortRecordingNeedsStrongerEvidence() {
        let pair = [sp([1, 0], 15), sp([0.58, 0.8146], 15)]                         // cos 0.58
        XCTAssertEqual(cleanup(pair, 30), [0, 0])
        XCTAssertEqual(cleanup(pair, 120), [0, 1])
    }

    func testTinySpeakersJoinUnlessClearlyDifferent() {
        // C (3 s) sounds like A → joins; D (3 s) is unlike anyone → stays.
        XCTAssertEqual(cleanup([sp([1, 0], 60), sp([0, 1], 60), sp([0.9, 0.436], 3), sp([-1, 0], 3)]), [0, 1, 0, 2])
        // E has 2.4 % of the speech and is moderately similar to A → joins.
        XCTAssertEqual(cleanup([sp([1, 0], 100), sp([0, 1], 100), sp([0.5, -0.866], 5)], 300), [0, 1, 0])
        // Under 1.5 s an embedding is not trusted: joins the nearest/largest.
        XCTAssertEqual(cleanup([sp([1, 0], 60), sp([-1, 0], 50), sp([0, 1], 1)]), [0, 1, 0])
        // No embedding at all → joins the largest speaker.
        XCTAssertEqual(cleanup([sp([1, 0], 30), sp(nil, 10)]), [0, 0])
    }

    func testCleanupExactCountAndCap() {
        let three = [sp([1, 0, 0], 20), sp([0, 1, 0], 20), sp([0, 0, 1], 20)]
        XCTAssertEqual(Set(cleanup(three, 120, SpeakerCleanup.Rules(numSpeakers: 2))).count, 2)
        XCTAssertEqual(Set(cleanup(three, 120, SpeakerCleanup.Rules(numSpeakers: 5))).count, 3)
        // With a known count, similar voices are not merged automatically.
        let similar = [sp([1, 0], 20), sp([0.99, 0.14], 20), sp([0, 1], 20)]
        XCTAssertEqual(cleanup(similar, 120, SpeakerCleanup.Rules(numSpeakers: 3)), [0, 1, 2])
        XCTAssertEqual(cleanup(similar), [0, 0, 1])
        // A speaker without embedding is the first to go when counting down.
        XCTAssertEqual(cleanup([sp([1, 0], 20), sp([0, 1], 20), sp(nil, 20)], 120, SpeakerCleanup.Rules(numSpeakers: 2)), [0, 1, 0])
        // Never more than maxSpeakers.
        let twelve = (0 ..< 12).map { i -> SpeakerCleanup.Speaker in
            var e = [Float](repeating: 0, count: 12)
            e[i] = 1
            return sp(e, 20)
        }
        XCTAssertEqual(Set(cleanup(twelve)).count, 10)
        XCTAssertEqual(Set(cleanup(twelve, 240, SpeakerCleanup.Rules(maxSpeakers: 4))).count, 4)
    }

    func testCleanupNumbersByFirstMember() {
        XCTAssertEqual(cleanup([sp([0, 1], 20), sp([1, 0], 20), sp([0.95, 0.31], 20)]), [0, 1, 1])
    }
}
