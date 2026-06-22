import Foundation

/// A workload OrbWatch has seen at some point. Persisted across launches so the
/// History tab can show containers/services that ran in the past but aren't
/// running now (stopped, or removed entirely).
struct HistoryEntry: Identifiable, Codable {
    var id: String
    var name: String
    var kind: String          // "Docker" / "Native"
    var image: String?
    var lastStatus: String
    var firstSeen: Date
    var lastSeen: Date         // last time we saw it at all
    var lastRunningAt: Date?   // last time it was actually running
    var seenCount: Int         // refreshes it appeared in
}

/// Loads/saves history JSON and folds live observations into it.
final class HistoryStore {
    private(set) var entries: [String: HistoryEntry] = [:]
    private let url: URL
    private let cap = 250

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrbWatch", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        load()
    }

    /// Records the currently-observed workloads. Anything not in `live` simply
    /// keeps its existing entry (so it surfaces as "gone").
    func record(_ live: [Workload], at now: Date) {
        for w in live {
            if var e = entries[w.id] {
                e.name = w.name
                e.image = w.image ?? e.image
                e.lastStatus = w.statusText
                e.lastSeen = now
                e.seenCount += 1
                if w.state == .running { e.lastRunningAt = now }
                entries[w.id] = e
            } else {
                entries[w.id] = HistoryEntry(
                    id: w.id, name: w.name, kind: w.kind.rawValue,
                    image: w.image, lastStatus: w.statusText,
                    firstSeen: now, lastSeen: now,
                    lastRunningAt: w.state == .running ? now : nil,
                    seenCount: 1)
            }
        }
        if entries.count > cap {
            let keep = entries.values.sorted { $0.lastSeen > $1.lastSeen }
                .prefix(cap).map { ($0.id, $0) }
            entries = Dictionary(uniqueKeysWithValues: keep)
        }
        save()
    }

    func clear() {
        entries = [:]
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func save() {
        let list = Array(entries.values)
        let target = url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: target)
            }
        }
    }
}
