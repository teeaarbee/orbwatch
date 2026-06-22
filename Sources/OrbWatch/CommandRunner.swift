import Foundation

/// Abstracts where shell commands run, so the same collectors work whether the
/// app runs directly on the iMac (LocalRunner) or points at it over Tailscale
/// SSH from another Mac (SSHRunner).
protocol CommandRunner: Sendable {
    /// Runs a command and returns stdout. Throws on a non-zero exit.
    func run(_ command: String) async throws -> String
    /// Human label for the connection, shown in the UI.
    var label: String { get }
}

struct CommandError: LocalizedError {
    let command: String
    let code: Int32
    let stderr: String
    var errorDescription: String? {
        "exit \(code): \(stderr.isEmpty ? command : stderr)"
    }
}

/// Runs commands on the local machine. GUI apps inherit a bare PATH, so we set
/// one that includes the usual Docker / Homebrew locations.
struct LocalRunner: CommandRunner {
    var label: String { "local" }

    private static let path =
        "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    func run(_ command: String) async throws -> String {
        try await Self.exec(
            executable: "/bin/zsh",
            arguments: ["-c", command],
            env: ["PATH": Self.path],
            label: command
        )
    }

    static func exec(
        executable: String,
        arguments: [String],
        env: [String: String],
        label: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                for (k, v) in env { environment[k] = v }
                proc.environment = environment

                let out = Pipe()
                let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                // Drain before waiting to avoid a full-pipe deadlock.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                if proc.terminationStatus != 0 {
                    cont.resume(throwing: CommandError(
                        command: label,
                        code: proc.terminationStatus,
                        stderr: String(decoding: errData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }
                cont.resume(returning: String(decoding: outData, as: UTF8.self))
            }
        }
    }
}

/// Runs commands on a remote host over SSH. Relies on key-based auth being set
/// up (e.g. Tailscale SSH or an installed key) — BatchMode avoids hanging on a
/// password prompt.
struct SSHRunner: CommandRunner {
    let host: String
    var label: String { "ssh \(host)" }

    func run(_ command: String) async throws -> String {
        try await LocalRunner.exec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=6",
                "-o", "StrictHostKeyChecking=accept-new",
                host,
                command,
            ],
            env: ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            label: "ssh \(host): \(command)"
        )
    }
}
