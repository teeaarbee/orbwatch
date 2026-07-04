import Foundation
import SwiftUI

/// Drives the polling loop, merges Docker + native collectors, keeps a rolling
/// CPU history per workload for the sparklines, and publishes to the UI.
@MainActor
final class Monitor: ObservableObject {
    @Published var workloads: [Workload] = []
    @Published var pastWorkloads: [HistoryEntry] = []
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?

    private let historyStore = HistoryStore()

    @Published var intervalSeconds: Double = 2
    @Published var paused = false

    /// "local" or an SSH host. Changing it swaps the runner on the next tick.
    @Published var connection: Connection = .local {
        didSet { rebuildRunner() }
    }
    /// Set in the UI (settings → Source: SSH host). e.g. a Tailscale MagicDNS
    /// name like `my-mac.tailnet-name.ts.net`, or any host reachable over SSH.
    @Published var sshHost = ""

    let nativePrefixes = ["com.besttt."]
    /// Native macOS apps (not Docker, no com.besttt. label) tracked by process
    /// pattern. Add more here to surface other background apps.
    let nativeApps = [
        NativeApp(name: "Jellyfin", pattern: "/Applications/Jellyfin.app/")
    ]
    /// launchd services to always surface with a friendly name — shown even when
    /// idle. box-to-drive & thumbnailvault are resident (also caught by the
    /// prefix); subtitle-sync is a daily scheduled job, invisible between runs
    /// without this. Add more curated services here.
    let trackedServices = [
        TrackedService(label: "com.besttt.box-to-drive",   name: "Box → Drive"),
        TrackedService(label: "com.besttt.subtitle-sync",  name: "Subtitle Sync"),
        TrackedService(label: "com.besttt.thumbnailvault", name: "Thumbnail Vault"),
    ]
    private let historyLength = 40
    private var cpuHistory: [String: [Double]] = [:]
    private var netHistory: [String: [Double]] = [:]
    /// Previous cumulative net totals per id, to derive live throughput.
    private var netPrev: [String: (rx: UInt64, tx: UInt64, at: Date)] = [:]
    private var runner: CommandRunner = LocalRunner()

    enum Connection: Equatable { case local, ssh }

    var connectionLabel: String { runner.label }

    // Aggregates for the header.
    var runningCount: Int { workloads.filter { $0.state == .running }.count }
    var totalCount: Int { workloads.count }
    var totalCPU: Double { workloads.reduce(0) { $0 + $1.cpuPercent } }
    var totalMem: UInt64 { workloads.reduce(0) { $0 + $1.memBytes } }
    var totalNetRx: Double { workloads.reduce(0) { $0 + ($1.netRxRate ?? 0) } }
    var totalNetTx: Double { workloads.reduce(0) { $0 + ($1.netTxRate ?? 0) } }

    private func rebuildRunner() {
        switch connection {
        case .local: runner = LocalRunner()
        case .ssh: runner = SSHRunner(host: sshHost)
        }
    }

    func applySSHHost() {
        if connection == .ssh { runner = SSHRunner(host: sshHost) }
    }

    func clearHistory() {
        historyStore.clear()
        pastWorkloads = []
    }

    /// Background loop, started from the view. Reads `intervalSeconds` each pass
    /// so the slider takes effect live.
    func runLoop() async {
        while !Task.isCancelled {
            if !paused { await refresh() }
            let secs = max(1, intervalSeconds)
            try? await Task.sleep(for: .seconds(secs))
        }
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let activeRunner = runner
        let docker = DockerCollector(runner: activeRunner)
        let native = ProcessCollector(runner: activeRunner,
                                      prefixes: nativePrefixes, apps: nativeApps,
                                      services: trackedServices)

        do {
            // Docker is the headline source; if it fails we surface the error.
            // Native is best-effort so one failure doesn't blank the table.
            async let dockerRows = docker.collect()
            async let nativeRows = nativeOrEmpty(native)

            var rows = try await dockerRows
            rows.append(contentsOf: await nativeRows)

            let now = Date()
            for i in rows.indices {
                let id = rows[i].id

                // CPU rolling history.
                var cpu = cpuHistory[id, default: []]
                cpu.append(rows[i].cpuPercent)
                trim(&cpu)
                cpuHistory[id] = cpu
                rows[i].cpuHistory = cpu

                // Net rate from the delta of cumulative counters.
                if let rx = rows[i].netRx, let tx = rows[i].netTx {
                    if let prev = netPrev[id] {
                        let dt = now.timeIntervalSince(prev.at)
                        if dt > 0.2 {
                            rows[i].netRxRate = rate(rx, prev.rx, dt)
                            rows[i].netTxRate = rate(tx, prev.tx, dt)
                        }
                    }
                    netPrev[id] = (rx, tx, now)
                }
                var net = netHistory[id, default: []]
                net.append((rows[i].netRxRate ?? 0) + (rows[i].netTxRate ?? 0))
                trim(&net)
                netHistory[id] = net
                rows[i].netHistory = net
            }
            // Drop bookkeeping for workloads that disappeared.
            let live = Set(rows.map(\.id))
            cpuHistory = cpuHistory.filter { live.contains($0.key) }
            netHistory = netHistory.filter { live.contains($0.key) }
            netPrev = netPrev.filter { live.contains($0.key) }

            // Fold into persistent history; surface anything not running now.
            historyStore.record(rows, at: now)
            let runningNow = Set(rows.filter { $0.state == .running }.map(\.id))
            pastWorkloads = historyStore.entries.values
                .filter { !runningNow.contains($0.id) }
                .sorted { $0.lastSeen > $1.lastSeen }

            workloads = rows.sorted(by: defaultOrder)
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nativeOrEmpty(_ c: ProcessCollector) async -> [Workload] {
        (try? await c.collect()) ?? []
    }

    private func trim(_ arr: inout [Double]) {
        if arr.count > historyLength { arr.removeFirst(arr.count - historyLength) }
    }

    /// bytes/sec from a cumulative-counter delta; 0 on counter reset (restart).
    private func rate(_ cur: UInt64, _ prev: UInt64, _ dt: TimeInterval) -> Double {
        cur >= prev ? Double(cur - prev) / dt : 0
    }

    private func defaultOrder(_ a: Workload, _ b: Workload) -> Bool {
        if a.state.sortRank != b.state.sortRank {
            return a.state.sortRank < b.state.sortRank
        }
        if a.cpuPercent != b.cpuPercent { return a.cpuPercent > b.cpuPercent }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
