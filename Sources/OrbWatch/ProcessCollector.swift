import Foundation

/// Collects native (non-Docker) workloads: launchd jobs whose label matches a
/// configured prefix and that currently have a live PID — e.g. the yt-dlp GUI
/// (`com.besttt.ytdlp-gui`). Resource numbers come from `ps`.
struct ProcessCollector {
    let runner: CommandRunner
    /// launchd label prefixes to surface, e.g. ["com.besttt."].
    let prefixes: [String]

    func collect() async throws -> [Workload] {
        guard !prefixes.isEmpty else { return [] }

        // `launchctl list` columns: PID  STATUS  LABEL
        let listOut = try await runner.run("launchctl list")
        var jobs: [(pid: Int, label: String)] = []
        for line in listOut.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard cols.count >= 3, let pid = Int(cols[0]) else { continue }
            let label = cols[2]
            guard prefixes.contains(where: { label.hasPrefix($0) }) else { continue }
            jobs.append((pid, label))
        }
        guard !jobs.isEmpty else { return [] }

        // One ps call for all PIDs: pid %cpu %mem rss(KiB) etime command
        let pidList = jobs.map { String($0.pid) }.joined(separator: ",")
        let psOut = try await runner.run(
            "ps -p \(pidList) -o pid=,pcpu=,pmem=,rss=,etime=,comm=")

        // Per-PID cumulative network bytes via nettop (no sudo needed). Rows:
        // "procname.PID,bytes_in,bytes_out,". Best-effort — skip if it fails.
        let netByPID = await networkByPID()

        var statsByPID: [Int: (cpu: Double, mem: Double, rss: UInt64,
                               etime: String, comm: String)] = [:]
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

        return jobs.map { job in
            let short = job.label
                .replacingOccurrences(of: "com.besttt.", with: "")
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
