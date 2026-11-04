import Foundation

/// Files too big for the Share extension's memory wait here (in the app group)
/// until the Pigeon app is opened, which sends them.
enum Outbox {
    struct Job: Codable {
        var id = UUID().uuidString
        var inbox: String
        var name: String
    }

    static var folder: URL {
        let f = AppGroup.folder.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// Copies the file in (the share sheet's copy goes away when it closes).
    static func add(_ url: URL, name: String, to dest: Destination) throws {
        let job = Job(inbox: dest.inbox, name: name)
        let dir = folder.appendingPathComponent(job.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
        try JSONEncoder().encode(job).write(to: dir.appendingPathComponent("job.json"))
    }

    /// Waiting jobs with the file to send.
    static func jobs() -> [(job: Job, file: URL)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("job.json")),
                  let job = try? JSONDecoder().decode(Job.self, from: d) else { return nil }
            return (job, dir.appendingPathComponent(job.name))
        }
    }

    static func remove(_ job: Job) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(job.id, isDirectory: true))
    }
}
