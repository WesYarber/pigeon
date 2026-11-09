import Foundation
import UniformTypeIdentifiers

/// Turns what was shared or dropped (item providers) into things to send:
/// files and photos keep their original bytes and names, web links and text
/// become one text message. Used by the Share extension and by drops onto the app.
enum ItemReader {
    static func read(_ providers: [NSItemProvider], into scratch: URL) async -> [Outgoing] {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var files: [Outgoing] = [], texts: [String] = []
        for p in providers {
            switch await read(p, into: scratch) {
            case .file(let url, let name)?: files.append(.file(url, name: name))
            case .text(let s)?: if !texts.contains(s) { texts.append(s) }
            case nil: break
            }
        }
        // Several text bits (e.g. a page title and its link) go as one message.
        return files + (texts.isEmpty ? [] : [.text(texts.joined(separator: "\n"))])
    }

    private static func read(_ p: NSItemProvider, into scratch: URL) async -> Outgoing? {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        // A web link (Safari, most apps): send the link itself.
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }), !types.contains(where: isFileData) {
            if let url = await p.loadURL(), !url.isFileURL { return .text(url.absoluteString) }
        }
        // A file, photo or video: its original bytes and name, best type first.
        if let t = types.first(where: isFileData) {
            let suggested = p.suggestedName
            return await withCheckedContinuation { cont in
                _ = p.loadFileRepresentation(forTypeIdentifier: t.identifier) { url, _ in
                    guard let url else { return cont.resume(returning: nil) }
                    let name = fileName(suggested: suggested, url: url, type: t)
                    let copy = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    // The provided file is deleted when this closure returns, so keep a copy.
                    do {
                        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                        let dest = copy.appendingPathComponent(name)
                        try FileManager.default.copyItem(at: url, to: dest)
                        cont.resume(returning: .file(dest, name: name))
                    } catch {
                        cont.resume(returning: nil)
                    }
                }
            }
        }
        if let s = await p.loadString(), !s.isEmpty { return .text(s) }
        return nil
    }

    private static func isFileData(_ t: UTType) -> Bool {
        (t.conforms(to: .data) || t.conforms(to: .directory)) && !t.conforms(to: .text) && !t.conforms(to: .url)
            || t.conforms(to: .image) || t.conforms(to: .audiovisualContent) || t.conforms(to: .pdf)
    }

    /// The real name with an extension that matches the data ("IMG_0042.HEIC").
    static func fileName(suggested: String?, url: URL, type: UTType) -> String {
        var name = (suggested?.isEmpty == false ? suggested! : url.lastPathComponent)
            .components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "_")
        let ext = (name as NSString).pathExtension
        let hasMatchingExt = !ext.isEmpty && (UTType(filenameExtension: ext)?.conforms(to: type) ?? false || type.preferredFilenameExtension == nil)
        if !hasMatchingExt, let want = type.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? nil : url.pathExtension) {
            name += "." + want
        }
        return name
    }
}
