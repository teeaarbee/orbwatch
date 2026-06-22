# OrbWatch

A native macOS app that shows a **live view of everything running on maseehurs-imac** —
both OrbStack/Docker containers and native `launchd` services — with their CPU, memory,
network/block I/O, status, and a rolling CPU sparkline per workload.

![overview](docs/placeholder.png)

## What it tracks

- **Docker / OrbStack containers** — merges `docker ps -a` (status, image, uptime, incl.
  stopped containers) with `docker stats` (CPU %, memory used/limit, net I/O, block I/O, PIDs).
- **Native services** — `launchd` jobs whose label starts with `com.besttt.` that have a
  live PID (e.g. the yt-dlp GUI `com.besttt.ytdlp-gui`), with CPU/mem from `ps` and
  per-process network from `nettop` (no sudo).

Everything is colour-coded by state (🟢 running, 🟠 restarting/created, 🟡 paused,
🔴 exited/dead) and updates live every 1–10 s. Click a row for a detail strip
(net rate + totals, block I/O, image, PIDs, full status). Columns are sortable; the header
shows running count, total CPU, total memory, and total network throughput.

### Network

The **Network** column shows live throughput (↓/↑ **per second**), derived from the delta
of the cumulative byte counters between refreshes, with a teal sparkline of total rate.
Counter resets (a restart) read as 0 rather than a spike.

### History tab

A second tab lists workloads that **ran in the past but aren't running now** — stopped
containers *and* ones that were removed entirely — with last status, last-running time, last-
seen time, and how many times they were observed. It's persisted to
`~/Library/Application Support/OrbWatch/history.json`, so it survives restarts. "Clear
History" wipes it.

## Run it

```sh
# quick dev run (opens the window)
swift run

# build a double-clickable app
./build-app.sh            # produces OrbWatch.app
./build-app.sh --install  # also copies it to /Applications

# headless sanity check of the data pipeline (no GUI)
swift run OrbWatch --selftest
```

Requires the Swift toolchain (Command Line Tools is enough) and `docker` on `PATH`.

## Local vs. remote

By default OrbWatch reads Docker and processes **locally** — run it on the iMac and it
sees everything directly. To watch the iMac from another Mac, open the settings menu
(slider icon) → **Source: SSH host**, and enter
`maseehurs-imac.tailc5b5ab.ts.net` (over Tailscale). SSH uses `BatchMode`, so key-based
auth (or Tailscale SSH) must already be set up — it won't prompt for a password.

## Layout

| File | Role |
|------|------|
| `CommandRunner.swift` | Local / SSH command execution abstraction |
| `DockerCollector.swift` | `docker ps` + `docker stats` → merged container rows |
| `ProcessCollector.swift` | `launchctl list` + `ps` → native service rows |
| `Models.swift` | `Workload` model + Docker stat-string / rate parsers |
| `Monitor.swift` | Polling loop, CPU+net history, net rates, aggregates (`ObservableObject`) |
| `History.swift` | Persistent store of past/stopped workloads |
| `ContentView.swift` | Live + History tabs, summary bar, toolbar, detail pane |
| `Sparkline.swift` | Per-row CPU / network trend chart |
| `AppIcon.swift` | Procedural gauge app icon (Dock icon + `.icns` export) |

## Tweaks

- **More native services:** edit `nativePrefixes` in `Monitor.swift` (e.g. add other
  `launchd` label prefixes).
- **Default refresh rate / SSH host:** `intervalSeconds` and `sshHost` in `Monitor.swift`.
