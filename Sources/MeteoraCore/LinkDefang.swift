import Foundation

/// Makes web addresses in untrusted text (model output, recognised speech)
/// non-clickable: `https://x` → `hxxps://x`, `ftp://x` → `ftp[:]//x`,
/// `www.x` → `www[.]x`. Readers still see the address; Markdown viewers,
/// Outlook and other mail clients no longer turn it into a link, so a phrase
/// planted in a recording can't become a working link in official minutes.
public enum LinkDefang {
    private static let rules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(?i)\bh(tt)(ps?)(?=:)"#), "hxx$2"),
        (try! NSRegularExpression(pattern: #"(?i)\b(?!hxxps?:)([a-z][a-z0-9+.\-]{1,15}):(//)"#), "$1[:]$2"),
        (try! NSRegularExpression(pattern: #"(?i)\b(www)\.(?=\S)"#), "$1[.]"),
    ]

    public static func defang(_ text: String) -> String {
        guard text.contains(":") || text.range(of: "www.", options: .caseInsensitive) != nil else { return text }
        var out = text
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
