import Foundation
import UniformTypeIdentifiers

/// Decides whether a shared or dropped item is a file (send it as itself, under
/// its name) or a snippet of text (send it as text, for the clipboard).
/// Shared by the Mac app and the iPhone app.
///
/// Text files are the tricky case: a shell script, JSON or Markdown file also
/// counts as "text" to the system, so a rule like "text types are text" sends
/// `deploy.sh` as a clipboard snippet. Instead, a text type means a file when
/// the item is named (files have names; a selection of text doesn't), or when
/// it's a specific file format rather than generic text.
enum FileKinds {
    /// Plain, rich or web text that a text selection (or a copied cell range)
    /// offers. These only mean a file when the item has a name.
    static let genericText = Set([
        UTType.text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText,
        .rtf, .rtfd, .flatRTFD, .html, .utf8TabSeparatedText, .delimitedText,
    ].map(\.identifier)).union(["com.apple.traditional-mac-plain-text", "public.url-name"])

    /// The type to load the item's file from, best first, or nil if it's text
    /// (or a link). `named` is whether the item came with a file name.
    static func fileType(in identifiers: [String], named: Bool) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        let isFile = named || types.contains(.fileURL)
        return types.first { t in
            if t.conforms(to: .url) { return false }
            if t.conforms(to: .image) || t.conforms(to: .audiovisualContent) || t.conforms(to: .pdf) { return true }
            guard t.conforms(to: .data) || t.conforms(to: .directory) else { return false }
            guard t.conforms(to: .text) else { return true }
            return isFile || !genericText.contains(t.identifier)
        }
    }
}
