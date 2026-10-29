import Foundation

/// GigaAM-v3's SentencePiece tokenizer, read from the verified
/// `tokenizer.model`, prepared for sherpa-onnx recognizer hints.
///
/// sherpa-onnx turns each hint into model tokens with its own small
/// SentencePiece encoder (simple-sentencepiece): a Viterbi search for the
/// highest total piece score over a "piece score" vocabulary. For a
/// *unigram* model that is exactly SentencePiece's own segmentation, so the
/// hint becomes the same pieces the model was trained to emit («▁П Д С»).
/// The sherpa-onnx export ships tokens.txt without scores, so the scores are
/// taken from Sber's original tokenizer and checked against tokens.txt
/// piece by piece: a different tokenizer is refused, never guessed.
struct HintTokenizer {
    enum Failure: Error, CustomStringConvertible {
        case malformed(String)
        case notUnigram(Int)
        case mismatch(String)

        var description: String {
            switch self {
            case .malformed(let s): return "tokenizer.model: \(s)"
            case .notUnigram(let t): return "tokenizer.model: model_type \(t), not unigram"
            case .mismatch(let s): return "tokenizer.model ≠ tokens.txt: \(s)"
            }
        }
    }

    let pieces: [String]
    let scores: [Float]
    /// Every Unicode scalar that occurs in some piece (except «▁»): a hint
    /// with any other character would become <unk>.
    let scalars: Set<Unicode.Scalar>

    /// Parses a SentencePiece `ModelProto` (protobuf) — only the fields we
    /// need: pieces (1: piece, score) and trainer_spec.model_type.
    init(modelData: Data) throws {
        let bytes = [UInt8](modelData)
        var reader = ProtoReader(bytes: bytes, position: 0, end: bytes.count)
        var pieces: [String] = []
        var scores: [Float] = []
        var modelType = 1 // proto default: UNIGRAM
        while let key = try reader.key() {
            if key.field == 1, key.wire == 2 {
                let range = try reader.lengthDelimited()
                var sub = ProtoReader(bytes: bytes, position: range.lowerBound, end: range.upperBound)
                var piece: String?
                var score: Float = 0
                while let k = try sub.key() {
                    if k.field == 1, k.wire == 2 {
                        let r = try sub.lengthDelimited()
                        piece = String(decoding: bytes[r], as: UTF8.self)
                    } else if k.field == 2, k.wire == 5 {
                        let bits = try sub.fixed32()
                        score = Float(bitPattern: bits)
                    } else {
                        try sub.skip(k.wire)
                    }
                }
                guard let p = piece else { throw Failure.malformed("piece without text") }
                pieces.append(p)
                scores.append(score)
            } else if key.field == 2, key.wire == 2 {
                let range = try reader.lengthDelimited()
                var sub = ProtoReader(bytes: bytes, position: range.lowerBound, end: range.upperBound)
                while let k = try sub.key() {
                    if k.field == 3, k.wire == 0 {
                        let v = try sub.varint()
                        modelType = Int(truncatingIfNeeded: v)
                    } else {
                        try sub.skip(k.wire)
                    }
                }
            } else {
                try reader.skip(key.wire)
            }
        }
        guard modelType == 1 else { throw Failure.notUnigram(modelType) }
        guard !pieces.isEmpty else { throw Failure.malformed("no pieces") }
        // The vocabulary file is "piece score" per line: a piece must be a
        // single non-empty token, a score a finite number (sherpa-onnx exits
        // the process on a malformed line).
        for (p, s) in zip(pieces, scores) {
            guard !p.isEmpty, !p.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw Failure.malformed("piece with whitespace")
            }
            guard s.isFinite else { throw Failure.malformed("score \(s)") }
        }
        guard Set(pieces).count == pieces.count else { throw Failure.malformed("duplicate pieces") }
        self.pieces = pieces
        self.scores = scores
        var set = Set<Unicode.Scalar>()
        for p in pieces where !(p.hasPrefix("<") && p.hasSuffix(">")) {
            for u in p.unicodeScalars where u != "\u{2581}" { set.insert(u) }
        }
        scalars = set
    }

    /// Checks that these are exactly the model's output tokens: tokens.txt
    /// is "piece id" per line, pieces in id order, plus the trailing <blk>.
    func check(tokensFile: URL) throws {
        let text = try String(contentsOf: tokensFile, encoding: .utf8)
        var tokens: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.lastIndex(of: " ") else { throw Failure.mismatch("line «\(line)»") }
            tokens.append(String(line[line.startIndex ..< space]))
        }
        guard tokens.count == pieces.count + 1, tokens.last == "<blk>" else {
            throw Failure.mismatch("\(pieces.count) pieces, \(tokens.count) tokens")
        }
        for i in pieces.indices where pieces[i] != tokens[i] {
            throw Failure.mismatch("id \(i): «\(pieces[i])» vs «\(tokens[i])»")
        }
    }

    /// The vocabulary in simple-sentencepiece format ("piece score\n").
    var vocabText: String {
        var s = ""
        for (p, sc) in zip(pieces, scores) {
            s += p
            s += " "
            s += String(describing: sc)
            s += "\n"
        }
        return s
    }

    /// True if every character of `phrase` exists in the vocabulary.
    func canEncode(_ phrase: String) -> Bool {
        for u in phrase.unicodeScalars where u != " " {
            if !scalars.contains(u) { return false }
        }
        return true
    }
}

/// Minimal protobuf wire-format reader (bounds-checked).
struct ProtoReader {
    struct Key {
        var field: Int
        var wire: Int
    }

    let bytes: [UInt8]
    var position: Int
    let end: Int

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end, shift < 64 else { throw HintTokenizer.Failure.malformed("varint") }
            let b = bytes[position]
            position += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func key() throws -> Key? {
        guard position < end else { return nil }
        let k = try varint()
        return Key(field: Int(truncatingIfNeeded: k >> 3), wire: Int(truncatingIfNeeded: k & 7))
    }

    mutating func lengthDelimited() throws -> Range<Int> {
        let n = try varint()
        guard n <= UInt64(end - position) else { throw HintTokenizer.Failure.malformed("length") }
        let start = position
        position += Int(n)
        return start ..< position
    }

    mutating func fixed32() throws -> UInt32 {
        guard end - position >= 4 else { throw HintTokenizer.Failure.malformed("fixed32") }
        let b0 = UInt32(bytes[position])
        let b1 = UInt32(bytes[position + 1]) << 8
        let b2 = UInt32(bytes[position + 2]) << 16
        let b3 = UInt32(bytes[position + 3]) << 24
        position += 4
        return b0 | b1 | b2 | b3
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1:
            guard end - position >= 8 else { throw HintTokenizer.Failure.malformed("fixed64") }
            position += 8
        case 2: _ = try lengthDelimited()
        case 5: _ = try fixed32()
        default: throw HintTokenizer.Failure.malformed("wire type \(wire)")
        }
    }
}
