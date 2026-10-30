Repository: Meteora — a macOS and iOS app for meeting recordings (Swift). There is
no server: review the source code and, where useful, build helpers and scripts.

Focus:
1. Untrusted input: crafted media files (WebM/EBML demuxer in
   Sources/MeteoraCore/WebMDemuxer.swift, Opus packet parsing, the FFmpeg XPC
   converter), text that ends up in exports (HTML, Markdown, DOCX, RTF, PDF,
   e-mail .eml) and in the WKWebView player.
2. Secrets and personal data: API keys (Keychain), transcripts, temp files,
   logs, clipboard, cloud requests (PII masking in PIIGuard.swift).
3. Paths: exports, auto-folders, the shared iCloud folder, model downloads.
4. Update and model integrity (pinned hashes, Updates.swift).
5. Sandbox entitlements (Resources/Meteora.entitlements) and the XPC boundary.
6. CI supply chain in .github/workflows and scripts/.

Report only confirmed issues with file:line, impact and a concrete fix.
