import Foundation

/// A native macOS app (not a `com.besttt.` launchd job and not Docker) to track
/// by matching its processes with `pgrep -f`. All matching PIDs are aggregated
/// into a single workload row — e.g. Jellyfin runs as a wrapper + server pair.
struct NativeApp {
    let name: String
    /// `pgrep -f` pattern matched against the full command line.
    let pattern: String
}

/// A launchd job to always surface with a friendly display name — including
/// when it's loaded but not currently running (e.g. a scheduled daily job like
/// `com.besttt.subtitle-sync` that only spins up its PID at 04:00). Without this
/// such jobs are invisible between runs since the prefix filter needs a live PID.
struct TrackedService {
    let label: String   // full launchd label, e.g. "com.besttt.subtitle-sync"
    let name: String    // friendly display name, e.g. "Subtitle Sync"
}

/// Collects native (non-Docker) workloads from two sources: launchd jobs whose
/// label matches a configured prefix (e.g. the yt-dlp GUI `com.besttt.ytdlp-gui`)
/// and named apps matched by `pgrep` (e.g. Jellyfin). Resource numbers from `ps`.
struct ProcessCollector {
    let runner: CommandRunner
    /// launchd label prefixes to surface, e.g. ["com.besttt."].
    let prefixes: [String]
    /// Named native apps to surface by process pattern, e.g. Jellyfin.
    var apps: [NativeApp] = []
    /// launchd jobs to always surface (friendly-named, shown even when idle).
    var services: [TrackedService] = []

    private typealias Stat = (cpu: Double, mem: Double, rss: UInt64,
                              etime: String, comm: String)

    func collect() async throws -> [Workload] {
        // launchd jobs matching a prefix. `launchctl list` cols: PID STATUS LABEL
        // (PID is "-" for a loaded-but-not-running job). Track the set of loaded
        // labels too, so tracked services can be surfaced while idle.
        var jobs: [(pid: Int, label: String)] = []
        var loadedLabels = Set<String>()
        if !prefixes.isEmpty || !services.isEmpty {
            let listOut = try await runner.run("launchctl list")
            for line in listOut.split(whereSeparator: \.isNewline) {
                let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard cols.count >= 3 else { continue }
                let label = cols[2]
                loadedLabels.insert(label)
                guard let pid = Int(cols[0]) else { continue }
                guard prefixes.contains(where: { label.hasPrefix($0) }) else { continue }
                jobs.append((pid, label))
            }
        }

        // Named apps: one `pgrep -f` per app → its set of live PIDs.
        var appHits: [(app: NativeApp, pids: [Int])] = []
        for app in apps {
            guard let out = try? await runner.run(
                "pgrep -f '\(app.pattern)'") else { continue }
            let pids = out.split(whereSeparator: \.isNewline)
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if !pids.isEmpty { appHits.append((app, pids)) }
        }

        let allPIDs = Set(jobs.map(\.pid) + appHits.flatMap(\.pids))
        guard !allPIDs.isEmpty else { return [] }

        // One ps call for every PID: pid %cpu %mem rss(KiB) etime command
        let pidList = allPIDs.map(String.init).joined(separator: ",")
        let psOut = try await runner.run(
            "ps -p \(pidList) -o pid=,pcpu=,pmem=,rss=,etime=,comm=")

        // Per-PID cumulative network bytes via nettop (no sudo needed). Rows:
        // "procname.PID,bytes_in,bytes_out,". Best-effort — skip if it fails.
        let netByPID = await networkByPID()

        var statsByPID: [Int: Stat] = [:]
        for line in psOut.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count >= 6, let pid = Int(f[0]) else { continue }
            let comm = f[5...].joined(separator: " ")
            statsByPID[pid] = (
                cpu: Double(f[1]) ?? 0,
                mem: Double(f[2]) ?? 0,
                rss: (UInt64(f[3]) ?? 0) * 1024,
                etime: f[4],
                comm: comm
            )
        }

        // Friendly display names for tracked launchd labels.
        let nameFor = Dictionary(services.map { ($0.label, $0.name) },
                                 uniquingKeysWith: { a, _ in a })

        var rows = jobs.map { job in
            let short = nameFor[job.label]
                ?? job.label.replacingOccurrences(of: "com.besttt.", with: "")
            var w = Workload(
                id: "native:\(job.label)",
                name: short,
                kind: .native,
                state: .running,
                statusText: "running (pid \(job.pid))",
                cpuPercent: 0,
                memBytes: 0
            )
            w.pids = 1
            w.detail = job.label
            if let s = statsByPID[job.pid] {
                w.cpuPercent = s.cpu
                w.memBytes = s.rss
                w.memPercent = s.mem
                w.uptime = humanizeETime(s.etime)
                w.detail = "\(job.label)  ·  \(s.comm)"
            }
            if let n = netByPID[job.pid] {
                w.netRx = n.in
                w.netTx = n.out
            }
            return w
        }

        // One aggregated row per named app: sum CPU/mem/net across its PIDs,
        // report the longest-running PID's uptime.
        for hit in appHits {
            var cpu = 0.0, memPct = 0.0
            var rss: UInt64 = 0
            var rx: UInt64 = 0, tx: UInt64 = 0
            var haveNet = false
            var longest = -1, longestEtime = ""
            for pid in hit.pids {
                if let s = statsByPID[pid] {
                    cpu += s.cpu; memPct += s.mem; rss += s.rss
                    let secs = etimeSeconds(s.etime)
                    if secs > longest { longest = secs; longestEtime = s.etime }
                }
                if let n = netByPID[pid] { rx += n.in; tx += n.out; haveNet = true }
            }
            let procWord = hit.pids.count == 1 ? "proc" : "procs"
            var w = Workload(
                id: "app:\(hit.app.name)",
                name: hit.app.name,
                kind: .native,
                state: .running,
                statusText: "running (\(hit.pids.count) \(procWord))",
                cpuPercent: cpu,
                memBytes: rss
            )
            w.pids = hit.pids.count
            w.memPercent = memPct
            w.uptime = longest >= 0 ? humanizeETime(longestEtime) : nil
            w.detail = "native app  ·  pids \(hit.pids.sorted().map(String.init).joined(separator: ", "))"
            if haveNet { w.netRx = rx; w.netTx = tx }
            rows.append(w)
        }

        // Tracked services that aren't running right now: surface them anyway so
        // scheduled jobs (e.g. the daily subtitle-sync) stay on the dashboard.
        // A loaded label with no live PID is "idle" (waiting for its next fire);
        // an entirely missing label is "not loaded".
        let runningLabels = Set(jobs.map(\.label))
        for svc in services where !runningLabels.contains(svc.label) {
            let loaded = loadedLabels.contains(svc.label)
            var w = Workload(
                id: "native:\(svc.label)",
                name: svc.name,
                kind: .native,
                state: loaded ? .idle : .exited,
                statusText: loaded ? "loaded · idle (scheduled)" : "not loaded",
                cpuPercent: 0,
                memBytes: 0
            )
            w.detail = svc.label
            rows.append(w)
        }

        return rows
    }

    private func networkByPID() async -> [Int: (in: UInt64, out: UInt64)] {
        guard let out = try? await runner.run(
            "nettop -P -L 1 -x -J bytes_in,bytes_out") else { return [:] }
        var map: [Int: (in: UInt64, out: UInt64)] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            // f[0] is "procname.PID"; take the PID after the last dot.
            guard let dot = f[0].lastIndex(of: "."),
                  let pid = Int(f[0][f[0].index(after: dot)...]) else { continue }
            map[pid] = (UInt64(f[1].trimmingCharacters(in: .whitespaces)) ?? 0,
                        UInt64(f[2].trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        return map
    }

    /// "10:59:32" / "04-00:09:13" -> total elapsed seconds (for picking the
    /// longest-running PID of an aggregated app).
    private func etimeSeconds(_ etime: String) -> Int {
        var days = 0
        var rest = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[..<dash]) ?? 0
            rest = String(etime[etime.index(after: dash)...])
        }
        let p = rest.split(separator: ":").map { Int($0) ?? 0 }
        let h = p.count == 3 ? p[0] : 0
        let m = p.count >= 2 ? p[p.count - 2] : 0
        let s = p.last ?? 0
        return ((days * 24 + h) * 60 + m) * 60 + s
    }

    /// "10:59:32" / "04-00:09:13" -> "10h 59m" / "4d 0h"
    private func humanizeETime(_ etime: String) -> String {
        var days = 0
        var rest = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[..<dash]) ?? 0
            rest = String(etime[etime.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        let h = parts.count == 3 ? parts[0] : 0
        let m = parts.count == 3 ? parts[1] : (parts.first ?? 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
