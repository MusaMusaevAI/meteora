import Foundation
import WebKit
import VolantCore

/// The page that hosts the <video> element. It contains no script at all:
/// the strict Content-Security-Policy forbids any script in the page, and
/// all our logic runs as a user script in an isolated content world.
enum PlayerPage {
    static let scheme = "volant-media"
    static let host = "local"
    static var pageURL: URL { URL(string: "\(scheme)://\(host)/player.html")! }
    static var mediaURLString: String { "\(scheme)://\(host)/media.webm" }

    static let html = """
    <!doctype html>
    <html lang="ru"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src volant-media:; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
    <style>
      html,body{margin:0;height:100%;background:#000;overflow:hidden;-webkit-user-select:none;cursor:default}
      video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}
    </style></head>
    <body><video id="v" preload="auto" playsinline disablepictureinpicture disableremoteplayback></video></body></html>
    """

    /// Runs in the isolated "volant" content world. Exposes a small API
    /// to native code via callAsyncJavaScript and posts state updates to
    /// the native message handler (registered only in this world).
    static let script = """
    (() => {
      const v = document.getElementById('v');
      const post = (m) => { try { window.webkit.messageHandlers.volant.postMessage(m); } catch (e) {} };
      const state = (type) => post({type, t: v.currentTime || 0, d: isFinite(v.duration) ? v.duration : 0,
        paused: v.paused, rate: v.playbackRate, vol: v.volume, w: v.videoWidth || 0, h: v.videoHeight || 0,
        err: v.error ? v.error.code : 0});
      ['loadedmetadata','loadeddata','play','pause','ended','seeked','ratechange','volumechange','error','waiting','playing','canplay']
        .forEach(e => v.addEventListener(e, () => state(e)));
      let last = 0;
      v.addEventListener('timeupdate', () => { const n = performance.now(); if (n - last > 100) { last = n; state('time'); } });
      // CORS mode keeps the canvas untainted so frames can be read back at
      // full resolution (the scheme handler answers with ACAO).
      v.crossOrigin = 'anonymous';
      v.src = '\(mediaURLString)';
      v.load();

      const thumbCanvas = document.createElement('canvas');
      thumbCanvas.width = \(FrameThumb.width); thumbCanvas.height = \(FrameThumb.height);
      const tctx = thumbCanvas.getContext('2d', { willReadFrequently: true });
      tctx.imageSmoothingEnabled = true; tctx.imageSmoothingQuality = 'high';

      const lumaB64 = (src) => {
        tctx.drawImage(src, 0, 0, thumbCanvas.width, thumbCanvas.height);
        const px = tctx.getImageData(0, 0, thumbCanvas.width, thumbCanvas.height).data;
        const n = thumbCanvas.width * thumbCanvas.height; let s = '';
        for (let i = 0; i < n; i++) s += String.fromCharCode(Math.round(0.2126 * px[4*i] + 0.7152 * px[4*i+1] + 0.0722 * px[4*i+2]));
        return btoa(s);
      };
      const fromB64 = (s) => { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; };
      const pngOf = (src, vw, vh) => {
        if (!vw || !vh || vw > 16384 || vh > 16384) return '';
        const k = Math.min(1, 2560 / Math.max(vw, vh));
        const c = document.createElement('canvas'); c.width = Math.round(vw * k); c.height = Math.round(vh * k);
        const g = c.getContext('2d'); g.imageSmoothingQuality = 'high'; g.drawImage(src, 0, 0, c.width, c.height);
        try { return c.toDataURL('image/png'); } catch (e) { return ''; }
      };
      let lastFrame = null;

      const waitFrame = () => new Promise(res => {
        let done = false; const finish = () => { if (!done) { done = true; res(); } };
        if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(finish);
        setTimeout(finish, 150);
      });
      // Two animation frames: the new video frame has been composited and
      // painted, so a native snapshot taken now is not stale.
      const sleep = (ms) => new Promise(r => setTimeout(r, ms));
      const painted = () => new Promise(res => requestAnimationFrame(() => requestAnimationFrame(() => res())));
      const seek = (t) => new Promise((res, rej) => {
        const to = setTimeout(() => rej(new Error('seek timeout')), 20000);
        const ok = () => { clearTimeout(to); v.removeEventListener('error', bad); res(); };
        const bad = () => { clearTimeout(to); v.removeEventListener('seeked', ok); rej(new Error('media error')); };
        v.addEventListener('seeked', ok, { once: true });
        v.addEventListener('error', bad, { once: true });
        v.currentTime = t;
      });
      const ready = () => new Promise((res, rej) => {
        if (v.readyState >= 2) return res();
        const to = setTimeout(() => rej(new Error('load timeout')), 30000);
        v.addEventListener('loadeddata', () => { clearTimeout(to); res(); }, { once: true });
        v.addEventListener('error', () => { clearTimeout(to); rej(new Error('media error ' + (v.error ? v.error.code : ''))); }, { once: true });
      });

      window.volant = {
        play: () => v.play().catch(() => {}),
        pause: () => v.pause(),
        seek: (t) => { v.currentTime = Math.max(0, t); },
        rate: (r) => { v.playbackRate = r; },
        volume: (x) => { v.volume = Math.min(1, Math.max(0, x)); v.muted = x <= 0; },
        // Seeks to t and returns a 64x40 grayscale thumbnail (base64) or
        // {tainted:true} if the canvas refuses to give pixels back.
        sample: async (t) => {
          await ready(); v.pause(); await seek(t);
          // WebKit doesn't repaint a paused video after a seek until the next
          // action, so present the frame by playing (muted) for one frame.
          const wasMuted = v.muted; v.muted = true;
          await Promise.race([v.play().catch(() => {}), sleep(400)]);
          await waitFrame();
          v.pause(); v.muted = wasMuted;
          await painted();
          tctx.drawImage(v, 0, 0, thumbCanvas.width, thumbCanvas.height);
          let px;
          try { px = tctx.getImageData(0, 0, thumbCanvas.width, thumbCanvas.height).data; }
          catch (e) { return { tainted: true, t: v.currentTime }; }
          const n = thumbCanvas.width * thumbCanvas.height; let s = '';
          for (let i = 0; i < n; i++) {
            const y = Math.round(0.2126 * px[4*i] + 0.7152 * px[4*i+1] + 0.0722 * px[4*i+2]);
            s += String.fromCharCode(y);
          }
          return { thumb: btoa(s), t: v.currentTime };
        },
        // Full-resolution PNG of the current frame (data URL).
        grab: async () => pngOf(v, v.videoWidth, v.videoHeight),
        // WebCodecs path: decode compressed frames handed over by the app —
        // exact, full resolution, independent of the visible player.
        canDecode: async (codec, w, h) => {
          if (typeof VideoDecoder === 'undefined' || typeof EncodedVideoChunk === 'undefined') return false;
          try { const r = await VideoDecoder.isConfigSupported({ codec, codedWidth: w, codedHeight: h }); return !!r.supported; }
          catch (e) { return false; }
        },
        decodeSample: async (codec, w, h, chunks) => {
          const frame = await new Promise((resolve, reject) => {
            let last = null;
            const d = new VideoDecoder({ output: f => { if (last) last.close(); last = f; }, error: e => reject(new Error(String(e))) });
            d.configure({ codec, codedWidth: w, codedHeight: h, optimizeForLatency: true });
            for (const c of chunks) d.decode(new EncodedVideoChunk({ type: c[1] ? 'key' : 'delta', timestamp: c[2], data: fromB64(c[0]) }));
            d.flush().then(() => { try { d.close(); } catch (e) {} resolve(last); }, e => reject(new Error(String(e))));
          });
          if (!frame) return { err: 'no frame' };
          if (lastFrame) lastFrame.close();
          lastFrame = frame;
          return { thumb: lumaB64(frame), w: frame.displayWidth, h: frame.displayHeight };
        },
        grabDecoded: async () => lastFrame ? pngOf(lastFrame, lastFrame.displayWidth, lastFrame.displayHeight) : '',
        releaseDecoded: () => { if (lastFrame) { lastFrame.close(); lastFrame = null; } return 0; },
        info: () => ({ w: v.videoWidth, h: v.videoHeight, d: v.duration, rs: v.readyState, ns: v.networkState,
          err: v.error ? v.error.code : 0, msg: v.error ? v.error.message : '', src: v.currentSrc,
          vis: document.visibilityState, vp8: v.canPlayType('video/webm; codecs="vp8, opus"'),
          vp9: v.canPlayType('video/webm; codecs="vp9, opus"'), webm: v.canPlayType('video/webm'),
          mse: typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/webm; codecs="vp8, opus"') })
      };
      state('init');
    })();
    """
}

/// Serves exactly two resources to the web view: the player page and the
/// currently opened recording (with HTTP range support). Nothing else can
/// be loaded — there is no mapping from URLs to the file system.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let source: ByteSource?
    private let mime: String
    private let queue = DispatchQueue(label: "volant.media", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private let chunk = 512 * 1024
    var logger: ((String) -> Void)?

    init(fileURL: URL?, audioOnly: Bool) {
        self.source = fileURL.flatMap { try? ByteSource(url: $0) }
        self.mime = audioOnly ? "audio/webm" : "video/webm"
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        logger?("scheme:\(task.request.url?.path ?? "?") range=\(task.request.value(forHTTPHeaderField: "Range") ?? "-")")
        guard let url = task.request.url, url.scheme == PlayerPage.scheme, url.host == PlayerPage.host else {
            return fail(task, 403)
        }
        switch url.path {
        case "/player.html":
            let body = Data(PlayerPage.html.utf8)
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "\(body.count)",
                "Cache-Control": "no-store",
            ])!
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
            active.remove(id)
        case "/media.webm":
            serveMedia(task, url: url)
        default:
            fail(task, 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        let id = ObjectIdentifier(task)
        guard active.contains(id) else { return }
        if let url = task.request.url,
           let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) {
            task.didReceive(resp)
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.resourceUnavailable))
        }
        active.remove(id)
    }

    private func serveMedia(_ task: WKURLSchemeTask, url: URL) {
        guard let src = source, src.size > 0 else { return fail(task, 404) }
        guard let parsed = HTTPRange.parse(task.request.value(forHTTPHeaderField: "Range"), size: src.size) else {
            let resp = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes */\(src.size)", "Content-Length": "0"])!
            task.didReceive(resp); task.didFinish(); active.remove(ObjectIdentifier(task))
            return
        }
        let range = parsed ?? (0 ... src.size - 1)
        let length = range.upperBound - range.lowerBound + 1
        var headers = [
            "Access-Control-Allow-Origin": "*",
            "Content-Type": mime,
            "Content-Length": "\(length)",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if parsed != nil { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(src.size)" }
        let resp = HTTPURLResponse(url: url, statusCode: parsed != nil ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        if length == 0 { task.didFinish(); active.remove(ObjectIdentifier(task)); return }
        stream(task, src: src, offset: range.lowerBound, remaining: length)
    }

    /// Streams the range in chunks; each chunk is read off the main thread
    /// and handed to WebKit on the main thread. Stops as soon as WebKit
    /// cancels the request.
    private func stream(_ task: WKURLSchemeTask, src: ByteSource, offset: UInt64, remaining: UInt64) {
        let id = ObjectIdentifier(task)
        let n = Int(min(UInt64(chunk), remaining))
        queue.async { [weak self] in
            let data = try? src.read(at: offset, count: n)
            DispatchQueue.main.async {
                guard let self, self.active.contains(id) else { return }
                guard let data else {
                    task.didFailWithError(URLError(.cannotOpenFile)); self.active.remove(id); return
                }
                task.didReceive(data)
                let left = remaining - UInt64(n)
                if left == 0 {
                    task.didFinish(); self.active.remove(id)
                } else {
                    self.stream(task, src: src, offset: offset + UInt64(n), remaining: left)
                }
            }
        }
    }
}
