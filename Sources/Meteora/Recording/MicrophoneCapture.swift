import Foundation
import AVFoundation
import CoreMedia

/// Something the engine can stop: the microphone or the system-audio tap.
protocol CaptureSource: AnyObject {
    func stop()
}

/// Records one microphone through AVCaptureSession. This path works for every
/// input macOS exposes as a capture device — the built-in mic, AirPods and
/// other Bluetooth headsets, USB microphones and an iPhone via Continuity.
///
/// Sample buffers are delivered as Float32 PCM on `deliveryQueue` (the
/// recorder's processing queue); format conversion happens there, never on
/// an audio thread. `start()` and `stop()` block, so call them off the main
/// thread.
final class MicrophoneCapture: NSObject, CaptureSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let deviceID: String
    let deviceName: String
    /// Called (on an arbitrary queue) if the session fails while running.
    var onRuntimeError: (@Sendable (String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let deliver: (AVAudioPCMBuffer) -> Void
    private var errorObserver: NSObjectProtocol?

    init(device: AVCaptureDevice, deliveryQueue: DispatchQueue, deliver: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.deviceID = device.uniqueID
        self.deviceName = device.localizedName
        self.deliver = deliver
        super.init()

        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw RecorderError.microphoneUnavailable(device.localizedName)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw RecorderError.microphoneUnavailable(device.localizedName) }
        session.addInput(input)
        // Float32, non-interleaved, at the device's own rate and channel
        // count; the processing queue resamples to 48 kHz mono.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard session.canAddOutput(output) else { throw RecorderError.microphoneUnavailable(device.localizedName) }
        session.addOutput(output)
    }

    func start() throws {
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onRuntimeError?(error?.localizedDescription ?? "ошибка устройства")
        }
        session.startRunning()
        guard session.isRunning else {
            stop()
            throw RecorderError.microphoneUnavailable(deviceName)
        }
    }

    func stop() {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        if session.isRunning { session.stopRunning() }
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        deliver(buffer)
    }

    /// Copies a CMSampleBuffer of linear PCM into an AVAudioPCMBuffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames < 1 << 20,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
