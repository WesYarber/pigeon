import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Destinations (other Macs/inboxes this Mac can send to)

struct Destination: Codable, Equatable {
    var name: String
    var server: URL
    var inbox: String
    var sendToken: String
    var pub: Data

    var fingerprint: String { ReceiverKey.fingerprint(of: pub) }

    /// Parses the pairing link another Mac shows: https://host/#p=v1.<inbox>.<token>.<pubkey>
    static func parse(_ link: String, name: String) -> Destination? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hashIdx = link.firstIndex(of: "#"),
              let server = URL(string: String(link[..<hashIdx])), server.scheme == "https" || server.host == "127.0.0.1" || server.host == "localhost"
        else { return nil }
        let frag = link[link.index(after: hashIdx)...]
        guard frag.hasPrefix("p=") else { return nil }
        let parts = frag.dropFirst(2).split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "v1", let pub = Data(base64URL: parts[3]),
              pub.count == 65, pub.first == 0x04 else { return nil }
        return Destination(name: name, server: server, inbox: parts[1], sendToken: parts[2], pub: pub)
    }

    static func load() -> [Destination] {
        Keychain.get("destinations").flatMap { try? JSONDecoder().decode([Destination].self, from: $0) } ?? []
    }

    static func save(_ list: [Destination]) { Keychain.set("destinations", try! JSONEncoder().encode(list)) }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

// MARK: - Global hotkey (Carbon; needs no Accessibility permission)

final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private(set) var registered = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.handlers[id] = action
        if !HotKey.installed {
            HotKey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKey.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x5047_4E31, id: id),
                                         GetApplicationEventTarget(), 0, &ref) == noErr
        if !registered { NSLog("Pigeon: couldn't register hotkey \(keyCode); another app may be using it") }
        self.id = id
    }

    private var id: UInt32 = 0

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }
}

// MARK: - Drop onto the menu bar icon

/// A transparent view laid over the status item's button that accepts drags.
/// (Registering the status bar *window* and relying on its delegate was flaky:
/// macOS can swap that window out, and drops then went nowhere.)
/// Clicks are passed through to the button underneath.
final class DropTarget: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onHover: ((Bool) -> Void)?

    func attach(to button: NSStatusBarButton) {
        frame = button.bounds
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
        button.addSubview(self)
    }

    // Let clicks reach the button.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { superview?.otherMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onHover?(true); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onHover?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover?(false)
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}

// MARK: - Sending

enum Outgoing {
    case text(String)
    case file(URL)
    case data(Data, name: String, type: String)
    /// This Mac's own pairing link, so the other Mac can send back.
    case pair(String)
}

extension AppDelegate {
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    var deviceName: String { Host.current().localizedName ?? "Mac" }

    var defaultDestination: Destination? { destinations.first }

    /// Reads whatever is on a pasteboard into things we can send.
    func outgoing(from pb: NSPasteboard) -> [Outgoing] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { .file($0) }
        }
        if let s = pb.string(forType: .string), !s.isEmpty { return [.text(s)] }
        if let png = pb.data(forType: .png) { return [.data(png, name: "clipboard.png", type: "image/png")] }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [.data(png, name: "clipboard.png", type: "image/png")]
        }
        return []
    }

    func send(_ items: [Outgoing], to dest: Destination?) {
        guard let dest = dest ?? defaultDestination else { return afterClosingPopover { self.addDestination() } }
        guard !items.isEmpty else { return showToast("Nothing to send") }
        Task {
            for item in items {
                sendingCount += 1
                defer { sendingCount -= 1 }
                do {
                    let label = try await upload(item, to: dest)
                    if case .pair = item { continue }
                    flashIcon("paperplane.fill")
                    checkReceiptsSoon(after: 3)
                    showToast("Sent to \(dest.name)")
                    notify("Sent to \(dest.name)", label)
                } catch {
                    showToast("Couldn't send: \(error.localizedDescription)")
                    notify("Couldn't send to \(dest.name)", error.localizedDescription)
                }
            }
        }
    }

    private func upload(_ item: Outgoing, to dest: Destination) async throws -> String {
        let (label, entry) = try await Self.deliver(item, to: dest, from: deviceName)
        if let entry { history.add(entry) }
        return label
    }

    /// Encrypts one item to `dest` and posts it to its relay. Returns a label for
    /// messages and the history entry to record. Shared with the `pigeon` command.
    nonisolated static func deliver(_ item: Outgoing, to dest: Destination, from deviceName: String) async throws -> (label: String, entry: Entry?) {
        var header: [String: Any] = ["v": 1, "ts": Date().timeIntervalSince1970 * 1000, "from": deviceName]
        let body: Data
        let label: String
        var entry: Entry? = Entry(id: UUID().uuidString, kind: "text", from: dest.name, ts: Date(), sent: true)
        switch item {
        case .text(let s):
            header["kind"] = "text"
            body = Data(s.utf8)
            label = String(s.prefix(80))
            entry?.text = s
        case .data(let d, let name, let type):
            header["kind"] = "file"; header["name"] = name; header["type"] = type; header["size"] = d.count
            body = d
            label = name
            entry?.kind = "file"; entry?.name = name
        case .file(let url):
            let (data, name) = try await Task.detached { try Self.readForSending(url) }.value
            header["kind"] = "file"; header["name"] = name; header["size"] = data.count
            header["type"] = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            body = data
            label = name
            entry?.kind = "file"; entry?.name = name; entry?.path = url.path
        case .pair(let link):
            header["kind"] = "pair"
            body = Data(link.utf8)
            label = "pairing request"
            entry = nil
        }
        guard body.count <= 100 * 1024 * 1024 else {
            throw NSError(domain: "Pigeon", code: 413, userInfo: [NSLocalizedDescriptionKey: "\(label) is over 100 MB"])
        }
        let sealed = try await Task.detached { [header] in try Envelope.seal(header: header, body: body, to: dest.pub) }.value

        var base = dest.server.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        var req = URLRequest(url: URL(string: base + "api/inboxes/\(dest.inbox)/items")!, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue(dest.sendToken, forHTTPHeaderField: "X-Send-Token")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: sealed)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 else {
            throw NSError(domain: "Pigeon", code: code, userInfo: [NSLocalizedDescriptionKey:
                code == 404 ? "\(dest.name)'s pairing changed. Add it again." :
                code == 413 ? "too large for the server" : "server said \(code)"])
        }
        // The relay's id for the item, so the app can later ask whether it was delivered.
        entry?.relayId = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
        entry?.inbox = dest.inbox
        return (label, entry)
    }

    /// Files are read as-is; folders are zipped first.
    nonisolated private static func readForSending(_ url: URL) throws -> (Data, String) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else { return (try Data(contentsOf: url), url.lastPathComponent) }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zip.path]
        try p.run()
        p.waitUntilExit()
        return (try Data(contentsOf: zip), url.lastPathComponent + ".zip")
    }

    // MARK: Clipboard auto-share

    func startClipboardWatcher() {
        lastChangeCount = NSPasteboard.general.changeCount
        Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.clipboardTick() } }
    }

    private func clipboardTick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        // Don't echo back what we just received, and never share password-manager copies.
        guard autoShare, let dest = defaultDestination, pb.changeCount != ownChangeCount,
              !(pb.types ?? []).contains(where: { Self.concealedTypes.contains($0.rawValue) }) else { return }
        let items = outgoing(from: pb).filter {
            switch $0 {
            case .text(let s): return s.count <= 1_000_000 && !s.contains("#p=v1.") // never leak pairing links
            case .data(let d, _, _): return d.count <= 20 * 1024 * 1024
            case .file, .pair: return false // copied files in Finder are only sent on purpose
            }
        }
        if !items.isEmpty { send(items, to: dest) }
    }

    // MARK: Actions used by the UI

    func sendClipboard(to dest: Destination? = nil) { send(outgoing(from: .general), to: dest) }

    func chooseAndSendFiles(to dest: Destination? = nil) {
        afterClosingPopover {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.prompt = "Send"
            panel.message = "Choose files or folders to send to \((dest ?? self.defaultDestination)?.name ?? "another Mac")."
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK else { return }
            self.send(panel.urls.map { .file($0) }, to: dest)
        }
    }

    // MARK: Destinations

    func makeDefault(_ d: Destination) {
        guard let i = destinations.firstIndex(of: d) else { return }
        destinations.insert(destinations.remove(at: i), at: 0)
        Destination.save(destinations)
    }

    func remove(_ d: Destination) {
        destinations.removeAll { $0 == d }
        Destination.save(destinations)
    }

    func rename(_ d: Destination) {
        afterClosingPopover {
            let a = NSAlert()
            a.messageText = "Rename \(d.name)"
            let field = NSTextField(string: d.name)
            a.accessoryView = formView([field], width: 260)
            a.addButton(withTitle: "Rename")
            a.addButton(withTitle: "Cancel")
            focusWhenShown(a, field)
            guard a.runAndClose() == .alertFirstButtonReturn,
                  let i = self.destinations.firstIndex(of: d) else { return }
            let n = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { self.destinations[i].name = String(n.prefix(40)) }
            Destination.save(self.destinations)
        }
    }

    func addDestination() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a Mac to send to"
        alert.informativeText = "On the other Mac, open Pigeon → Settings → Receiving → Pair a Device… → Copy Link, then paste the link here."
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        let link = NSTextField(string: clip.contains("#p=v1.") ? clip : "")
        link.placeholderString = "https://relay.example.com/#p=v1…"
        let name = NSTextField(string: "")
        name.placeholderString = "Name, e.g. Home Mac"
        alert.accessoryView = formView([link, name], width: 340)
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        focusWhenShown(alert, link.stringValue.isEmpty ? link : name)
        guard alert.runAndClose() == .alertFirstButtonReturn else { return }

        addDestination(link: link.stringValue, name: name.stringValue, confirm: true)
    }

    @discardableResult
    func addDestination(link: String, name: String, confirm askFingerprint: Bool) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let dest = Destination.parse(link, name: n.isEmpty ? "Other Mac" : String(n.prefix(40))) else {
            fail("That doesn't look like a Pigeon pairing link.")
            return false
        }
        if let cfg = config, cfg.inbox == dest.inbox { fail("That's this Mac's own link."); return false }
        if askFingerprint && !confirmFingerprint(dest) { return false }
        store(dest)
        // Two-way: offer the other Mac our own link, through the encrypted channel.
        if offerPairBack, let cfg = config, ReceiverKey.current != nil {
            send([.pair(cfg.pairingLink)], to: dest)
            notify("Ready to send to \(dest.name)", "\(dest.name) will be asked whether it may send back to this Mac.")
        } else {
            notify("Ready to send to \(dest.name)", "Drop files on the pigeon or press ⌃⌥⌘V to send your clipboard.")
        }
        return true
    }

    private func store(_ dest: Destination) {
        destinations.removeAll { $0.inbox == dest.inbox }
        destinations.append(dest)
        Destination.save(destinations)
    }

    func confirmFingerprint(_ dest: Destination) -> Bool {
        let confirm = NSAlert()
        confirm.messageText = "Check the fingerprint"
        confirm.informativeText = "\(dest.fingerprint)\n\nIt should match the fingerprint in the other Mac's pairing window. If it doesn't, someone may have tampered with the link."
        confirm.addButton(withTitle: "It Matches")
        confirm.addButton(withTitle: "Cancel")
        return confirm.runAndClose() == .alertFirstButtonReturn
    }

    // MARK: Two-way pairing

    /// Another Mac (which already holds our send token) offered its own link.
    /// Nothing is added until the user approves it in the popover.
    func receivePairRequest(_ p: Payload) {
        guard let dest = Destination.parse(String(decoding: p.body, as: UTF8.self), name: String(p.from.prefix(40))),
              dest.inbox != config?.inbox else { return }
        let existing = destinations.first { $0.inbox == dest.inbox }
        if let existing, existing.pub == dest.pub, existing.sendToken == dest.sendToken { return } // nothing new
        // A changed key for a known Mac also needs approval: never swap keys silently.
        pairRequests.removeAll { $0.dest.inbox == dest.inbox }
        pairRequests.append(PairRequest(dest: existing.map { var d = dest; d.name = $0.name; return d } ?? dest,
                                        at: Date(), isUpdate: existing != nil))
        setIcon(active: true)
        notify("\(dest.name) wants to receive from this Mac", "Open Pigeon to allow sending to it.")
    }

    func accept(_ r: PairRequest) {
        store(r.dest)
        pairRequests.removeAll { $0.id == r.id }
        setIcon(active: false)
        showToast("You can now send to \(r.dest.name)")
    }

    func dismiss(_ r: PairRequest) {
        pairRequests.removeAll { $0.id == r.id }
        setIcon(active: false)
    }
}
