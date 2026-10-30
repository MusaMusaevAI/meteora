import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Records what the Mac plays (a meeting in the browser, Zoom, Telemost)
/// with a Core Audio process tap — macOS 14.2+.
///
/// A stereo global tap that excludes Meteora itself is attached to a private
/// aggregate device; its IO block only copies the samples and hands them to
/// the processing queue. Nothing else runs on the IO path.
///
/// Permission: the first tap triggers the system prompt for "System Audio
/// Recording" (NSAudioCaptureUsageDescription). There is no public way to ask
/// in advance or to read the answer; if access is denied the tap delivers
/// silence, which the recorder detects and explains.
@available(macOS 14.2, *)
final class SystemAudioCapture: CaptureSource, @unchecked Sendable {
    /// Called (on a Core Audio queue) when the default output device changes;
    /// the engine rebuilds the tap so it keeps a live clock.
    var onRouteChange: (@Sendable () -> Void)?

    private let deliver: @Sendable (AVAudioPCMBuffer) -> Void
    private let ioQueue = DispatchQueue(label: "com.musamusaev.meteora.recorder.system-io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listening = false

    init(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.deliver = deliver
    }

    deinit { stop() }

    func start() throws {
        // 1. A stereo mix of every process except ours (Meteora may be
        //    playing another recording at the same time).
        let own = CoreAudioProperty.processObject(for: getpid())
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        tapDescription.uuid = UUID()
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { throw RecorderError.systemAudio(err) }
        tapID = tap

        do {
            var asbd = try CoreAudioProperty.read(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0 else { throw RecorderError.systemAudio(-1) }

            // 2. A private aggregate device clocked by the current output,
            //    with the tap as its input.
            let outputUID = try CoreAudioProperty.deviceUID(CoreAudioProperty.defaultOutputDevice())
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meteora — звук Mac",
                kAudioAggregateDeviceUIDKey: "com.musamusaev.meteora.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
            guard err == noErr, device != kAudioObjectUnknown else { throw RecorderError.systemAudio(err) }
            aggregateID = device

            // The tap reports its own format, but samples arrive at the rate
            // of the aggregate device, i.e. of the current output. They differ
            // with Bluetooth headphones (a headset in call mode runs at 16 or
            // 24 kHz): taking the tap's word for it played the other side of
            // the call too fast and garbled. Trust the device.
            let tapRate = asbd.mSampleRate
            if let deviceRate = try? CoreAudioProperty.read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
               deviceRate > 0 {
                asbd.mSampleRate = deviceRate
            }
            recorderLog.info("system audio: tap \(tapRate, privacy: .public) Hz, device \(asbd.mSampleRate, privacy: .public) Hz, \(asbd.mChannelsPerFrame, privacy: .public) ch")
            guard let initialFormat = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError.systemAudio(-1) }
            activeRate = asbd.mSampleRate
            let rate = RateProbe(format: initialFormat)

            // 3. IO block: copy and hand over. If the output device has input
            //    streams of its own, the tap's buffers come last in the list.
            let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let buffersNeeded = interleaved ? 1 : Int(asbd.mChannelsPerFrame)
            let bytesPerFrame = asbd.mBytesPerFrame
            let deliver = self.deliver
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { now, inputData, _, _, _ in
                if let copy = SystemAudioCapture.copy(inputData, format: rate.format, buffers: buffersNeeded, bytesPerFrame: bytesPerFrame) {
                    rate.observe(frames: copy.frameLength, hostTime: now.pointee.mHostTime)
                    deliver(copy)
                }
            }
            guard err == noErr, procID != nil else { throw RecorderError.systemAudio(err) }
            err = AudioDeviceStart(device, procID)
            guard err == noErr else { throw RecorderError.systemAudio(err) }
            addRouteListener()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        removeRouteListener()
        if aggregateID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateID, procID)
            if let procID { _ = AudioDeviceDestroyIOProcID(aggregateID, procID) }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Tears the tap down and builds it again on the current output device.
    func restart() throws {
        stop()
        try start()
    }

    // MARK: IO

    /// Copies the tap's part of an IO buffer list into an owned buffer.
    private static func copy(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat,
                             buffers needed: Int, bytesPerFrame: UInt32) -> AVAudioPCMBuffer? {
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard src.count >= needed, needed > 0 else { return nil }
        let first = src.count - needed
        let frames = src[first].mDataByteSize / bytesPerFrame
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        guard dst.count == needed else { return nil }
        let bytes = frames * bytesPerFrame
        for i in 0 ..< needed {
            guard let s = src[first + i].mData, let d = dst[i].mData,
                  src[first + i].mDataByteSize >= bytes else { return nil }
            memcpy(d, s, Int(bytes))
        }
        out.frameLength = frames
        return out
    }

    // MARK: Output device changes

    /// Also follows the sample rate of the aggregate device: headphones that
    /// switch to call mode change it in the middle of a meeting.
    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var activeRate: Double = 0

    private func addRouteListener() {
        guard !listening else { return }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, systemOutputChanged,
                                                    Unmanaged.passUnretained(self).toOpaque())
        listening = status == noErr
        var rateAddr = CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListener(aggregateID, &rateAddr, aggregateRateChanged,
                                          Unmanaged.passUnretained(self).toOpaque()) == noErr {
            rateListenerDevice = aggregateID
        }
    }

    private func removeRouteListener() {
        guard listening else { return }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, systemOutputChanged,
                                              Unmanaged.passUnretained(self).toOpaque())
        if rateListenerDevice != kAudioObjectUnknown {
            var rateAddr = CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
            _ = AudioObjectRemovePropertyListener(rateListenerDevice, &rateAddr, aggregateRateChanged,
                                                  Unmanaged.passUnretained(self).toOpaque())
            rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
        }
        listening = false
    }

    fileprivate func outputDidChange() {
        onRouteChange?()
    }

    /// Rebuilds only when the rate really moved away from the one in use
    /// (the notification also comes when a device merely re-announces it).
    fileprivate func rateDidChange() {
        guard aggregateID != kAudioObjectUnknown,
              let rate = try? CoreAudioProperty.read(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
              rate > 0, abs(rate - activeRate) > 1 else { return }
        recorderLog.info("system audio: device rate \(self.activeRate, privacy: .public) → \(rate, privacy: .public) Hz")
        onRouteChange?()
    }
}

/// Safety net for the sample rate: counts the frames that really arrive
/// against the host clock. If, after a few seconds, they disagree with the
/// declared rate by more than 4 %, buffers are labelled with the nearest
/// standard rate from then on (the recorder's resampler follows the format).
/// Touched only on the capture's IO queue.
final class RateProbe: @unchecked Sendable {
    private(set) var format: AVAudioFormat
    private var frames: UInt64 = 0
    private var startNanos: UInt64 = 0
    private var checked = false

    static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    init(format: AVAudioFormat) { self.format = format }

    func observe(frames n: AVAudioFrameCount, hostTime: UInt64) {
        guard !checked, hostTime != 0 else { return }
        let nanos = AudioConvertHostTimeToNanos(hostTime)
        if startNanos == 0 { startNanos = nanos; return }
        frames += UInt64(n)
        let seconds = Double(nanos &- startNanos) / 1e9
        guard seconds >= 3 else { return }
        checked = true
        let measured = Double(frames) / seconds
        let declared = format.sampleRate
        guard abs(measured / declared - 1) > 0.04,
              let nearest = Self.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }),
              abs(nearest / measured - 1) < 0.04 else { return }
        var asbd = format.streamDescription.pointee
        asbd.mSampleRate = nearest
        if let corrected = AVAudioFormat(streamDescription: &asbd) {
            recorderLog.error("system audio: declared \(declared, privacy: .public) Hz, measured \(measured, privacy: .public) Hz, using \(nearest, privacy: .public) Hz")
            format = corrected
        }
    }
}

/// C callback for the default-output listener; the client data is the
/// capture object, which removes the listener before it goes away.
private let systemOutputChanged: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    if #available(macOS 14.2, *) {
        Unmanaged<SystemAudioCapture>.fromOpaque(clientData).takeUnretainedValue().outputDidChange()
    }
    return noErr
}

private let aggregateRateChanged: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    if #available(macOS 14.2, *) {
        Unmanaged<SystemAudioCapture>.fromOpaque(clientData).takeUnretainedValue().rateDidChange()
    }
    return noErr
}

// MARK: - Core Audio property helpers

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value.
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var addr = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw RecorderError.systemAudio(err) }
        return value
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let id = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                          initial: AudioDeviceID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else { throw RecorderError.systemAudio(-1) }
        return id
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        var addr = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid else { throw RecorderError.systemAudio(err) }
        return uid.takeRetainedValue() as String
    }

    /// The Core Audio object of a process, if it has one yet.
    @available(macOS 14.2, *)
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &object) { objectPtr in
            withUnsafePointer(to: &qualifier) { qualifierPtr in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<pid_t>.size), qualifierPtr, &size, objectPtr)
            }
        }
        return err == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
