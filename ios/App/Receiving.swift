import BackgroundTasks
import CryptoKit
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Receiving on this iPhone
// Like a Mac, the phone can have its own inbox on the relay and a key that
// only it holds (in the Secure Enclave). Your Macs add it as a destination
// after you approve its pairing request on them. iOS doesn't let apps keep a
// connection open in the background, so items arrive right away while Pigeon
// is open, and otherwise when iOS lets it check in the background (it then
// posts a notification) or the next time you open it.

/// This iPhone's inbox on the relay.
struct InboxConfig: Codable {
    var server: URL
    var inbox: String
    var sendToken: String
    var recvToken: String

    func api(_ path: String) -> URL {
        var base = server.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + "api/" + path)!
    }

    /// The link a Mac adds to send here (same format the Mac shows).
    func pairingLink(pub: Data) -> String {
        var base = server.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return "\(base)#p=v1.\(inbox).\(sendToken).\(pub.base64URL)"
    }
}

enum ReceiveSettings {
    static var addMediaToPhotos: Bool {
        get { AppGroup.defaults.object(forKey: "addMediaToPhotos") as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: "addMediaToPhotos") }
    }
    static var copyText: Bool {
        get { AppGroup.defaults.object(forKey: "copyReceivedText") as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: "copyReceivedText") }
    }
}

@MainActor
final class Receiver: ObservableObject {
    static let shared = Receiver()
    static let refreshTask = "net.wesyarber.pigeon.ios.refresh"

    enum Status: Equatable { case off, connecting, connected, offline }

    @Published private(set) var config: InboxConfig?
    @Published private(set) var status: Status = .off
    private(set) var key: ReceiverKey?
    /// Shown briefly in the app when something arrives ("Received Report.pdf").
    var onReceive: ((String) -> Void)?
    private var loop: Task<Void, Never>?

    private init() {
        config = Keychain.get("inbox").flatMap { try? JSONDecoder().decode(InboxConfig.self, from: $0) }
        key = Keychain.get("receiverKey").flatMap { ReceiverKey(serialized: $0) }
        if config == nil || key == nil { config = nil }
    }

    var isOn: Bool { config != nil }
    var pairingLink: String? { config.flatMap { c in key.map { c.pairingLink(pub: $0.publicKey) } } }
    var fingerprint: String? { key?.fingerprint }

    // MARK: Setup

    enum SetupError: LocalizedError {
        case badSecret, server(Int), unreachable(String)
        var errorDescription: String? {
            switch self {
            case .badSecret: return "The admin secret was wrong."
            case .server(let code): return "The relay said \(code)."
            case .unreachable(let why): return "Couldn't reach the relay: \(why)"
            }
        }
    }

    /// Creates this iPhone's key and inbox (the admin secret is used once and
    /// not kept), then asks each paired Mac to send back here.
    func turnOn(server: URL, adminSecret: String, macs: [Destination]) async throws {
        let key = ReceiverKey.generate()
        let cfg = InboxConfig(server: server, inbox: Data.random(16).base64URL,
                              sendToken: Data.random(32).base64URL, recvToken: Data.random(32).base64URL)
        func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        var req = URLRequest(url: cfg.api("inboxes"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(adminSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": cfg.inbox, "sendHash": hash(cfg.sendToken), "recvHash": hash(cfg.recvToken)])
        let code: Int
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw SetupError.unreachable(error.localizedDescription)
        }
        guard code == 201 else { throw code == 401 ? SetupError.badSecret : SetupError.server(code) }

        Keychain.set("receiverKey", key.serialized)
        Keychain.set("inbox", try JSONEncoder().encode(cfg))
        self.key = key
        config = cfg
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await askToPair(macs)
        start()
    }

    /// Sends this iPhone's pairing link to each Mac; it shows "Send back to …?" there.
    func askToPair(_ macs: [Destination]) async {
        guard let link = pairingLink else { return }
        for mac in macs { try? await Sender.send(.pair(link), to: mac, log: SentLog()) }
    }

    /// Forgets this iPhone's key and inbox. Macs that send here get an error until they remove it.
    func turnOff() {
        stop()
        Keychain.delete("inbox")
        Keychain.delete("receiverKey")
        config = nil
        key = nil
        status = .off
    }

    // MARK: Fetching

    /// While the app is open: wait on the relay so items arrive within a second or two.
    func start() {
        guard isOn, loop == nil else { return }
        applyPendingClipboard()
        status = .connecting
        loop = Task { [weak self] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    _ = try await self.fetch(wait: self.status == .connected ? 25 : 0)
                    self.status = .connected
                    backoff = 2
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.status = .offline
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if isOn { status = .connecting }
    }

    /// One check; returns how many items were saved. Used by the open app and by background checks.
    @discardableResult
    func fetch(wait: Int) async throws -> Int {
        guard let cfg = config, let key else { return 0 }
        func request(_ path: String, _ method: String = "GET", timeout: TimeInterval) -> URLRequest {
            var r = URLRequest(url: cfg.api(path), timeoutInterval: timeout)
            r.httpMethod = method
            r.setValue(cfg.recvToken, forHTTPHeaderField: "X-Recv-Token")
            r.cachePolicy = .reloadIgnoringLocalCacheData
            return r
        }
        struct List: Decodable { struct Item: Decodable { let id: String }; let items: [Item] }
        let (data, resp) = try await URLSession.shared.data(for: request("inboxes/\(cfg.inbox)/items?wait=\(wait)", timeout: TimeInterval(wait + 15)))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var saved = 0
        for item in try JSONDecoder().decode(List.self, from: data).items {
            let (blob, r2) = try await URLSession.shared.data(for: request("inboxes/\(cfg.inbox)/items/\(item.id)", timeout: 300))
            guard (r2 as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if let payload = try? Envelope.open(blob, with: key), let (summary, entry) = await handle(payload) {
                saved += 1
                SentLog().add(entry) // shows in Recent (the app reloads it when told below)
                announce(summary, from: payload.from)
            }
            // Delivered (or unreadable): remove it either way, which also tells the sender.
            _ = try? await URLSession.shared.data(for: request("inboxes/\(cfg.inbox)/items/\(item.id)", "DELETE", timeout: 30))
        }
        return saved
    }

    // MARK: Handling what arrives

    /// Saves one item; returns a short description and its Recent entry, or nil if there was nothing to save.
    private func handle(_ p: Payload) async -> (String, SentItem)? {
        let from = String(p.from.prefix(40))
        switch p.kind {
        case .pair:
            return nil // the phone sends to Macs it paired with itself; ignore requests
        case .text:
            let text = String(decoding: p.body, as: UTF8.self)
            if ReceiveSettings.copyText { copyToClipboard(text) }
            var e = SentItem(kind: "text", title: String(text.replacingOccurrences(of: "\n", with: " ").prefix(80)), to: from, inbox: "")
            e.ts = p.sentAt
            e.received = true
            e.savedTo = ReceiveSettings.copyText ? "clipboard" : "none"
            e.text = String(text.prefix(5_000))
            return (ReceiveSettings.copyText ? "Text copied: \(text.prefix(60))" : "Text: \(text.prefix(60))", e)
        case .file:
            let name = Self.safeName(p.name)
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            let isMedia = type.map { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? false
            var e = SentItem(kind: "file", title: name, to: from, inbox: "")
            e.ts = p.sentAt
            e.received = true
            if isMedia, ReceiveSettings.addMediaToPhotos, await addToPhotos(p.body, name: name, video: type?.conforms(to: .movie) == true) {
                e.savedTo = "photos"
                return ("\(name) added to Photos", e)
            }
            guard let url = try? saveToFiles(p.body, name: name) else { return nil }
            e.title = url.lastPathComponent
            e.savedTo = "files"
            e.fileName = url.lastPathComponent
            return ("\(url.lastPathComponent) saved to Files", e)
        }
    }

    /// Received files live in the app's Documents folder, which the Files app
    /// shows as On My iPhone → Pigeon.
    private func saveToFiles(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var url = dir.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            i += 1
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Adds a photo or video to the library (add-only permission; Pigeon can't read your photos).
    private func addToPhotos(_ data: Data, name: String, video: Bool) async -> Bool {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        guard (try? data.write(to: tmp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: tmp, options: options)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Clipboard
    // iOS only lets the frontmost app write the clipboard, so text that
    // arrives in the background is copied when you next open Pigeon.

    private func copyToClipboard(_ text: String) {
        if UIApplication.shared.applicationState == .active {
            UIPasteboard.general.string = text
        } else {
            AppGroup.defaults.set(text, forKey: "pendingClipboard")
        }
    }

    func applyPendingClipboard() {
        guard let text = AppGroup.defaults.string(forKey: "pendingClipboard") else { return }
        AppGroup.defaults.removeObject(forKey: "pendingClipboard")
        UIPasteboard.general.string = text
        onReceive?("Copied the text from your Mac")
    }

    // MARK: Telling you

    private func announce(_ summary: String, from: String) {
        if UIApplication.shared.applicationState == .active {
            onReceive?(summary)
        } else {
            let c = UNMutableNotificationContent()
            c.title = "From \(from)"
            c.body = summary
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    // MARK: Background checks

    /// Asks iOS to wake Pigeon in the background now and then (iOS picks the time).
    func scheduleBackgroundCheck() {
        guard isOn else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs when iOS wakes the app for a background check.
    func backgroundCheck() async {
        scheduleBackgroundCheck()
        _ = try? await fetch(wait: 0)
    }

    static func safeName(_ raw: String?) -> String {
        var n = (raw ?? "file").components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
        while n.hasPrefix(".") { n.removeFirst() }
        n = String(n.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "file" : n
    }
}
