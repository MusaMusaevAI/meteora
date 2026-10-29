import Foundation

/// Tells when the entries of one folder change (a file appears, is renamed
/// or removed). Uses a kqueue vnode source on the folder's descriptor, which
/// works in the sandbox for any folder the app has access to, including
/// iCloud Drive. Growth of an existing file is not reported here: files that
/// are still being written are polled by `AutoFolderStore` until they settle,
/// and every folder is rescanned every 20 seconds as a safety net.
@MainActor
final class AutoFolderWatcher {
    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let onChange: @MainActor () -> Void
    /// The folder itself was deleted or moved away.
    private(set) var folderVanished = false

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    /// Starts watching. Returns false if the folder can't be opened (gone,
    /// or no access); the periodic rescan still runs and retries.
    @discardableResult
    func start() -> Bool {
        stop()
        folderVanished = false
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        fd = descriptor
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                            eventMask: [.write, .extend, .link, .rename, .delete, .revoke],
                                                            queue: .main)
        let handler = onChange
        // The handler holds the source until it is cancelled (dispatch
        // releases handlers on cancel), so there is no lasting cycle.
        src.setEventHandler { [weak self] in
            let events = src.data
            Task { @MainActor in
                if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                    self?.folderVanished = true
                    self?.stop()
                }
                handler()
            }
        }
        src.setCancelHandler {
            _ = close(descriptor)
        }
        source = src
        src.resume()
        return true
    }

    func stop() {
        if let source {
            source.cancel()
        } else if fd >= 0 {
            close(fd)
        }
        source = nil
        fd = -1
    }

    var isRunning: Bool { source != nil }
}
