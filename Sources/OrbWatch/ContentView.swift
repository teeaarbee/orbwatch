import SwiftUI

enum MainTab: String, CaseIterable { case live = "Live", history = "History" }

struct ContentView: View {
    @StateObject private var monitor = Monitor()
    @State private var selection: Workload.ID?
    @State private var sortOrder: [KeyPathComparator<Workload>] = []
    @State private var tab: MainTab = .live

    private var rows: [Workload] {
        sortOrder.isEmpty ? monitor.workloads
                          : monitor.workloads.sorted(using: sortOrder)
    }

    private var selected: Workload? {
        monitor.workloads.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar(monitor: monitor)
            Divider()
            Picker("", selection: $tab) {
                ForEach(MainTab.allCases, id: \.self) { t in
                    Text(t == .history
                         ? "History (\(monitor.pastWorkloads.count))"
                         : t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 7)

            Divider()
            if tab == .live {
                table
                if let w = selected {
                    Divider()
                    DetailPane(workload: w)
                }
            } else {
                HistoryView(monitor: monitor)
            }
        }
        .frame(minWidth: 860, minHeight: 480)
        .toolbar { toolbarContent }
        .task { await monitor.runLoop() }
    }

    // MARK: Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Workload", value: \.name) { w in
                HStack(spacing: 8) {
                    Image(systemName: w.kind.symbol)
                        .foregroundStyle(w.kind == .docker ? .blue : .purple)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.name).fontWeight(.medium)
                        if let sub = w.image ?? w.detail {
                            Text(sub).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .width(min: 200, ideal: 240)

            TableColumn("State", value: \.state.sortRank) { w in
                HStack(spacing: 6) {
                    Circle().fill(w.state.color).frame(width: 8, height: 8)
                    Text(w.statusText).font(.caption).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 130, ideal: 160)

            TableColumn("CPU", value: \.cpuPercent) { w in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f%%", w.cpuPercent))
                        .font(.system(.body, design: .rounded))
                        .monospacedDigit()
                    MeterBar(fraction: min(w.cpuPercent / 100, 1),
                             tint: cpuTint(w.cpuPercent))
                }
            }
            .width(min: 70, ideal: 84)

            TableColumn("Trend") { w in
                Sparkline(values: w.cpuHistory, tint: cpuTint(w.cpuPercent))
                    .frame(height: 24)
            }
            .width(min: 70, ideal: 100)

            TableColumn("Memory", value: \.memBytes) { w in
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.memBytes.humanBytes).monospacedDigit()
                    if let limit = w.memLimitBytes {
                        Text("of \(limit.humanBytes)").font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let p = w.memPercent {
                        Text(String(format: "%.1f%% sys", p)).font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Network", value: \.netSortKey) { w in
                if w.netRx != nil {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("↓ \(rateString(w.netRxRate))")
                            .font(.caption).monospacedDigit()
                        Text("↑ \(rateString(w.netTxRate))")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 92, ideal: 112)

            TableColumn("Net trend") { w in
                Sparkline(values: w.netHistory, tint: .teal)
                    .frame(height: 24)
            }
            .width(min: 64, ideal: 90)

            TableColumn("Uptime") { w in
                Text(w.uptime ?? "—").font(.caption)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")

            Button { monitor.paused.toggle() } label: {
                Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
            }
            .help(monitor.paused ? "Resume live updates" : "Pause live updates")

            Menu {
                Picker("Refresh every", selection: $monitor.intervalSeconds) {
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("5s").tag(5.0)
                    Text("10s").tag(10.0)
                }
                Divider()
                Picker("Source", selection: $monitor.connection) {
                    Text("This Mac (local)").tag(Monitor.Connection.local)
                    Text("SSH host").tag(Monitor.Connection.ssh)
                }
                if monitor.connection == .ssh {
                    TextField("host", text: $monitor.sshHost)
                        .onSubmit { monitor.applySSHHost() }
                    Button("Apply host") { monitor.applySSHHost() }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Settings")
        }
    }

    private func cpuTint(_ pct: Double) -> Color {
        switch pct {
        case ..<40: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }
}

/// Top aggregate strip.
struct SummaryBar: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        HStack(spacing: 18) {
            Label("OrbWatch", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)

            stat("\(monitor.runningCount)/\(monitor.totalCount)", "running")
            stat(String(format: "%.1f%%", monitor.totalCPU), "total CPU")
            stat(monitor.totalMem.humanBytes, "total mem")
            stat("↓\(rateString(monitor.totalNetRx)) ↑\(rateString(monitor.totalNetTx))",
                 "network")

            Spacer()

            if let err = monitor.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            if monitor.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Text(monitor.paused ? "paused"
                 : statusLine)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var statusLine: String {
        let src = monitor.connectionLabel
        guard let t = monitor.lastUpdated else { return src }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "\(src) · \(f.localizedString(for: t, relativeTo: Date()))"
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A thin horizontal usage bar.
struct MeterBar: View {
    let fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

/// Bottom inspector for the selected workload.
struct DetailPane: View {
    let workload: Workload

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 28) {
                field("Name", workload.name)
                field("Kind", workload.kind.rawValue)
                field("Status", workload.statusText)
                field("CPU", String(format: "%.1f%%", workload.cpuPercent))
                field("Memory", memText)
                if let p = workload.pids { field("PIDs", "\(p)") }
                if workload.netRx != nil {
                    field("Net rate", "↓ \(rateString(workload.netRxRate))  ↑ \(rateString(workload.netTxRate))")
                }
                if let rx = workload.netRx, let tx = workload.netTx {
                    field("Net total", "↓ \(rx.humanBytes)  ↑ \(tx.humanBytes)")
                }
                if let r = workload.blockRead, let w = workload.blockWrite {
                    field("Block", "r \(r.humanBytes)  w \(w.humanBytes)")
                }
                if let img = workload.image { field("Image", img) }
                if let d = workload.detail { field("Detail", d) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.quaternary.opacity(0.3))
    }

    private var memText: String {
        if let limit = workload.memLimitBytes {
            return "\(workload.memBytes.humanBytes) / \(limit.humanBytes)"
        }
        return workload.memBytes.humanBytes
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

/// Workloads that ran in the past but aren't running now (stopped or removed).
struct HistoryView: View {
    @ObservedObject var monitor: Monitor

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if monitor.pastWorkloads.isEmpty {
                ContentUnavailableView(
                    "Nothing in history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Containers and services that stop or get "
                                      + "removed will appear here while OrbWatch runs."))
            } else {
                Table(monitor.pastWorkloads) {
                    TableColumn("Workload") { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.kind == "Docker"
                                  ? "shippingbox" : "gearshape.2")
                                .foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).fontWeight(.medium)
                                if let img = e.image {
                                    Text(img).font(.caption2)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }.width(min: 200, ideal: 250)

                    TableColumn("Kind") { e in
                        Text(e.kind).font(.caption).foregroundStyle(.secondary)
                    }.width(60)

                    TableColumn("Last status") { e in
                        Text(e.lastStatus).font(.caption).lineLimit(1)
                    }.width(min: 130, ideal: 170)

                    TableColumn("Last running") { e in
                        Text(e.lastRunningAt.map {
                            Self.relative.localizedString(for: $0, relativeTo: .now)
                        } ?? "—").font(.caption).foregroundStyle(.secondary)
                    }.width(min: 90, ideal: 110)

                    TableColumn("Last seen") { e in
                        Text(Self.relative.localizedString(
                            for: e.lastSeen, relativeTo: .now))
                            .font(.caption).foregroundStyle(.secondary)
                    }.width(min: 90, ideal: 110)

                    TableColumn("Seen ×") { e in
                        Text("\(e.seenCount)").font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }.width(54)
                }

                HStack {
                    Text("\(monitor.pastWorkloads.count) not running now")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History", role: .destructive) {
                        monitor.clearHistory()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
    }
}
