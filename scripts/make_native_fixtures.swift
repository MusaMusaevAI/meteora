// Builds test media in formats macOS opens itself, for the CI self-test:
//   swift scripts/make_native_fixtures.swift <out-dir> [speech.wav]
// slides.mp4  — H.264 1280×720, three slides with text (8 s each) + AAC audio
// The audio-only fixtures (m4a, flac, wav) are made with afconvert.
import AVFoundation
import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make_native_fixtures <out> [wav]"); exit(2) }
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let wav = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

let width = 1280, height = 720, fps: Int32 = 10, slideSeconds = 8
let slides: [(UInt32, String, String)] = [
    (0x33506B, "Квартальный отчёт", "Выручка выросла на 18 процентов"),
    (0xF3F2EF, "План на ноябрь", "Запуск приложения для iPhone"),
    (0x6B3350, "Вопросы и ответы", "Спасибо за внимание"),
]

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func draw(_ ctx: CGContext, slide: (UInt32, String, String)) {
    ctx.setFillColor(color(slide.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dark = slide.0 != 0xF3F2EF
    let fg = dark ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 1)
    for (text, size, y) in [(slide.1, 72.0, 400.0), (slide.2, 40.0, 300.0)] {
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg.cgColor])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (Double(width) - w) / 2, y: y)
        CTLineDraw(line, ctx)
    }
}

let dest = out.appendingPathComponent("slides.mp4")
try? FileManager.default.removeItem(at: dest)
let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
])
vIn.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
])
writer.add(vIn)

// Audio: the speech sample (looped to the video length) or a quiet tone.
let total = slides.count * slideSeconds
let rate = 48_000.0
var pcm = [Float](repeating: 0, count: Int(rate) * total)
if let wav, let f = try? AVAudioFile(forReading: wav),
   let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
   let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
   let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) {
    try f.read(into: inBuf)
    let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(f.length) * rate / f.processingFormat.sampleRate) + 4096)!
    var given = false
    _ = conv.convert(to: outBuf, error: nil) { _, s in
        if given { s.pointee = .endOfStream; return nil }
        given = true; s.pointee = .haveData; return inBuf
    }
    let src = UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
    if !src.isEmpty { for i in pcm.indices { pcm[i] = src[i % src.count] } }
} else {
    for i in pcm.indices { pcm[i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
}
let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
])
aIn.expectsMediaDataInRealTime = false
writer.add(aIn)

writer.startWriting()
writer.startSession(atSourceTime: .zero)

// Audio format for the PCM chunks
var desc: CMAudioFormatDescription?
var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                       mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                       mBitsPerChannel: 32, mReserved: 0)
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                               magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)

// Feed both inputs the way AVAssetWriter expects: each asks for data on its
// own queue whenever it can take more, so neither stalls waiting for the
// other to catch up.
let frames = total * Int(fps)
let group = DispatchGroup()
var frameIndex = 0
group.enter()
vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "video")) {
    while vIn.isReadyForMoreMediaData {
        if frameIndex >= frames { vIn.markAsFinished(); group.leave(); return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let pb else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(ctx, slide: slides[min(slides.count - 1, frameIndex / (slideSeconds * Int(fps)))])
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: fps))
        frameIndex += 1
    }
}
var pos = 0
group.enter()
aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "audio")) {
    while aIn.isReadyForMoreMediaData {
        if pos >= pcm.count { aIn.markAsFinished(); group.leave(); return }
        let n = min(1024, pcm.count - pos)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: n * 4, flags: 0, blockBufferOut: &block)
        pcm.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + pos * 4, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!,
                                                             sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: CMTimeScale(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        aIn.append(sb!)
        pos += n
    }
}
if group.wait(timeout: .now() + 120) == .timedOut { print("writer stalled"); exit(1) }

let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed { print("writer failed: \(writer.error?.localizedDescription ?? "?")"); exit(1) }
print("wrote \(dest.path)")
