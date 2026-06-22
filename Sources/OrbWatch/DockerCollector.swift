import Foundation

/// Collects Docker / OrbStack containers by merging `docker ps -a` (gives every
/// container incl. stopped, with status + image) and `docker stats` (gives live
/// CPU / mem / I/O for running ones only).
struct DockerCollector {
    let runner: CommandRunner

    private struct PSItem: Decodable {
        let Names: String
        let Image: String
        let State: String
        let Status: String
        let RunningFor: String
    }

    private struct StatItem: Decodable {
        let Name: String
        let CPUPerc: String
        let MemUsage: String
        let MemPerc: String
        let NetIO: String
        let BlockIO: String
        let PIDs: String
    }

    func collect() async throws -> [Workload] {
        // `docker ps`/`stats` emit one JSON object per line (not a JSON array).
        async let psOut = runner.run("docker ps -a --format '{{json .}}'")
        async let statsOut = runner.run(
            "docker stats --no-stream --format '{{json .}}'")

        let psItems = decodeLines(try await psOut, as: PSItem.self)
        let statItems = decodeLines(try await statsOut, as: StatItem.self)

        var statsByName: [String: StatItem] = [:]
        for s in statItems { statsByName[s.Name] = s }

        return psItems.map { ps in
            let state = RunState.fromDocker(ps.State)
            var w = Workload(
                id: "docker:\(ps.Names)",
                name: ps.Names,
                kind: .docker,
                state: state,
                statusText: ps.Status,
                cpuPercent: 0,
                memBytes: 0
            )
            w.image = ps.Image
            w.uptime = ps.RunningFor

            if let s = statsByName[ps.Names] {
                w.cpuPercent = Parse.percent(s.CPUPerc)
                let mem = Parse.pair(s.MemUsage)
                w.memBytes = mem.0
                w.memLimitBytes = mem.1
                w.memPercent = Parse.percent(s.MemPerc)
                let net = Parse.pair(s.NetIO)
                w.netRx = net.0
                w.netTx = net.1
                let blk = Parse.pair(s.BlockIO)
                w.blockRead = blk.0
                w.blockWrite = blk.1
                w.pids = Int(s.PIDs)
            }
            return w
        }
    }

    private func decodeLines<T: Decodable>(_ text: String, as: T.Type) -> [T] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}
