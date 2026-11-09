import SwiftUI

@main
struct PigeonApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .onChange(of: phase) { _, now in if now == .active { model.becameActive() } }
        }
    }
}

/// The app's state: paired Macs, what's being sent, and the sent history.
@MainActor
final class AppModel: ObservableObject {
    let macs = Macs()
    let log = SentLog()
    @Published var targetInbox: String?
    @Published var progress: Double?      // non-nil while sending
    @Published var sendingTitle = ""
    @Published var message: String?       // last error or "Sent", shown briefly
    private var queue: [(Outgoing, Destination)] = []
    private var receiptTimer: Timer?

    /// Where the Send buttons send: the picked Mac, else the default.
    var target: Destination? { macs.list.first { $0.inbox == targetInbox } ?? macs.list.first }

    func becameActive() {
        macs.reload()
        log.reload()
        objectWillChange.send()
        // Big files the Share extension couldn't handle wait in the outbox.
        for (job, file) in Outbox.jobs() {
            guard let dest = macs.list.first(where: { $0.inbox == job.inbox }) else { Outbox.remove(job); continue }
            enqueue([.file(file, name: job.name)], to: dest) { Outbox.remove(job) }
        }
        watchReceipts()
    }

    // MARK: Sending

    private var onDone: [() -> Void] = []

    func enqueue(_ items: [Outgoing], to dest: Destination? = nil, then done: (() -> Void)? = nil) {
        guard let dest = dest ?? target else { return }
        queue += items.map { ($0, dest) }
        if let done { onDone.append(done) }
        if progress == nil { Task { await drain() } }
    }

    private func drain() async {
        var sent = 0
        while !queue.isEmpty {
            let (item, dest) = queue.removeFirst()
            sendingTitle = item.title
            progress = 0
            do {
                try await Sender.send(item, to: dest, log: log) { p in Task { @MainActor in self.progress = p } }
                Self.removeTemporaryCopy(of: item)
                sent += 1
                objectWillChange.send()
            } catch {
                message = "Couldn't send \(item.title): \(error.localizedDescription)"
            }
        }
        progress = nil
        onDone.forEach { $0() }
        onDone = []
        if sent > 0, message == nil { flash(sent == 1 ? "Sent" : "Sent \(sent) items") }
        watchReceipts()
    }

    /// Picked and pasted files are copied into the temporary folder to be read;
    /// once sent, the copy shouldn't linger on the phone.
    private static func removeTemporaryCopy(of item: Outgoing) {
        guard case .file(let url, _) = item else { return }
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(tmp) else { return }
        let parent = url.deletingLastPathComponent()
        // Pickers put each copy in its own folder; remove that folder, else just the file.
        try? FileManager.default.removeItem(at: parent.standardizedFileURL.path == tmp ? url : parent)
    }

    func flash(_ text: String) {
        message = text
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if message == text { message = nil } }
    }

    // MARK: Delivery receipts

    /// While anything is waiting, ask every 15 seconds (only while the app is open).
    func watchReceipts() {
        Task { await refreshReceipts() }
        guard receiptTimer == nil else { return }
        receiptTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { return t.invalidate() }
                if Receipts.pending(self.log).isEmpty { t.invalidate(); self.receiptTimer = nil; return }
                await self.refreshReceipts()
            }
        }
    }

    func refreshReceipts() async {
        await Receipts.refresh(log, macs: macs.list)
        objectWillChange.send()
    }
}
