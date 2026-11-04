import AppKit
import CryptoKit

// MARK: - `pigeon` command
// install.sh puts a small `pigeon` script on your PATH that runs this binary
// with --cli. It sends directly (same keys, same relay) without the menu bar
// app needing to be open, then tells a running Pigeon to refresh its history.
//
//   pigeon report.pdf                 send to your default Mac
//   pigeon -t work a.png b.png        send to the Mac whose name matches "work"
//   echo hi | pigeon                  send text from stdin
//   pigeon --list                     show the Macs you can send to

extension Destination {
    /// The Mac a name refers to: exact (ignoring case), else the only one that
    /// starts with it, else the only one containing it. nil query = the default.
    static func pick(_ query: String?, from list: [Destination]) -> Result<Destination, PickError> {
        guard let first = list.first else { return .failure(.none) }
        guard let q = query?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty else { return .success(first) }
        if let d = list.first(where: { $0.name.lowercased() == q }) { return .success(d) }
        for matches in [list.filter { $0.name.lowercased().hasPrefix(q) }, list.filter { $0.name.lowercased().contains(q) }] {
            if matches.count == 1 { return .success(matches[0]) }
            if matches.count > 1 { return .failure(.ambiguous(matches.map(\.name))) }
        }
        return .failure(.notFound)
    }

    enum PickError: Error { case none, notFound, ambiguous([String]) }
}

extension History {
    /// Re-read from disk (the `pigeon` command may have added entries).
    func reload() {
        if let d = try? Data(contentsOf: file), let box = try? AES.GCM.SealedBox(combined: d),
           let pt = try? AES.GCM.open(box, using: key),
           let e = try? JSONDecoder().decode([Entry].self, from: pt) { replaceAll(e) }
    }

    static let changedNotification = Notification.Name("net.wesyarber.pigeon.historyChanged" + (Profile.name.map { ".\($0)" } ?? ""))
}

enum CLI {
    static let usage = """
    Usage: pigeon [-t <mac>] <file or folder>...
           echo "some text" | pigeon [-t <mac>]
           pigeon --list

    Sends files, folders (zipped) or text to one of your Macs, end-to-end encrypted.

      -t, --to <mac>   which Mac to send to (part of its name is enough);
                       without it, your default Mac
      -l, --list       list the Macs you can send to
      -h, --help       show this help
    """

    static func run(_ args: [String]) -> Never {
        var to: String?
        var paths: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help": print(usage); exit(0)
            case "-l", "--list": list(); exit(0)
            case "-t", "--to":
                guard i + 1 < args.count else { fail("\(a) needs the name of a Mac") }
                to = args[i + 1]; i += 1
            case "--": paths += args[(i + 1)...]; i = args.count
            default:
                if a.hasPrefix("--to=") { to = String(a.dropFirst(5)) }
                else if a.hasPrefix("-"), a != "-" { fail("unknown option \(a)\n\n\(usage)") }
                else { paths.append(a) }
            }
            i += 1
        }

        let all = Destination.load()
        let dest: Destination
        switch Destination.pick(to, from: all) {
        case .success(let d): dest = d
        case .failure(.none): fail("no Macs to send to yet. Add one in Pigeon (Settings → Sending → Add a Mac).")
        case .failure(.notFound): fail("no Mac matches \"\(to ?? "")\". Your Macs: \(all.map(\.name).joined(separator: ", "))")
        case .failure(.ambiguous(let names)): fail("\"\(to ?? "")\" matches more than one Mac: \(names.joined(separator: ", "))")
        }

        var items: [Outgoing] = []
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for p in paths where p != "-" {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { fail("\(p): no such file or folder") }
            items.append(.file(url))
        }
        if paths.isEmpty || paths.contains("-") {
            guard isatty(STDIN_FILENO) == 0 || paths.contains("-") else { print(usage); exit(1) }
            let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            guard !text.isEmpty else { fail("nothing to send on stdin") }
            items.append(.text(text))
        }

        let device = Host.current().localizedName ?? "Mac"
        Task.detached {
            var failed = false
            var sent: [Entry] = []
            for item in items {
                do {
                    let (label, entry) = try await AppDelegate.deliver(item, to: dest, from: device)
                    print("Sent \(label.replacingOccurrences(of: "\n", with: " ")) to \(dest.name)")
                    if let entry { sent.append(entry) }
                } catch {
                    FileHandle.standardError.write(Data("pigeon: couldn't send to \(dest.name): \(error.localizedDescription)\n".utf8))
                    failed = true
                }
            }
            if !sent.isEmpty {
                let history = History()
                sent.forEach(history.add)
                DistributedNotificationCenter.default().postNotificationName(History.changedNotification, object: nil,
                                                                            userInfo: nil, deliverImmediately: true)
            }
            exit(failed ? 1 : 0)
        }
        dispatchMain()
    }

    private static func list() {
        let all = Destination.load()
        if all.isEmpty { print("No Macs yet. Add one in Pigeon (Settings → Sending → Add a Mac).") }
        for (i, d) in all.enumerated() { print(d.name + (i == 0 ? "  (default)" : "")) }
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("pigeon: \(msg)\n".utf8))
        exit(1)
    }
}
