Context: this is the repository owner's own defensive security review of
Meteora, a macOS and iOS app for meeting recordings (Swift, SwiftUI/AppKit,
on-device speech recognition and summaries, optional cloud summaries with the
user's own API key). There is no server and no network target: work only on
the source code, build scripts and CI in this repository. The goal is a
complete, documented review that the owner can hand to the company's
information-security team, with concrete fixes. Describe weaknesses and fixes
in prose; do not write working exploit code or malicious payloads.

Scope: the WHOLE repository, not a list of hotspots: Sources/ (all modules),
iOS/, Resources/ (entitlements, Info.plist), scripts/, .github/workflows/.
Read SECURITY.md first and check every claim in it against the code.

Deliverables, all in the final report:

1. Verification matrix (the main deliverable). Use OWASP MASVS v2 as the
   checklist, applied to a desktop and mobile app without a backend:
   MASVS-STORAGE, -CRYPTO, -AUTH, -NETWORK, -PLATFORM, -CODE, -RESILIENCE,
   -PRIVACY. For EVERY control give: what was checked, how (code reading,
   tool, test run), where (file:line), and the result: Pass / Fail (finding
   id) / Partial / Not applicable (with the reason). Do not leave controls out
   because nothing was found.

2. Findings: confirmed issues only, each with file:line, impact, severity
   (CVSS 3.1), and a concrete fix.

3. AI-era threats. Assess, for this app specifically, how an attacker could
   use AI and how the app holds up, with a verdict and fix for each:
   - instructions hidden in a recording's speech, on-screen text (OCR) or
     file names that try to steer the summary model (prompt injection):
     what can the model's output reach (file names, links, mail, clipboard,
     titles), and is every such path sanitised;
   - AI-generated malformed media files built to break the parsers
     (WebM/EBML, Opus, files handed to FFmpeg), at scale;
   - tampering with downloaded or bundled model files (ONNX, GGUF);
   - leaking meeting content or API keys to cloud providers; masking of
     personal data before cloud requests;
   - AI-assisted reverse engineering or patching of the shipped app
     (ad-hoc signed DMG, update check, authenticity check) and what it can
     and cannot protect.

4. Hardening recommendations beyond the findings: defence-in-depth measures
   ranked by value and effort (code signing and notarisation, sandbox
   entitlements, update integrity, secrets handling, logging, CI supply
   chain, dependency pinning, runtime checks). Mark which ones need a paid
   Apple Developer ID.

5. Security architecture notes: trust boundaries, where untrusted data
   enters, and design changes that would remove whole classes of risk.

Work method: build what can be built on Linux (pure Swift in MeteoraCore)
and run the existing tests; generate malformed samples from the test
fixtures for the parsers; review AppKit/WebKit/XPC code statically and say
so in the matrix. Keep run state and any generated files out of the
repository checkout.
