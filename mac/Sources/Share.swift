import AppKit
import Carbon.HIToolbox

// MARK: - Share menu
// The Share extension (mac/ShareExtension) is sandboxed and can't read
// Pigeon's keys, so it hands what was shared to the app as
//   pigeon://share?file=/path/a&file=/path/b&text=...
// With one Mac it sends straight away; with several, a small menu at the
// pointer asks which. Only requests that really come from Pigeon's own signed
// extension skip the menu, so a pigeon:// link from anywhere else (a web page)
// can't send anything without you choosing.

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

extension AppDelegate {
    func handleShareURL(_ url: URL) {
        guard url.host == "share", let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        var items: [Outgoing] = q.filter { $0.name == "file" }.compactMap(\.value)
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { .file($0) }
        items += q.filter { $0.name == "text" }.compactMap(\.value).filter { !$0.isEmpty }.map { .text($0) }
        guard !items.isEmpty else { return showToast("Nothing to send") }
        guard !destinations.isEmpty else { return afterClosingPopover { self.addDestination() } }
        let fromExtension = Self.requestCameFromShareExtension()
        dragLog.notice("share: \(items.count) items, from extension: \(fromExtension)")
        if destinations.count == 1, fromExtension {
            return send(items, to: destinations[0])
        }
        // Let the share sheet finish closing before the menu appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.askWhereToSend(items) }
    }

    /// Whether the Apple event that delivered this URL was sent by our Share
    /// extension: same bundle identifier and signed by the same team as this app.
    private static func requestCameFromShareExtension() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0,
              let team = ownTeamID else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        let text = "identifier \"net.wesyarber.pigeon.share\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    private static let ownTeamID: String? = {
        var code: SecCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    private func askWhereToSend(_ items: [Outgoing]) {
        let what: String
        switch (items.count, items.first) {
        case (1, .file(let u)?): what = "“\(u.lastPathComponent)”"
        case (1, .text?): what = "this text"
        default: what = "\(items.count) items"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = menu.addItem(withTitle: "Send \(what) to", action: nil, keyEquivalent: "")
        title.isEnabled = false
        var actions: [MenuAction] = []
        for (i, d) in destinations.enumerated() {
            let a = MenuAction { [weak self] in self?.send(items, to: d) }
            actions.append(a)
            let item = menu.addItem(withTitle: d.name + (i == 0 && destinations.count > 1 ? "  (default)" : ""),
                                    action: #selector(MenuAction.fire), keyEquivalent: i == 0 ? "\r" : "")
            item.keyEquivalentModifierMask = []
            item.target = a
            item.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cancel", action: nil, keyEquivalent: "").isEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: menu.items[1], at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(actions) {}
    }
}
