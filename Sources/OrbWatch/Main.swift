import Foundation

@main
enum Entry {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            await SelfTest.run()
            exit(0)
        }
        if let i = args.firstIndex(of: "--export-icon"), i + 1 < args.count {
            try? AppIcon.exportICNS(to: args[i + 1])
            print("wrote AppIcon.icns to \(args[i + 1])")
            exit(0)
        }
        OrbWatchApp.main()
    }
}

/// Headless check: drives the Monitor through two refreshes and prints the
/// merged table (incl. live net rates), so the pipeline can be verified
/// without the GUI.
enum SelfTest {
    @MainActor
    static func run() async {
        // Two refreshes so net throughput has a prior sample to delta against.
        let monitor = Monitor()
        await monitor.refresh()
        try? await Task.sleep(for: .seconds(2))
        await monitor.refresh()
        let rows = monitor.workloads

        print(String(repeating: "─", count: 104))
        print(pad("WORKLOAD", 26) + pad("KIND", 8) + pad("STATE", 9)
              + pad("CPU%", 7) + pad("MEM", 11) + pad("NET ↓/s", 12)
              + pad("NET ↑/s", 12) + "STATUS")
        for w in rows {
            print(pad(w.name, 26)
                  + pad(w.kind.rawValue, 8)
                  + pad(label(w.state), 9)
                  + pad(String(format: "%.1f", w.cpuPercent), 7)
                  + pad(w.memBytes.humanBytes, 11)
                  + pad(rateString(w.netRxRate), 12)
                  + pad(rateString(w.netTxRate), 12)
                  + w.statusText)
        }
        print(String(repeating: "─", count: 104))
        print("\(rows.count) workloads, "
              + "\(rows.filter { $0.state == .running }.count) running · "
              + String(format: "net ↓%@ ↑%@",
                       rateString(monitor.totalNetRx),
                       rateString(monitor.totalNetTx)))
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n - 1)) + " "
                     : s + String(repeating: " ", count: n - s.count)
    }

    private static func label(_ s: RunState) -> String {
        switch s {
        case .running: return "running"
        case .idle: return "idle"
        case .exited: return "exited"
        case .restarting: return "restart"
        case .paused: return "paused"
        case .created: return "created"
        case .dead: return "dead"
        case .unknown: return "unknown"
        }
    }
}
