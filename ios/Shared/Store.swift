import Foundation

// Shared by the app and the Share extension. Paired Macs (with their send
// tokens) live in the Keychain; both targets list the same keychain access
// group first, so they see the same items. The sent history and settings live
// in the shared app group container.

enum AppGroup {
    static let id = "group.net.wesyarber.pigeon"

    /// The shared container, or this process's own Application Support folder
    /// when the app group isn't available (unsigned simulator builds).
    static var folder: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

// MARK: - Keychain

enum Keychain {
    static let service = "net.wesyarber.pigeon.ios"

    static func get(_ account: String) -> Data? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ account: String, _ data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Paired Macs

/// A Mac this phone can send to. Same fields and pairing link as the Mac app's.
struct Destination: Codable, Hashable, Identifiable {
    var name: String
    var server: URL
    var inbox: String
    var sendToken: String
    var pub: Data

    var id: String { inbox }
    var fingerprint: String { ReceiverKey.fingerprint(of: pub) }

    func api(_ path: String) -> URL {
        var base = server.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + "api/" + path)!
    }

    /// Parses the link a Mac's Pair a Device window shows (also its QR code):
    /// https://host/#p=v1.<inbox>.<token>.<pubkey>
    static func parse(_ link: String, name: String) -> Destination? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hashIdx = link.firstIndex(of: "#"),
              let server = URL(string: String(link[..<hashIdx])),
              server.scheme == "https" || server.host == "127.0.0.1" || server.host == "localhost" else { return nil }
        let frag = link[link.index(after: hashIdx)...]
        guard frag.hasPrefix("p=") else { return nil }
        let parts = frag.dropFirst(2).split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "v1", let pub = Data(base64URL: parts[3]),
              pub.count == 65, pub.first == 0x04 else { return nil }
        return Destination(name: name, server: server, inbox: parts[1], sendToken: parts[2], pub: pub)
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

final class Macs: ObservableObject {
    /// The first one is the default.
    @Published private(set) var list: [Destination] = []

    init() { reload() }

    func reload() {
        list = Keychain.get("destinations").flatMap { try? JSONDecoder().decode([Destination].self, from: $0) } ?? []
    }

    private func save() { Keychain.set("destinations", (try? JSONEncoder().encode(list)) ?? Data()) }

    func add(_ d: Destination) { list.removeAll { $0.inbox == d.inbox }; list.append(d); save() }
    func remove(_ d: Destination) { list.removeAll { $0.inbox == d.inbox }; save() }
    func rename(_ d: Destination, to name: String) {
        guard let i = list.firstIndex(of: d) else { return }
        list[i].name = name; save()
    }
    func move(fromOffsets: IndexSet, toOffset: Int) {
        list.move(fromOffsets: fromOffsets, toOffset: toOffset); save()
    }
    func makeDefault(_ d: Destination) {
        guard let i = list.firstIndex(of: d) else { return }
        list.insert(list.remove(at: i), at: 0); save()
    }
}

// MARK: - Settings

enum Settings {
    /// Shown on the Mac as who sent it ("File from Alex's iPhone").
    static var deviceName: String {
        get { AppGroup.defaults.string(forKey: "deviceName").flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone" }
        set { AppGroup.defaults.set(newValue, forKey: "deviceName") }
    }
}

// MARK: - Sent history

struct SentItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String // "text" | "file"
    var title: String
    var to: String // the Mac's name
    var inbox: String
    var ts = Date()
    var relayId: String?
    var delivered: Date?
    var undelivered: Bool?
}

/// What this phone has sent, newest first. A small JSON file in the app group,
/// written by both the app and the Share extension.
final class SentLog: ObservableObject {
    @Published private(set) var items: [SentItem] = []
    private static var file: URL { AppGroup.folder.appendingPathComponent("sent.json") }

    init() { reload() }

    func reload() {
        items = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([SentItem].self, from: $0) } ?? []
    }

    func add(_ item: SentItem) {
        reload() // the other target may have written since
        items.insert(item, at: 0)
        if items.count > 100 { items = Array(items.prefix(100)) }
        save()
    }

    func update(_ id: String, _ change: (inout SentItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i]); save()
    }

    func clear() { items = []; save() }

    private func save() {
        try? JSONEncoder().encode(items).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
