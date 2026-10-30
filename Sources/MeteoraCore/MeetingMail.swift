import Foundation

/// A meeting summary as an e-mail, in the three forms every mail client
/// understands — so it keeps working whichever corporate mail the company
/// moves to (Outlook, Apple Mail, Thunderbird, МойОфис Почта, RuPost,
/// CommuniGate, Яндекс 360, VK WorkSpace…):
///
/// * `mailtoURL` — opens a new message in the default mail app; subject and
///   text only (the mailto scheme has no attachments), cut to a safe length;
/// * `eml()` — a complete unsent message (RFC 5322 / MIME) with HTML and
///   plain text and the attachments. Outlook opens it as a draft ready to
///   send (`X-Unsent: 1`); Thunderbird, Apple Mail and МойОфис open or
///   import .eml as well;
/// * `html` / `plainText` — for the clipboard, to paste into web mail.
public struct MeetingMail: Sendable {
    public var subject: String
    public var summary: MeetingSummary
    public var recipients: [String]
    public var attachments: [Attachment]
    /// A line under the summary («Расшифровка — во вложении.», the app's name…).
    public var footer: String?

    public struct Attachment: Sendable, Equatable {
        public var fileName: String
        public var mimeType: String
        public var data: Data
        public init(fileName: String, mimeType: String, data: Data) {
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }
    }

    public init(summary: MeetingSummary, subject: String? = nil, recipients: [String] = [],
                attachments: [Attachment] = [], footer: String? = nil) {
        self.summary = summary
        self.subject = subject ?? "Итоги: \(summary.title)"
        self.recipients = recipients
        self.attachments = attachments
        self.footer = footer
    }

    // MARK: Bodies

    public var plainText: String {
        var out = summary.plainText()
        if let footer, !footer.isEmpty { out += "\n" + footer + "\n" }
        return out
    }

    public var html: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = "<h2 style=\"margin:0 0 12px;font-size:18px\">\(esc(summary.title))</h2>\n"
        if !summary.summary.isEmpty {
            body += "<p style=\"margin:0 0 14px\">\(esc(summary.summary))</p>\n"
        }
        for (heading, items) in summary.sections where !items.isEmpty {
            body += "<p style=\"margin:14px 0 6px;font-weight:600\">\(esc(heading))</p>\n<ul style=\"margin:0;padding-left:20px\">\n"
            for i in items { body += "<li style=\"margin:0 0 4px\">\(esc(i))</li>\n" }
            body += "</ul>\n"
        }
        if let footer, !footer.isEmpty {
            body += "<p style=\"margin:18px 0 0;color:#5B6068;font-size:12px\">\(esc(footer))</p>\n"
        }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>"
            + "<body style=\"font-family:-apple-system,'Segoe UI',Arial,sans-serif;font-size:14px;line-height:1.45;color:#16181B\">\n"
            + body + "</body></html>"
    }

    // MARK: mailto

    /// Longest URL handed to the mail app. Some clients (and Windows' shell)
    /// break on very long mailto links; the full text goes into .eml.
    public static let mailtoLimit = 1_900

    public var mailtoURL: URL {
        func enc(_ s: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        let to = recipients.map { r in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~@+")
            return r.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }.joined(separator: ",")
        let head = "mailto:\(to)?subject=\(enc(subject))&body="
        var text = plainText
        var url = head + enc(text)
        if url.count > Self.mailtoLimit {
            let tail = "\n…\n(Полностью — в Meteora: «Сохранить письмо».)"
            // Shorten by characters until the encoded link fits.
            var keep = text.count
            while keep > 0 {
                keep = Int(Double(keep) * 0.85)
                text = String(plainText.prefix(keep)) + tail
                url = head + enc(text)
                if url.count <= Self.mailtoLimit { break }
            }
        }
        return URL(string: url) ?? URL(string: "mailto:")!
    }

    // MARK: .eml

    /// A complete unsent message. `date` and `boundary` are parameters only so
    /// tests are deterministic.
    public func eml(date: Date = Date(), boundary: String = UUID().uuidString) -> Data {
        let mixed = "mixed-" + boundary
        let alt = "alt-" + boundary
        var out = ""
        func line(_ s: String = "") { out += s + "\r\n" }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        line("MIME-Version: 1.0")
        line("Date: \(f.string(from: date))")
        line("Subject: \(Self.encodedWord(subject))")
        if !recipients.isEmpty { line("To: \(recipients.joined(separator: ", "))") }
        line("X-Unsent: 1")
        line("X-Mailer: Meteora")
        line("Content-Type: multipart/mixed; boundary=\"\(mixed)\"")
        line()
        line("--\(mixed)")
        line("Content-Type: multipart/alternative; boundary=\"\(alt)\"")
        line()
        line("--\(alt)")
        line("Content-Type: text/plain; charset=utf-8")
        line("Content-Transfer-Encoding: base64")
        line()
        out += Self.base64Lines(Data(plainText.utf8))
        line("--\(alt)")
        line("Content-Type: text/html; charset=utf-8")
        line("Content-Transfer-Encoding: base64")
        line()
        out += Self.base64Lines(Data(html.utf8))
        line("--\(alt)--")
        for a in attachments {
            let name = Self.encodedWord(a.fileName)
            line("--\(mixed)")
            line("Content-Type: \(a.mimeType); name=\"\(name)\"")
            line("Content-Disposition: attachment; filename=\"\(name)\"; filename*=UTF-8''\(Self.rfc2231(a.fileName))")
            line("Content-Transfer-Encoding: base64")
            line()
            out += Self.base64Lines(a.data)
        }
        line("--\(mixed)--")
        return Data(out.utf8)
    }

    /// RFC 2047 encoded-word for non-ASCII header text.
    static func encodedWord(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "\r" && $0 != "\n" }) { return s }
        let clean = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "=?UTF-8?B?\(Data(clean.utf8).base64EncodedString())?="
    }

    static func rfc2231(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
    }

    static func base64Lines(_ d: Data) -> String {
        d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pdf": return "application/pdf"
        case "md": return "text/markdown; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        case "rtf": return "application/rtf"
        default: return "application/octet-stream"
        }
    }
}
