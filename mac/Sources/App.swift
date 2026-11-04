import AppKit
import Combine
import CoreImage
import CryptoKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Profile
// PIGEON_PROFILE=name runs a fully separate instance (own Keychain items,
// settings, history and folders). Used for testing two "Macs" on one machine.

enum Profile {
    static let name: String? = ProcessInfo.processInfo.environment["PIGEON_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
    static var folderName: String { "Pigeon" + (name.map { "-\($0)" } ?? "") }
    static var defaults: UserDefaults { name.flatMap { UserDefaults(suiteName: "net.wesyarber.pigeon.\($0)") } ?? .standard }
}

extension NSAlert {
    /// runModal, then make sure the window is really gone; it can linger on
    /// screen, unresponsive, when the alert was started from menu tracking.
    @discardableResult
    func runAndClose() -> NSApplication.ModalResponse {
        let r = runModal()
        window.orderOut(nil)
        return r
    }
}

/// Puts the text cursor in an alert's accessory field once the alert is on screen.
func focusWhenShown(_ alert: NSAlert, _ field: NSView) {
    // NSAlert ignores initialFirstResponder for accessory fields, so focus the
    // field the moment the alert's window becomes key.
    alert.layout()
    var token: NSObjectProtocol?
    token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                   object: alert.window, queue: .main) { _ in
        MainActor.assumeIsolated { _ = alert.window.makeFirstResponder(field) }
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// Stacks text fields vertically at a fixed width for an NSAlert accessory view.
/// (NSStackView with a manual frame collapses the fields to zero width.)
func formView(_ fields: [NSTextField], width: CGFloat = 320) -> NSView {
    let h: CGFloat = 24, gap: CGFloat = 8
    let total = CGFloat(fields.count) * h + CGFloat(fields.count - 1) * gap
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
    for (i, f) in fields.enumerated() {
        f.frame = NSRect(x: 0, y: total - CGFloat(i + 1) * h - CGFloat(i) * gap, width: width, height: h)
        v.addSubview(f)
    }
    return v
}

// MARK: - Keychain

enum Keychain {
    static let service = "net.wesyarber.pigeon" + (Profile.name.map { ".\($0)" } ?? "")

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ account: String, _ data: Data) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Config & history

struct Config: Codable {
    var server: URL
    var inbox: String
    var sendToken: String
    var recvToken: String

    var pairingLink: String {
        var base = server.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return "\(base)#p=v1.\(inbox).\(sendToken).\(ReceiverKey.current!.publicKey.base64URL)"
    }

    func api(_ path: String) -> URL {
        var base = server.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + "api/" + path)!
    }

    static func load() -> Config? { Keychain.get("config").flatMap { try? JSONDecoder().decode(Config.self, from: $0) } }
    func save() { Keychain.set("config", try! JSONEncoder().encode(self)) }
}

extension ReceiverKey {
    static var current: ReceiverKey? = Keychain.get("receiverKey").flatMap { ReceiverKey(serialized: $0) }

    static func rotate() -> ReceiverKey {
        let k = ReceiverKey.generate()
        Keychain.set("receiverKey", k.serialized)
        current = k
        return k
    }
}

struct Entry: Codable, Identifiable {
    var id: String
    var kind: String // "text" | "file"
    var from: String
    var ts: Date
    var text: String?
    var name: String?
    var path: String?
    var sent: Bool? = nil
    // Delivery tracking for things this Mac sent (see Receipts.swift).
    var relayId: String? = nil
    var inbox: String? = nil
    var delivered: Date? = nil
    var undelivered: Bool? = nil // expired on the relay before the other Mac picked it up
}

/// Received/sent history, encrypted at rest with a Keychain-held key.
final class History {
    private(set) var entries: [Entry] = []
    /// Hard cap; normally items expire by age first (see Features.swift).
    var limit = 200 { didSet { trim(); save() } }
    var onChange: (() -> Void)?
    let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Profile.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.bin")
    }()
    lazy var key: SymmetricKey = {
        if let d = Keychain.get("historyKey") { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        Keychain.set("historyKey", k.withUnsafeBytes { Data($0) })
        return k
    }()

    init() {
        if let d = try? Data(contentsOf: file), let box = try? AES.GCM.SealedBox(combined: d),
           let pt = try? AES.GCM.open(box, using: key),
           let e = try? JSONDecoder().decode([Entry].self, from: pt) { entries = e }
    }

    /// Newest first by when it was sent (items can arrive late, e.g. after the Mac was offline).
    func add(_ e: Entry) {
        entries.insert(e, at: entries.firstIndex { $0.ts <= e.ts } ?? entries.count)
        trim(); save()
    }
    func remove(_ id: String) { entries.removeAll { $0.id == id }; save() }
    func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i]); save()
    }
    func clear() { entries = []; save() }
    func replaceAll(_ e: [Entry]) { entries = e; save() }
    private func trim() { if entries.count > limit { entries = Array(entries.prefix(limit)) } }

    func save() {
        onChange?()
        guard let pt = try? JSONEncoder().encode(entries),
              let sealed = try? AES.GCM.seal(pt, using: key).combined else { return }
        try? sealed.write(to: file, options: [.atomic, .completeFileProtection])
    }
}

/// Another Mac asked (through the encrypted channel) to let this Mac send back to it.
struct PairRequest: Identifiable {
    let id = UUID()
    let dest: Destination
    let at: Date
    /// True when this Mac already sends to it and the request carries new keys.
    var isUpdate = false
}

enum Connection: Equatable {
    case off, connecting, connected, offline(String)
}

enum AfterReceive: String, CaseIterable, Identifiable {
    case nothing, reveal, open
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nothing: return "Do nothing"
        case .reveal: return "Show it in Finder"
        case .open: return "Open it"
        }
    }
}

// MARK: - App

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static func main() {
        // `pigeon` on the command line runs this binary with --cli (see CLI.swift).
        if CommandLine.arguments.dropFirst().first == "--cli" { CLI.run(Array(CommandLine.arguments.dropFirst(2))) }
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(d.showInDock ? .regular : .accessory)
        app.run()
    }

    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var fallbackPanel: NSPanel?
    var settingsWindow: NSWindow?
    var pairWindow: NSWindow?
    let history = History()
    var config = Config.load() { didSet { objectWillChange.send() } }
    @Published var connection: Connection = .off
    @Published var destinations = Destination.load()
    @Published var pairRequests: [PairRequest] = []
    @Published var sendingCount = 0
    @Published var toast: String?
    var pollTask: Task<Void, Never>?
    var lastChangeCount = 0
    var ownChangeCount = -1
    var hotKeys: [HotKey] = []
    @Published var hotKeyFailures: Set<ShortcutAction> = []
    var popoverHost: NSHostingController<PopoverView>!
    var sizeObserver: AnyCancellable?
    let dropTarget = DropTarget()
    let defaults = Profile.defaults
    // Drag watching (see DropShelf.swift)
    var dropShelf: NSPanel?
    var eventMonitors: [Any] = []
    var dragChangeCount = 0
    var fileDragActive = false
    var outsideClickPending = false
    var checkingReceipts = false
    var receiptsUnsupported: Set<String> = [] // relays (by URL) too old to answer receipts
    var dragCountAtRelease = 0 // drag pasteboard changeCount when the mouse was last released
    // Updates (see Features.swift)
    @Published var updateAvailable: [String] = [] { didSet { setIcon(active: false) } } // new commit subjects
    @Published var updating = false
    var updateTimer: Timer?

    // MARK: Settings (UserDefaults-backed; setters refresh the UI)

    func setting<T>(_ key: String, _ value: T) { objectWillChange.send(); defaults.set(value, forKey: key) }

    /// Dock icon is optional: useful when the menu bar is too full to show ours,
    /// and files dropped on it get sent. PIGEON_DOCK=1 forces it (UI testing).
    var showInDock: Bool {
        get { defaults.bool(forKey: "showInDock") || ProcessInfo.processInfo.environment["PIGEON_DOCK"] != nil }
        set { setting("showInDock", newValue); NSApp.setActivationPolicy(newValue ? .regular : .accessory) }
    }
    /// Slide out a drop shelf under the pigeon while dragging files toward the top of the screen.
    var dropShelfOn: Bool {
        get { defaults.object(forKey: "dropShelf") as? Bool ?? true }
        set { setting("dropShelf", newValue) }
    }
    /// Keep the popover open when clicking in other apps, e.g. to open the Dock's
    /// Downloads stack and find a file to drag in. Closes with the pigeon, Esc or a right-click.
    var keepPopoverOpen: Bool {
        get { defaults.object(forKey: "keepPopoverOpen") as? Bool ?? true }
        set { setting("keepPopoverOpen", newValue) }
    }
    var autoShare: Bool {
        get { defaults.bool(forKey: "autoShare") }
        set { setting("autoShare", newValue) }
    }
    var autoCopy: Bool {
        get { defaults.object(forKey: "autoCopy") as? Bool ?? true }
        set { setting("autoCopy", newValue) }
    }
    var notificationsOn: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { setting("notifications", newValue) }
    }
    /// When adding a Mac to send to, also send it this Mac's link so it can send back.
    var offerPairBack: Bool {
        get { defaults.object(forKey: "offerPairBack") as? Bool ?? true }
        set { setting("offerPairBack", newValue) }
    }
    var afterReceive: AfterReceive {
        get { AfterReceive(rawValue: defaults.string(forKey: "afterReceive") ?? "") ?? .nothing }
        set { setting("afterReceive", newValue.rawValue) }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { showToast("Couldn't change login item: \(error.localizedDescription)") }
        }
    }

    /// Where received files go. Defaults to ~/Downloads; chosen folder is remembered.
    /// Test profiles get their own subfolder so they never write into the real Downloads.
    var downloadsDir: URL {
        if let p = defaults.string(forKey: "downloadDir"), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard Profile.name != nil else { return downloads }
        let d = downloads.appendingPathComponent(Profile.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func chooseDownloadsDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = downloadsDir
        panel.prompt = "Use This Folder"
        panel.message = "Choose where files you receive are saved."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setting("downloadDir", url.path)
    }

    func resetDownloadsDir() { objectWillChange.send(); defaults.removeObject(forKey: "downloadDir") }

    var statusText: String {
        switch connection {
        case .off: return "Receiving is off"
        case .connecting: return "Connecting…"
        case .connected: return "Connected · \(config?.server.host ?? "")"
        case .offline(let why): return "Offline, retrying… (\(why))"
        }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        installMainMenu()
        history.onChange = { [weak self] in self?.objectWillChange.send() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(active: false)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Pigeon"
            dropTarget.attach(to: button)
            dropTarget.onHover = { [weak self] on in self?.setIcon(active: on) }
            dropTarget.onDrop = { [weak self] pb in
                guard let self else { return false }
                self.send(self.outgoing(from: pb), to: nil)
                return true
            }
        }
        // Closed by our own mouse watching instead of .transient, so a click outside
        // that starts a file drag (e.g. in Finder) doesn't make the popover vanish.
        popover.behavior = .applicationDefined
        popover.animates = true
        popoverHost = NSHostingController(rootView: PopoverView(app: self))
        popoverHost.sizingOptions = [] // sized explicitly to its content (refitPanels), never grown by SwiftUI
        popover.contentViewController = popoverHost
        // Whenever what the popover shows changes, resize it to fit.
        sizeObserver = objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refitPanels() }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerHotKeys()
        startHistoryExpiry()
        startClipboardWatcher()
        startDragWatch()
        startUpdateChecks()
        startReceiptChecks()
        // The `pigeon` command records what it sent; show it here too.
        DistributedNotificationCenter.default().addObserver(forName: History.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.history.reload()
                self?.checkReceiptsSoon(after: 3)
            }
        }

        if config != nil && ReceiverKey.current != nil {
            startPolling()
        } else if destinations.isEmpty {
            DispatchQueue.main.async { self.firstRun() }
        }
    }

    /// Menu-bar-only apps have no main menu, which silently breaks ⌘C/⌘V/⌘A in
    /// text fields (e.g. pasting a pairing link). Install a minimal one.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu!.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",").target = self
        appItem.submenu!.addItem(withTitle: "Quit Pigeon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Popover

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Right-click: a tiny menu with the essentials.
            let m = NSMenu()
            m.addItem(withTitle: "Open Pigeon", action: #selector(togglePopoverAction), keyEquivalent: "").target = self
            m.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Pigeon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc func togglePopoverAction() { DispatchQueue.main.async { self.togglePopover() } }

    /// Shows the popover under the menu bar icon, or (if macOS has hidden the
    /// icon because the menu bar is full) in a small floating window at the pointer.
    func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        if let panel = fallbackPanel, panel.isVisible, panel.isKeyWindow { panel.close(); return }
        showPopover()
    }

    func showPopover() {
        NSApp.activate(ignoringOtherApps: true)
        if popover.isShown { return }
        if let button = statusItem.button, let w = button.window, w.isVisible, w.occlusionState.contains(.visible) {
            // Size before showing, capped so the popover's top stays below the menu bar.
            let screen = (w.screen ?? NSScreen.main!).visibleFrame
            _ = screen
            pruneHistory()
            popover.contentSize = fittedPanelSize() // fits the content and stays below the menu bar
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            showFallbackPanel()
        }
    }

    static let popoverHeight: CGFloat = 560

    func closePopover() {
        popover.performClose(nil)
        fallbackPanel?.close()
    }

    private func showFallbackPanel() {
        let panel = fallbackPanel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: Self.popoverHeight),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false // closed by the mouse watching, like the popover
            p.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: PopoverView(app: self))
            host.sizingOptions = []
            p.contentViewController = host
            p.setContentSize(fittedPanelSize())
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            fallbackPanel = p
            return p
        }()
        pruneHistory()
        panel.setContentSize(fallbackFrameSize(panel, fitting: fittedPanelSize()))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = NSPoint(x: mouse.x - panel.frame.width / 2, y: mouse.y - panel.frame.height - 8)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Runs `body` after the popover has closed, so dialogs don't fight it for focus.
    func afterClosingPopover(_ body: @escaping () -> Void) {
        closePopover()
        DispatchQueue.main.async(execute: body)
    }

    // Opening Pigeon again (Spotlight, Finder, Dock) shows the popover, in case the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    // Files dropped on the Dock icon or the app in Finder get sent.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { send(files.map { .file($0) }, to: nil) }
        // pigeon://share?... comes from the Share menu extension (see Share.swift).
        urls.filter { $0.scheme == "pigeon" }.forEach(handleShareURL)
    }

    // MARK: Settings window

    @objc func showSettingsAction() { afterClosingPopover { self.showSettings() } }

    func showSettings(tab: SettingsTab = .general) {
        settingsTab = tab
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Pigeon Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(app: self))
            settingsWindow = w
            w.layoutIfNeeded()
            w.center() // after SwiftUI has sized it, or it lands partly off-screen
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @Published var settingsTab: SettingsTab = .general

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: First run

    func firstRun() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Welcome to Pigeon"
        a.informativeText = "Should this Mac receive things, send things to another Mac, or both? You can change this any time in Pigeon's settings."
        a.addButton(withTitle: "Receive on This Mac")
        a.addButton(withTitle: "Send to Another Mac")
        a.addButton(withTitle: "Later")
        switch a.runAndClose() {
        case .alertFirstButtonReturn: setup()
        case .alertSecondButtonReturn: addDestination()
        default: break
        }
    }

    func flashIcon(_ symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pigeon")
        img?.isTemplate = true
        statusItem.button?.image = img
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.setIcon(active: false) }
    }

    /// Pigeon glyph; `active` adds a dot (something arrived, or a drag is
    /// hovering). An orange dot means an update is waiting.
    func setIcon(active: Bool) {
        guard let button = statusItem?.button else { return }
        let img = Bundle.main.image(forResource: active ? "MenuBarIconBadge" : "MenuBarIcon")
            ?? NSImage(systemSymbolName: active ? "tray.and.arrow.down.fill" : "tray.and.arrow.down", accessibilityDescription: nil)
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        img?.accessibilityDescription = "Pigeon"
        if !active, !updateAvailable.isEmpty, let img {
            button.image = updateBadgeIcon(img)
            button.toolTip = "Pigeon · update available"
        } else {
            button.image = img
            button.toolTip = "Pigeon"
        }
    }

    // MARK: History actions

    func copy(_ e: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if e.kind == "text" {
            pb.setString(e.text ?? "", forType: .string)
        } else if let p = e.path {
            let url = URL(fileURLWithPath: p)
            var objs: [NSPasteboardWriting] = [url as NSURL]
            if let img = NSImage(contentsOf: url) { objs.insert(img, at: 0) }
            pb.writeObjects(objs)
        }
        ownChangeCount = pb.changeCount // copying from history isn't a new thing to auto-share
        showToast("Copied")
    }

    func open(_ e: Entry) {
        guard let p = e.path, FileManager.default.fileExists(atPath: p) else { return showToast("That file is gone") }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    func reveal(_ e: Entry) {
        guard let p = e.path, FileManager.default.fileExists(atPath: p) else { return showToast("That file is gone") }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    func openDownloads() { NSWorkspace.shared.open(downloadsDir) }

    // MARK: Setup & pairing

    func setup(prefill: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect Pigeon to your relay"
        alert.informativeText = "Enter your relay server's address and its admin secret (RELAY_ADMIN_SECRET). The secret is only used once to create this Mac's inbox and isn't stored."
        // PIGEON_SERVER / PIGEON_ADMIN_SECRET prefill the fields; only used by UI tests.
        let env = ProcessInfo.processInfo.environment
        let server = NSTextField(string: prefill ?? config?.server.absoluteString ?? env["PIGEON_SERVER"]
            ?? defaults.string(forKey: "lastServer") ?? "")
        let secret = NSSecureTextField(string: env["PIGEON_ADMIN_SECRET"] ?? "")
        secret.placeholderString = "Admin secret"
        server.placeholderString = "https://relay.example.com"
        alert.accessoryView = formView([server, secret])
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        focusWhenShown(alert, secret)
        guard alert.runAndClose() == .alertFirstButtonReturn else { return }

        let typed = server.stringValue.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: typed),
              url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            fail("The server address must start with https://")
            return setup(prefill: typed)
        }
        Task { await register(server: url, adminSecret: secret.stringValue, rotate: ReceiverKey.current == nil) }
    }

    func register(server: URL, adminSecret: String, rotate: Bool) async {
        if rotate { _ = ReceiverKey.rotate() }
        let cfg = Config(server: server, inbox: Data.random(16).base64URL,
                         sendToken: Data.random(32).base64URL, recvToken: Data.random(32).base64URL)
        var req = URLRequest(url: cfg.api("inboxes"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(adminSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": cfg.inbox,
            "sendHash": SHA256.hash(data: Data(cfg.sendToken.utf8)).map { String(format: "%02x", $0) }.joined(),
            "recvHash": SHA256.hash(data: Data(cfg.recvToken.utf8)).map { String(format: "%02x", $0) }.joined(),
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 201 else {
                fail(code == 401 ? "The admin secret was wrong." : "The server said \(code).")
                return setup(prefill: server.absoluteString)
            }
        } catch {
            fail("Couldn't reach the server: \(error.localizedDescription)")
            return setup(prefill: server.absoluteString)
        }
        defaults.set(server.absoluteString, forKey: "lastServer")
        cfg.save()
        config = cfg
        startPolling()
        showPairing()
    }

    func resetKeys() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Reset keys and unpair all devices?"
        a.informativeText = "This makes a new encryption key and a new inbox. Every device will have to scan the new QR code. Anything still waiting on the server becomes unreadable. You'll need the admin secret."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        guard a.runAndClose() == .alertFirstButtonReturn else { return }
        pollTask?.cancel()
        _ = ReceiverKey.rotate()
        Keychain.delete("config")
        config = nil
        connection = .off
        setup()
    }

    func fail(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Pigeon"
        a.informativeText = msg
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runAndClose()
    }

    func showPairing() {
        guard let cfg = config, let key = ReceiverKey.current else { return setup() }
        pairWindow?.close()
        let link = cfg.pairingLink

        let qr = NSImageView(image: qrImage(link) ?? NSImage())
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 260).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let title = NSTextField(labelWithString: "Scan with your phone's camera")
        title.font = .boldSystemFont(ofSize: 15)
        let note = NSTextField(wrappingLabelWithString:
            "Or open the link on any device and add it to the home screen. For another Mac, use Copy Link and add it there with \"Add a Mac\". Anyone with this link can send things to this Mac, so only use it on your own devices.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300
        let fp = NSTextField(wrappingLabelWithString: "Key fingerprint\n\(key.fingerprint)" + (key.isHardwareBacked ? "  ·  Secure Enclave" : ""))
        fp.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fp.textColor = .secondaryLabelColor
        fp.alignment = .center
        fp.preferredMaxLayoutWidth = 300
        let copy = NSButton(title: "Copy Link", target: self, action: #selector(copyPairLink))

        let stack = NSStackView(views: [title, qr, note, fp, copy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pair a Device"
        w.contentView = stack
        w.isReleasedWhenClosed = false
        w.center()
        pairWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc func copyPairLink() {
        guard let cfg = config else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cfg.pairingLink, forType: .string)
        ownChangeCount = NSPasteboard.general.changeCount // never auto-share our own pairing link
    }

    func qrImage(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: Receiving

    func startPolling() {
        pollTask?.cancel()
        connection = .connecting
        pollTask = Task { [weak self] in
            var backoff: UInt64 = 2
            var wait = 0 // first request returns at once so the status updates right away
            while !Task.isCancelled {
                guard let self, let cfg = self.config, let key = ReceiverKey.current else { return }
                do {
                    try await self.pollOnce(cfg, key, wait: wait)
                    if Task.isCancelled { return }
                    if self.connection != .connected { self.connection = .connected }
                    backoff = 2
                    wait = 25
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.connection = .offline(error.localizedDescription)
                    wait = 0
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    func request(_ cfg: Config, _ path: String, method: String = "GET", timeout: TimeInterval = 60) -> URLRequest {
        var r = URLRequest(url: cfg.api(path), timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(cfg.recvToken, forHTTPHeaderField: "X-Recv-Token")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    struct ItemList: Decodable { struct Item: Decodable { let id: String }; let items: [Item] }

    func pollOnce(_ cfg: Config, _ key: ReceiverKey, wait: Int) async throws {
        let (data, resp) = try await URLSession.shared.data(for: request(cfg, "inboxes/\(cfg.inbox)/items?wait=\(wait)", timeout: 40))
        try check(resp)
        for item in try JSONDecoder().decode(ItemList.self, from: data).items {
            let (blob, r2) = try await URLSession.shared.data(for: request(cfg, "inboxes/\(cfg.inbox)/items/\(item.id)", timeout: 300))
            try check(r2)
            do {
                handle(try Envelope.open(blob, with: key))
            } catch {
                NSLog("Pigeon: dropped an item that failed to decrypt: \(error)")
            }
            _ = try? await URLSession.shared.data(for: request(cfg, "inboxes/\(cfg.inbox)/items/\(item.id)", method: "DELETE"))
        }
    }

    func check(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw NSError(domain: "Pigeon", code: code, userInfo: [NSLocalizedDescriptionKey:
                code == 404 ? "inbox not found, set up receiving again" : "HTTP \(code)"])
        }
    }

    func handle(_ p: Payload) {
        var e = Entry(id: UUID().uuidString, kind: p.kind.rawValue, from: p.from, ts: p.sentAt)
        switch p.kind {
        case .pair:
            return receivePairRequest(p)
        case .text:
            let text = String(decoding: p.body, as: UTF8.self)
            e.text = text
            if autoCopy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ownChangeCount = NSPasteboard.general.changeCount // don't auto-share it back
            }
            notify("Text from \(p.from)" + (autoCopy ? " · copied" : ""), String(text.prefix(120)))
        case .file:
            let url = uniqueURL(for: safeName(p.name))
            do {
                try p.body.write(to: url, options: .atomic)
                // Mark as downloaded so Gatekeeper checks anything executable.
                var rv = URLResourceValues()
                rv.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                           kLSQuarantineAgentNameKey as String: "Pigeon"]
                var u = url
                try? u.setResourceValues(rv)
            } catch {
                NSLog("Pigeon: couldn't save file: \(error)")
                return
            }
            e.name = url.lastPathComponent
            e.path = url.path
            notify("File from \(p.from)", url.lastPathComponent)
            switch afterReceive {
            case .nothing: break
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
            case .open: NSWorkspace.shared.open(url)
            }
        }
        history.add(e)
        setIcon(active: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.setIcon(active: false) }
    }

    func safeName(_ raw: String?) -> String {
        var n = (raw ?? "file").components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
        while n.hasPrefix(".") { n.removeFirst() }
        n = String(n.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "file" : n
    }

    func uniqueURL(for name: String) -> URL {
        let base = downloadsDir
        var url = base.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            i += 1
        }
        return url
    }

    func notify(_ title: String, _ body: String) {
        guard notificationsOn else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
