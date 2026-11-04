import AppKit
import UniformTypeIdentifiers

// Pigeon in the Share menu. Extensions must be sandboxed, so this one can't
// read Pigeon's keys; it gathers what was shared and hands it to the app
// (pigeon://share?file=...&text=...), which asks which Mac to send to.

@objc(PigeonShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var files: [String] = [], texts: [String] = []
        let lock = NSLock()
        let group = DispatchGroup()
        func add(file: String? = nil, text: String? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let file { files.append(file) }
            if let text, !text.isEmpty { texts.append(text) }
        }
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { url.isFileURL ? add(file: url.path) : add(text: url.absoluteString) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    add(text: s as? String)
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var c = URLComponents()
            c.scheme = "pigeon"
            c.host = "share"
            c.queryItems = files.map { URLQueryItem(name: "file", value: $0) } + texts.map { URLQueryItem(name: "text", value: $0) }
            if !(files.isEmpty && texts.isEmpty), let url = c.url { NSWorkspace.shared.open(url) }
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
