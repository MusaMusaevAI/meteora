import Foundation
import MeteoraCore
import MeteoraASR
import MeteoraLLM

/// State of the downloadable summary model (Qwen3.5-4B, ~2.7 GB), shared by
/// all windows. Mirrors SpeechModelController.
@MainActor
final class SummaryModelController: ObservableObject {
    static let shared = SummaryModelController()

    @Published private(set) var isInstalled = SummaryModelStore.shared.isInstalled
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var token: CancelToken?

    /// One summarizer for the app: the model stays loaded between summaries
    /// until `unload()` (or removal).
    let summarizer = MeetingSummarizer()

    var sizeText: String { FileSizeText.string(SummaryModel.totalSize) }

    func refresh() { isInstalled = SummaryModelStore.shared.isInstalled }

    @discardableResult
    func download() async -> Bool {
        guard progress == nil else { return false }
        let t = CancelToken()
        token = t
        error = nil
        progress = 0
        defer { progress = nil; token = nil; refresh() }
        do {
            try await SummaryModelStore.shared.install(progress: { p in
                Task { @MainActor in if SummaryModelController.shared.progress != nil { SummaryModelController.shared.progress = p } }
            }, isCancelled: { t.isCancelled })
            return true
        } catch ModelError.cancelled {
            return false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Installs from a GGUF the user downloaded themselves (same hash check).
    @discardableResult
    func install(fromFile url: URL) async -> Bool {
        guard progress == nil else { return false }
        error = nil
        progress = 0
        defer { progress = nil; refresh() }
        do {
            try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try SummaryModelStore.shared.installFromLocalFile(url)
            }.value
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func cancel() { token?.cancel() }

    func remove() {
        summarizer.unload()
        try? SummaryModelStore.shared.remove()
        refresh()
    }
}
