Context: this is the repository owner's own code review of Meteora, a macOS
and iOS app for meeting recordings (Swift). There is no server and no network
target: work only on the source code in this repository, as a defensive code
audit that ends in concrete fixes. Describe weaknesses and fixes in prose; do
not write working exploit code or malicious payloads.

A previous review (Oct 31, 2026) already covered and cleared: model download
integrity, the update check, the WKWebView player and its Range parser, HTML,
DOCX and e-mail export encoding, the export file-name sanitizer, llama.cpp
tokenization. Do not spend the budget on those again.

Review only these areas, in this order:

1. Secrets and personal data
   - Keychain items for API keys (Sources/Meteora/SummaryModel.swift, iOS
     APIKeychain): accessibility class, synchronisation, access group.
   - PII masking before cloud requests (PIIGuard.swift, CloudSummarizer.swift):
     is every field of every request masked; what happens on failure.
   - Temporary files, logs and clipboard: does any transcript text outlive
     the user's deletion or leave the device.

2. Build and CI scripts (.github/workflows, scripts/)
   - Hash checks of downloaded vendor binaries, models and caches; anything
     fetched without a pin; secrets exposure in workflows; permissions.

3. Interfaces with other apps and the system
   - XPC converter (Sources/MeteoraConverter, MeteoraConverterProtocol):
     arguments, inherited file descriptors, what the service may open.
   - Services, URL and document handling, drag and drop, the self-test mode
     gate (METEORA_SELFTEST), the hand-off to the transcription app,
     sandbox entitlements (Resources/Meteora.entitlements).
   - Auto-folders and the iCloud shared folder: symlinks, FIFOs, renamed files.

4. Robustness of the WebM/EBML demuxer and Opus packet parsing
   (Sources/MeteoraCore/WebMDemuxer.swift and related): review bounds checks,
   integer overflow, recursion depth and memory limits on malformed files.
   Where a Swift toolchain is available, run the existing parser tests and
   generate malformed sample files from the test fixtures to check that
   parsing fails cleanly.

Report only confirmed issues with file:line, impact and a concrete fix. For
areas reviewed without findings, list the controls you verified.
