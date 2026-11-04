import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Something to send: text (links are sent as text, like the web page does) or a file.
enum Outgoing {
    case text(String)
    case file(URL, name: String)

    var title: String {
        switch self {
        case .text(let s): return String(s.replacingOccurrences(of: "\n", with: " ").prefix(80))
        case .file(_, let name): return name
        }
    }
}

enum SendError: LocalizedError {
    case tooLarge(String, Int)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let mb): return "\(name) is over \(mb) MB"
        case .server(404, let mac): return "\(mac)'s pairing changed. Add it again."
        case .server(413, _): return "Too large for the relay"
        case .server(let code, _): return "The relay said \(code)"
        }
    }
}

enum Sender {
    /// The Share extension has ~120 MB of memory, and encrypting needs about
    /// twice the file's size, so it hands bigger files to the app (see Outbox).
    static let shareExtensionLimit = 30 * 1024 * 1024
    static let relayLimit = 100 * 1024 * 1024

    /// Encrypts one item to `dest`, uploads it, and records it in the sent log.
    static func send(_ item: Outgoing, to dest: Destination, log: SentLog,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var header: [String: Any] = ["v": 1, "ts": Date().timeIntervalSince1970 * 1000, "from": Settings.deviceName]
        let body: Data
        switch item {
        case .text(let s):
            header["kind"] = "text"
            body = Data(s.utf8)
        case .file(let url, let name):
            body = try readForSending(url)
            header["kind"] = "file"
            header["name"] = name
            header["size"] = body.count
            header["type"] = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        guard body.count <= relayLimit else { throw SendError.tooLarge(item.title, relayLimit >> 20) }

        // Seal (same envelope format as the Mac) straight into a file and
        // upload from it, so the envelope is never copied in memory again.
        let envelope = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: envelope) }
        try Envelope.seal(header: header, body: body, to: dest.pub, into: envelope)

        var req = URLRequest(url: dest.api("inboxes/\(dest.inbox)/items"), timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue(dest.sendToken, forHTTPHeaderField: "X-Send-Token")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: envelope, delegate: ProgressDelegate(progress))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 else { throw SendError.server(code, dest.name) }

        let relayId = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
        log.add(SentItem(kind: header["kind"] as! String, title: item.title, to: dest.name, inbox: dest.inbox, relayId: relayId))
    }

    /// Files are read as-is; folders are zipped by the system first.
    private static func readForSending(_ url: URL) throws -> Data {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else { return try Data(contentsOf: url, options: .alwaysMapped) }
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordError) { zip in
            result = Result { try Data(contentsOf: zip) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// Size on disk (folders count as their contents), to decide where to send from.
    static func size(of url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard v.isDirectory == true else { return v.fileSize ?? 0 }
        return (FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))?
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: keys).fileSize } }
            .reduce(0, +)) ?? 0
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

// MARK: - Delivery receipts (same relay API the Mac uses)

enum Receipts {
    private struct Response: Decodable {
        struct Receipt: Decodable { let state: String; let at: Double? }
        let receipts: [String: Receipt]
        let ttlHours: Double?
    }

    static func pending(_ log: SentLog) -> [SentItem] {
        log.items.filter { $0.relayId != nil && $0.delivered == nil && $0.undelivered != true && $0.ts > Date().addingTimeInterval(-7 * 86_400) }
    }

    /// Asks each relay about items still waiting and records the answers.
    static func refresh(_ log: SentLog, macs: [Destination]) async {
        for (inbox, items) in Dictionary(grouping: pending(log), by: \.inbox) {
            guard let dest = macs.first(where: { $0.inbox == inbox }) else { continue }
            let ids = items.compactMap(\.relayId).prefix(200).joined(separator: ",")
            var req = URLRequest(url: URL(string: dest.api("inboxes/\(inbox)/receipts").absoluteString + "?ids=\(ids)")!, timeoutInterval: 20)
            req.setValue(dest.sendToken, forHTTPHeaderField: "X-Send-Token")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { continue }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let r = try? JSONDecoder().decode(Response.self, from: data) else {
                // An older relay without receipts: stop tracking so nothing waits forever.
                if code == 404 { await MainActor.run { items.forEach { i in log.update(i.id) { $0.relayId = nil } } } }
                continue
            }
            let ttl = (r.ttlHours ?? 72) * 3600
            await MainActor.run {
                for i in items {
                    guard let id = i.relayId, let receipt = r.receipts[id] else { continue }
                    if receipt.state == "delivered" {
                        log.update(i.id) { $0.delivered = receipt.at.map { Date(timeIntervalSince1970: $0) } ?? Date() }
                    } else if receipt.state == "gone" {
                        let expired = Date().timeIntervalSince(i.ts) >= ttl - 300
                        log.update(i.id) { if expired { $0.undelivered = true } else { $0.relayId = nil } }
                    }
                }
            }
        }
    }
}

extension NSItemProvider {
    /// Text and links, whichever form the source offered them in (a string,
    /// raw UTF-8 data, an NSURL…); `loadItem` alone often hands back Data.
    func loadString() async -> String? {
        guard canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { c in _ = loadObject(ofClass: String.self) { s, _ in c.resume(returning: s) } }
    }

    func loadURL() async -> URL? {
        guard canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { c in _ = loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) } }
    }
}
