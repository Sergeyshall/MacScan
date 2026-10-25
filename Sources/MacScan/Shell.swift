import AppKit

/// Runs shell commands for checks and fixes.
enum Shell {
    static let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec"

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["LC_ALL"] = "C"                    // stable, English, dot-decimal output
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }()

    /// Runs `command` with zsh as the current user. Unmatched globs expand to nothing.
    static func run(_ command: String, timeout: TimeInterval = 60) async -> (out: String, status: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-f", "-c", "setopt null_glob; " + command]   // -f: skip the user's zsh startup files
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: ("", -1))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (out, process.terminationStatus))
            }
        }
    }

    /// Runs `command` as root via the standard macOS administrator password dialog.
    @MainActor
    static func runAsAdmin(_ command: String) -> (ok: Bool, out: String) {
        let full = "export PATH=\(path); " + command
        let escaped = full
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let result = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return (false, "Cancelled.") }
            return (false, error[NSAppleScript.errorMessage] as? String ?? "The command failed.")
        }
        return (true, result?.stringValue ?? "")
    }
}
