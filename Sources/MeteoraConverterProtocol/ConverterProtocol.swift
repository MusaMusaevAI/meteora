import Foundation

/// Bundle identifier (and XPC service name) of the isolated converter:
/// `Meteora.app/Contents/XPCServices/com.musamusaev.meteora.converter.xpc`.
public let meteoraConverterServiceName = "com.musamusaev.meteora.converter"

/// Result codes passed back in `ConverterServiceProtocol.convert` replies.
/// Plain integers keep the XPC interface free of custom classes.
public enum ConverterResultCode: Int {
    case ok = 0
    /// The client called `cancel()` (or the connection went away).
    case cancelled = 1
    /// FFmpeg doesn't know the container or codec, or the file has no audio/video.
    case unsupported = 2
    /// FFmpeg failed while converting (damaged file, encoder failure…).
    case failed = 3
    /// The service couldn't start FFmpeg (missing binary, spawn failure).
    case internalError = 4
    /// The file handles aren't usable: input must be a readable regular file,
    /// output a writable file or pipe.
    case badHandles = 5
    /// Another conversion is already running on this connection.
    case busy = 6
}

/// Implemented by the app; the service calls it on the same connection to
/// report progress.
@objc(MeteoraConverterClientProtocol)
public protocol ConverterClientProtocol {
    /// `fraction` is 0…1, or -1 while the total duration is unknown.
    func converterDidProgress(_ fraction: Double)
}

/// Implemented by the XPC service. One connection = one conversion.
///
/// The service never receives a path: the app opens the source itself (it has
/// the user's permission) and passes a read-only `FileHandle`; it creates the
/// destination in its own temporary directory and passes a writable
/// `FileHandle`. NSXPC transfers `FileHandle` as a file descriptor, so the
/// sandboxed service (and FFmpeg, which inherits its sandbox) can read and
/// write exactly these two files and nothing else.
@objc(MeteoraConverterServiceProtocol)
public protocol ConverterServiceProtocol {
    /// Converts `input` into MP4 written to `output`: H.264 + AAC when
    /// `keepVideo` is true and the source has video, otherwise AAC only.
    /// `reply(hasVideo, code, detail)`: `code` is a `ConverterResultCode`
    /// raw value; `detail` is a short technical log tail for diagnostics
    /// (never shown to the user verbatim).
    func convert(_ input: FileHandle, output: FileHandle, keepVideo: Bool,
                 withReply reply: @escaping (Bool, Int, String?) -> Void)

    /// Stops the running conversion (FFmpeg is terminated). The pending
    /// `convert` reply then arrives with `ConverterResultCode.cancelled`.
    func cancel()

    /// Self-test only: checks that the sandbox really isolates the service
    /// and FFmpeg. Tries to open `path` (a file the app *can* read) from the
    /// service and from FFmpeg, and to open a TCP connection. Every flag is
    /// true when the corresponding attempt was blocked.
    func probeIsolation(_ path: String,
                        withReply reply: @escaping (_ serviceFileBlocked: Bool, _ ffmpegFileBlocked: Bool,
                                                    _ networkBlocked: Bool, _ detail: String) -> Void)
}
