import Foundation
import MeteoraCore

/// Formats macOS can't open itself go through the isolated converter.
/// This façade keeps the model independent of how conversion is done.
enum MediaConverterSupport {
    /// Extensions that always need conversion.
    static var extensions: [String] { [] }

    /// Returns a temporary file macOS can play. The caller deletes it.
    static func convert(_ url: URL, keepVideo: Bool,
                        progress: @escaping @Sendable (Double) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {
        throw MediaError.unplayable
    }
}
