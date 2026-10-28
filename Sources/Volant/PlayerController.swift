import AppKit
import WebKit
import VolantCore

/// Owns the WKWebView used to render the recording and exposes a small,
/// typed API over it. All web content is local; the web view is configured
/// to be as inert as possible.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var rate: Double = 1
    @Published var volume: Double = 1
    @Published var videoSize: CGSize = .zero
    @Published var isReady = false
    @Published var mediaErrorCode = 0
    /// Short event log for diagnostics (self-test report).
    private(set) var diagnostics: [String] = []
    private var seenMessageTypes = Set<String>()
    private var crashCount = 0

    func log(_ s: String) {
        if diagnostics.count < 300 { diagnostics.append(s) }
    }

    let webView: WKWebView
    private let world = WKContentWorld.world(name: "volant")
    private var schemeHandler: MediaSchemeHandler?
    private let fileURL: URL?
    /// When the canvas path is unavailable we fall back to native snapshots.
    private(set) var usesSnapshotFallback = false

    init(fileURL: URL?, audioOnly: Bool) {
        self.fileURL = fileURL
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = false // page JS off; our user script runs in its own world
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        if #available(macOS 14.0, *) { config.allowsInlinePredictions = false }

        let handler = MediaSchemeHandler(fileURL: fileURL, audioOnly: audioOnly)
        var pendingLog: [String] = []
        handler.logger = { pendingLog.append($0) }
        config.setURLSchemeHandler(handler, forURLScheme: PlayerPage.scheme)

        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: PlayerPage.script, injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true, in: world))
        config.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsMagnification = false
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsLinkPreview = false
        wv.underPageBackgroundColor = .black
        if #available(macOS 13.3, *) { wv.isInspectable = false }
        webView = wv
        schemeHandler = handler
        super.init()

        ucc.add(WeakMessageHandler(self), contentWorld: world, name: "volant")
        diagnostics = pendingLog
        handler.logger = { [weak self] s in self?.log(s) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        guard fileURL != nil else { return }
        Task { [weak self] in
            // Defence in depth on top of CSP and the navigation policy: the
            // content blocker refuses every load that is not our own scheme.
            let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"# +
                #"{"trigger":{"url-filter":"^volant-media:"},"action":{"type":"ignore-previous-rules"}}]"#
            if let list = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "volant-offline-v1", encodedContentRuleList: rules) {
                ucc.add(list)
                self?.log("rules:installed")
            } else {
                self?.log("rules:failed")
            }
            self?.webView.load(URLRequest(url: PlayerPage.pageURL))
        }
    }

    func tearDown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: Commands

    private func call(_ js: String, _ args: [String: Any] = [:]) {
        webView.callAsyncJavaScript(js + "; return 0", arguments: args, in: nil, in: world, completionHandler: nil)
    }

    /// Runs `body` (an async JS function body) in our isolated world.
    private func eval(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: args, in: nil, in: world) { result in
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }
    func play() { call("volant.play()") }
    func pause() { call("volant.pause()") }
    func seek(to t: Double) {
        let clamped = max(0, min(t, duration > 0 ? duration : t))
        currentTime = clamped
        call("volant.seek(t)", ["t": clamped])
    }
    func skip(_ delta: Double) { seek(to: currentTime + delta) }
    func setRate(_ r: Double) { rate = r; call("volant.rate(r)", ["r": r]) }
    func setVolume(_ v: Double) { volume = v; call("volant.volume(x)", ["x": v]) }

    // MARK: Frame sampling (used by key-frame analysis)

    enum SampleError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let s) = self { return s }; return nil }
    }

    func waitUntilReady(timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady {
            if mediaErrorCode != 0 { throw SampleError.failed("Видео не воспроизводится на этом Mac (код \(mediaErrorCode)).") }
            if Date() > deadline { throw SampleError.failed("Видео не загрузилось.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func sample(at t: Double) async throws -> FrameThumb {
        let result = try await eval("return await volant.sample(t)", ["t": t])
        guard let dict = result as? [String: Any] else { throw SampleError.failed("Не удалось получить кадр.") }
        // btoa() maps each byte to one Latin-1 character, so base64-decoding
        // yields the raw luma bytes.
        if let b64 = dict["thumb"] as? String, let data = Data(base64Encoded: b64), let thumb = FrameThumb(luma: [UInt8](data)) {
            return thumb
        }
        if dict["tainted"] as? Bool == true {
            usesSnapshotFallback = true
            guard let img = try await snapshotVideo(), let thumb = Self.thumb(from: img) else {
                throw SampleError.failed("Не удалось снять кадр.")
            }
            return thumb
        }
        throw SampleError.failed("Не удалось получить кадр.")
    }

    /// Full-resolution image of the frame currently shown.
    func grabFrame() async throws -> CGImage? {
        if !usesSnapshotFallback,
           let s = try await eval("return await volant.grab()") as? String,
           let comma = s.firstIndex(of: ","), s.hasPrefix("data:image/png;base64"),
           let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
           data.count < 64 * 1024 * 1024,
           let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(src) == 1,
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        return try await snapshotVideo()
    }

    private func snapshotVideo() async throws -> CGImage? {
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: cfg)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func thumb(from image: CGImage) -> FrameThumb? {
        let w = FrameThumb.width, h = FrameThumb.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? FrameThumb(luma: px) : nil
    }

    // MARK: State updates from the page

    fileprivate func handle(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        if seenMessageTypes.insert(type).inserted || type == "error" { log("js:\(type) rs=\(m["err"] ?? 0)") }
        func num(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        let t = num("t"), d = num("d")
        if t.isFinite { currentTime = t }
        if d.isFinite, d > 0 { duration = max(duration, d) }
        isPlaying = !(m["paused"] as? Bool ?? true)
        let w = num("w"), h = num("h")
        if w > 0, h > 0, w <= 16384, h <= 16384 { videoSize = CGSize(width: w, height: h) }
        let err = Int(num("err"))
        if err != 0 { mediaErrorCode = err }
        if ["loadeddata", "canplay", "playing", "seeked"].contains(type) { isReady = true }
        if type == "ended" { isPlaying = false }
    }
}

extension PlayerController: WKNavigationDelegate, WKUIDelegate {
    /// Only our own page may ever be loaded in this web view.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let ok = action.request.url == PlayerPage.pageURL && action.targetFrame?.isMainFrame == true
        return ok ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { log("nav:finish") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("nav:fail \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("nav:failProvisional \(error)")
    }

    /// JS-side state for diagnostics.
    func debugInfo() async -> String {
        let r = try? await eval("return JSON.stringify(volant.info())")
        return (r as? String) ?? "unavailable"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("webcontent:terminated")
        isReady = false
        // Recover from a crashed renderer at most twice, then give up with an
        // error instead of looping on a file that keeps crashing it.
        crashCount += 1
        if crashCount <= 2, fileURL != nil {
            webView.load(URLRequest(url: PlayerPage.pageURL))
        } else {
            mediaErrorCode = -1
        }
    }
}

/// Breaks the retain cycle WKUserContentController → handler → controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: PlayerController?
    init(_ target: PlayerController) { self.target = target }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // Accept messages only from our own page in the main frame.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == PlayerPage.scheme,
              message.frameInfo.securityOrigin.host == PlayerPage.host else { return }
        let body = message.body
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
