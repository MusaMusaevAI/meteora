import Foundation
import AVFoundation
import CoreAudio

/// One microphone the Mac can record from: built-in, AirPods and other
/// Bluetooth headsets, USB microphones, or an iPhone nearby (Continuity).
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case builtIn, bluetooth, usb, continuity, virtual, other

        /// SF Symbol for menus.
        var symbol: String {
            switch self {
            case .builtIn: return "laptopcomputer"
            case .bluetooth: return "headphones"
            case .usb: return "cable.connector"
            case .continuity: return "iphone"
            case .virtual: return "waveform"
            case .other: return "mic"
            }
        }
    }

    /// `AVCaptureDevice.uniqueID` — stable across launches and reconnects.
    let id: String
    let name: String
    let kind: Kind
}

/// The list of audio inputs, kept current as devices come and go
/// (AirPods connect mid-meeting, an iPhone walks away, a USB mic is pulled).
@MainActor
final class AudioInputCatalog: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    /// The system's default input right now.
    @Published private(set) var defaultDeviceID: String?

    /// Called with the unique ID of a device that disappeared.
    var onDisconnect: (@MainActor (String) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            Task { @MainActor in
                self?.refresh()
                if let id { self?.onDisconnect?(id) }
            }
        })
    }

    func refresh() {
        devices = Self.discoverDevices()
        defaultDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    func device(_ id: String?) -> AudioInputDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    func isConnected(_ id: String) -> Bool { devices.contains { $0.id == id } }

    /// Display name for a stored choice; nil means "as in System Settings".
    func name(of id: String?) -> String {
        if let d = device(id ?? defaultDeviceID) { return d.name }
        return "Микрофон"
    }

    // MARK: Discovery (no permission needed to list devices)

    nonisolated static func discoverDevices() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified)
        var seen = Set<String>()
        return session.devices.compactMap { d in
            guard seen.insert(d.uniqueID).inserted else { return nil }
            return AudioInputDevice(id: d.uniqueID, name: d.localizedName, kind: kind(of: d))
        }
        .sorted { (rank($0.kind), $0.name) < (rank($1.kind), $1.name) }
    }

    /// The capture device for a stored ID, or the system default for nil.
    nonisolated static func captureDevice(id: String?) -> AVCaptureDevice? {
        if let id { return AVCaptureDevice(uniqueID: id) }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Core Audio process taps (system audio) need macOS 14.2.
    nonisolated static var systemAudioAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private nonisolated static func kind(of d: AVCaptureDevice) -> AudioInputDevice.Kind {
        let t = UInt32(bitPattern: d.transportType)
        switch t {
        case fourCC("ccwd"), fourCC("ccwl"): // Continuity Capture, wired / wireless
            return .continuity
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return .virtual
        default:
            return d.localizedName.localizedCaseInsensitiveContains("iPhone") ? .continuity : .other
        }
    }

    private nonisolated static func rank(_ k: AudioInputDevice.Kind) -> Int {
        switch k {
        case .builtIn: return 0
        case .bluetooth: return 1
        case .continuity: return 2
        case .usb: return 3
        case .other: return 4
        case .virtual: return 5
        }
    }

    private nonisolated static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
