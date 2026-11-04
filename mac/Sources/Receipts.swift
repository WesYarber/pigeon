import Foundation

// MARK: - Delivery receipts
// The relay remembers when the receiving Mac picked an item up (see
// server/relay.py, "receipts"). While anything this Mac sent is still waiting,
// ask about it now and then; Recent shows Delivered / Waiting, and a
// notification says when something that had to wait (the other Mac was asleep
// or offline) finally arrived, or expired first. Quick deliveries only get the
// checkmark, so a normal send doesn't notify twice.

extension AppDelegate {
    /// Seconds after sending beyond which a delivery is worth a notification.
    static let deliveryNotifyAfter: TimeInterval = 30

    var notifyDelivered: Bool {
        get { defaults.object(forKey: "notifyDelivered") as? Bool ?? true }
        set { setting("notifyDelivered", newValue) }
    }

    func startReceiptChecks() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReceiptsSoon(after: 0) }
        }
        checkReceiptsSoon(after: 2)
    }

    /// Right after a send, look again shortly: the other Mac usually has it within seconds.
    func checkReceiptsSoon(after delay: TimeInterval) {
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await checkReceipts()
        }
    }

    private var pendingDeliveries: [Entry] {
        let week = Date().addingTimeInterval(-7 * 86_400)
        return history.entries.filter {
            $0.sent == true && $0.relayId != nil && $0.inbox != nil
                && $0.delivered == nil && $0.undelivered != true && $0.ts > week
        }
    }

    private struct ReceiptResponse: Decodable {
        struct Receipt: Decodable { let state: String; let at: Double? }
        let receipts: [String: Receipt]
        let ttlHours: Double?
    }

    func checkReceipts() async {
        let pending = pendingDeliveries
        guard !pending.isEmpty, !checkingReceipts else { return }
        checkingReceipts = true
        defer { checkingReceipts = false }

        for (inbox, entries) in Dictionary(grouping: pending, by: { $0.inbox! }) {
            guard let dest = destinations.first(where: { $0.inbox == inbox }),
                  !receiptsUnsupported.contains(dest.server.absoluteString) else { continue }
            var base = dest.server.absoluteString
            if !base.hasSuffix("/") { base += "/" }
            let ids = entries.compactMap(\.relayId).prefix(200).joined(separator: ",")
            var req = URLRequest(url: URL(string: base + "api/inboxes/\(inbox)/receipts?ids=\(ids)")!, timeoutInterval: 20)
            req.setValue(dest.sendToken, forHTTPHeaderField: "X-Send-Token")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { continue } // offline: try later
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let r = try? JSONDecoder().decode(ReceiptResponse.self, from: data) else {
                // An older relay without receipts answers 404: stop tracking these
                // (so they don't show "Waiting…" forever) and don't ask it again this session.
                if code == 404 {
                    dragLog.notice("receipts: \(dest.server.host ?? "relay", privacy: .public) doesn't support receipts yet")
                    receiptsUnsupported.insert(dest.server.absoluteString)
                    entries.forEach { e in history.update(e.id) { $0.relayId = nil } }
                }
                continue
            }
            let ttl = (r.ttlHours ?? 72) * 3600
            for e in entries {
                guard let id = e.relayId, let receipt = r.receipts[id] else { continue }
                switch receipt.state {
                case "delivered":
                    let at = receipt.at.map { Date(timeIntervalSince1970: $0) } ?? Date()
                    dragLog.notice("receipts: delivered after \(Int(at.timeIntervalSince(e.ts)))s")
                    history.update(e.id) { $0.delivered = at }
                    if notifyDelivered, at.timeIntervalSince(e.ts) > Self.deliveryNotifyAfter {
                        notify("Delivered to \(dest.name)", "\(e.name ?? e.text?.prefix(80).description ?? "Item") · sent \(ago(e.ts))")
                    }
                case "gone":
                    dragLog.notice("receipts: gone after \(Int(Date().timeIntervalSince(e.ts)))s")
                    if Date().timeIntervalSince(e.ts) >= ttl - 300 {
                        history.update(e.id) { $0.undelivered = true }
                        notify("Not delivered to \(dest.name)",
                               "\(e.name ?? "An item") expired on the relay before \(dest.name) came online. Send it again.")
                    } else {
                        // Gone early without a receipt: delivered by a relay from before
                        // receipts existed. Nothing to report; stop tracking it.
                        history.update(e.id) { $0.relayId = nil }
                    }
                default:
                    break // still waiting
                }
            }
        }
    }
}
