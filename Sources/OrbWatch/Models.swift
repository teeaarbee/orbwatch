import Foundation
import SwiftUI

enum WorkloadKind: String {
    case docker = "Docker"
    case native = "Native"

    var symbol: String {
        switch self {
        case .docker: return "shippingbox.fill"
        case .native: return "gearshape.2.fill"
        }
    }
}

enum RunState {
    case running
    case idle        // launchd job loaded but not currently running (e.g. a
                     // scheduled daily job waiting for its next fire)
    case exited
    case restarting
    case paused
    case created
    case dead
    case unknown

    /// Maps Docker's `State` field (or a native running flag) to our enum.
    static func fromDocker(_ state: String) -> RunState {
        switch state.lowercased() {
        case "running": return .running
        case "exited": return .exited
        case "restarting": return .restarting
        case "paused": return .paused
        case "created": return .created
        case "dead": return .dead
        default: return .unknown
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .idle: return .teal
        case .exited, .dead: return .red
        case .restarting, .created: return .orange
        case .paused: return .yellow
        case .unknown: return .gray
        }
    }

    var sortRank: Int {
        switch self {
        case .running: return 0
        case .idle: return 1
        case .restarting: return 2
        case .paused: return 3
        case .created: return 4
        case .exited: return 5
        case .dead: return 6
        case .unknown: return 7
        }
    }
}

/// One unified row in the table — a Docker container or a native process.
struct Workload: Identifiable {
    let id: String          // stable key: "docker:<name>" / "native:<label>"
    var name: String
    var kind: WorkloadKind
    var state: RunState
    var statusText: String  // "Up 2 hours (healthy)" / "running" / "exited (0)"

    var cpuPercent: Double          // can exceed 100 (multi-core)
    var memBytes: UInt64
    var memLimitBytes: UInt64?      // Docker only
    var memPercent: Double?

    var netRx: UInt64?              // cumulative bytes received
    var netTx: UInt64?              // cumulative bytes sent
    var netRxRate: Double?          // live bytes/sec in  (computed by Monitor)
    var netTxRate: Double?          // live bytes/sec out (computed by Monitor)
    var blockRead: UInt64?
    var blockWrite: UInt64?
    var pids: Int?

    var image: String?              // Docker image
    var uptime: String?             // human "2 hours ago" / elapsed
    var detail: String?             // extra line (e.g. launchd label, command)

    // Filled in by Monitor from its rolling history store.
    var cpuHistory: [Double] = []
    var netHistory: [Double] = []   // total net rate (rx+tx) bytes/sec

    /// Sort key for the Network column: total live throughput.
    var netSortKey: Double { (netRxRate ?? 0) + (netTxRate ?? 0) }
}

// MARK: - Parsing helpers for Docker's stringly-typed stats output.

enum Parse {
    /// "11.26%" -> 11.26
    static func percent(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// "70.88MiB" / "3.66GB" / "0B" / "1.02GB" -> bytes
    static func size(_ raw: String) -> UInt64 {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return 0 }
        let number = s.prefix { $0.isNumber || $0 == "." }
        let unit = s.dropFirst(number.count)
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let v = Double(number) else { return 0 }
        let mult: Double
        switch unit {
        case "b", "": mult = 1
        case "kb": mult = 1_000
        case "mb": mult = 1_000_000
        case "gb": mult = 1_000_000_000
        case "tb": mult = 1_000_000_000_000
        case "kib": mult = 1024
        case "mib": mult = 1024 * 1024
        case "gib": mult = 1024 * 1024 * 1024
        case "tib": mult = 1024 * 1024 * 1024 * 1024
        default: mult = 1
        }
        return UInt64(v * mult)
    }

    /// "24.1MB / 20.5MB" -> (24_100_000, 20_500_000)
    static func pair(_ s: String) -> (UInt64, UInt64) {
        let parts = s.components(separatedBy: "/")
        guard parts.count == 2 else { return (0, 0) }
        return (size(parts[0]), size(parts[1]))
    }
}

extension UInt64 {
    var humanBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary)
    }
}

/// bytes/sec -> "12.3 KB/s" (blank-ish when effectively idle).
func rateString(_ bytesPerSec: Double?) -> String {
    guard let r = bytesPerSec, r >= 1 else { return "0 B/s" }
    let s = ByteCountFormatter.string(
        fromByteCount: Int64(r), countStyle: .binary)
    return "\(s)/s"
}
