import Foundation

/// Removes Meteora's own leftovers in the temporary folder: mail drafts with
/// the transcript attached and playback copies of recordings. They are only
/// needed for a short while, but a crash or a mail app that keeps the
/// draft open would otherwise leave meeting content behind.
enum TempCleanup {
    static let prefixes = ["meteora-mail-", "meteora-play-"]

    static func run(olderThan age: TimeInterval = 12 * 3600) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isSymbolicLinkKey]
        guard let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: keys) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items where prefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, let modified = values?.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: item)
        }
    }
}
