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
            guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0,
                  let format = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError.systemAudio(-1) }

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

            // 3. IO block: copy and hand over. If the output device has input
            //    streams of its own, the tap's buffers come last in the list.
            let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let buffersNeeded = interleaved ? 1 : Int(asbd.mChannelsPerFrame)
            let bytesPerFrame = asbd.mBytesPerFrame
            let deliver = self.deliver
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, inputData, _, _, _ in
                if let copy = SystemAudioCapture.copy(inputData, format: format, buffers: buffersNeeded, bytesPerFrame: bytesPerFrame) {
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

    private func addRouteListener() {
        guard !listening else { return }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, systemOutputChanged,
                                                    Unmanaged.passUnretained(self).toOpaque())
        listening = status == noErr
    }

    private func removeRouteListener() {
        guard listening else { return }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, systemOutputChanged,
                                              Unmanaged.passUnretained(self).toOpaque())
        listening = false
    }

    fileprivate func outputDidChange() {
        onRouteChange?()
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
