import Foundation
import MeteoraCore

/// Formats macOS can't open itself go through the isolated converter
/// (an XPC service running FFmpeg with no file or network access).
enum MediaConverterSupport {
    /// Extensions that always need conversion.
    static var extensions: [String] { MediaConverter.convertedExtensions }

    static func needsConversion(_ url: URL) async -> Bool { await MediaConverter.needsConversion(url) }

    /// Returns a temporary file macOS can play. The caller deletes it.
    static func convert(_ url: URL, keepVideo: Bool,
                        progress: @escaping @Sendable (Double) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {
        try await MediaConverter().convert(url, keepVideo: keepVideo, progress: progress, isCancelled: isCancelled)
    }
}
