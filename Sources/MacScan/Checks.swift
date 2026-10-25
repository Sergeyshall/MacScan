import Foundation

// MARK: - Helpers

private func sh(_ command: String, timeout: TimeInterval = 60) async -> String {
    await Shell.run(command, timeout: timeout).out
}

private func lines(_ s: String) -> [String] {
    s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func match(_ pattern: String, in s: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[range])
}

private func allMatches(_ pattern: String, in s: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
        Range($0.range(at: 1), in: s).map { String(s[$0]) }
    }
}

private func bytes(kb: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file)
}

/// Total size in KB of the paths (globs and ~ allowed). 0 when nothing matches.
private func sizeKB(_ paths: String) async -> Int64 {
    Int64(await sh("set -- \(paths); (( $# )) && du -skc \"$@\" 2>/dev/null | tail -1 | cut -f1", timeout: 300)) ?? 0
}

/// Single-quotes a path for the shell.
private func quote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Replaces the home folder with ~ so reports never contain the user name.
private func tilde(_ s: String) -> String {
    s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

private func bullets(_ items: [String], limit: Int = 12) -> String {
    let shown = items.prefix(limit).map { "• " + $0 }
    let more = items.count > limit ? ["• …and \(items.count - limit) more"] : []
    return (shown + more).joined(separator: "\n")
}

private enum Pane {
    /// macOS 13+ System Settings pane, or the macOS 12 System Preferences equivalent.
    static func open(_ id: String, legacy: String) -> FixAction {
        let modern = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))
        return .open("x-apple.systempreferences:\(modern ? id : legacy)")
    }
    static let privacy = open("com.apple.settings.PrivacySecurity.extension", legacy: "com.apple.preference.security")
    static let timeMachine = open("com.apple.Time-Machine-Settings.extension", legacy: "com.apple.prefs.backup")
    static let softwareUpdate = open("com.apple.Software-Update-Settings.extension", legacy: "com.apple.preferences.softwareupdate")
    static let lockScreen = open("com.apple.Lock-Screen-Settings.extension", legacy: "com.apple.preference.security?General")
    static let users = open("com.apple.Users-Groups-Settings.extension", legacy: "com.apple.preferences.users")
    static let sharing = open("com.apple.Sharing-Settings.extension", legacy: "com.apple.preferences.sharing")
    static let loginItems = open("com.apple.LoginItems-Settings.extension", legacy: "com.apple.preferences.users")
    static let airDrop = open("com.apple.AirDrop-Handoff-Settings.extension", legacy: "com.apple.preference.general")
}

private let socketfilterfw = "/usr/libexec/ApplicationFirewall/socketfilterfw"

// MARK: - Checks

enum Checks {
    static let all: [Check] = security + performance + disk + apps

    // MARK: Security

    static let security: [Check] = [
        Check("sip", .security) {
            let out = await sh("csrutil status")
            let on = out.contains("status: enabled")
            return [Finding("System Integrity Protection", on ? .ok : .critical,
                            on ? "Enabled" : "\(out)\nRe-enable it from Recovery mode: `csrutil enable`.")]
        },

        Check("gatekeeper", .security) {
            let on = await sh("spctl --status").contains("assessments enabled")
            return [on
                ? Finding("Gatekeeper", .ok, "Enabled: apps must be signed and notarized")
                : Finding("Gatekeeper", .critical, "Disabled: unsigned apps run without any check",
                          fix: Fix("Open Settings", Pane.privacy))]
        },

        Check("filevault", .security) {
            let on = await sh("fdesetup status").contains("FileVault is On")
            return [on
                ? Finding("FileVault disk encryption", .ok, "On")
                : Finding("FileVault disk encryption", .critical,
                          "Off: anyone with physical access to this Mac can read the disk",
                          fix: Fix("Open Settings", Pane.privacy))]
        },

        Check("firewall", .security) {
            let out = await sh("\(socketfilterfw) --getglobalstate").lowercased()
            let off = out.contains("state = 0") || out.contains("disabled")
            return [off
                ? Finding("Firewall", .medium, "Off: services listening on this Mac are reachable by anyone on the same network",
                          fix: Fix("Turn On", .admin("\(socketfilterfw) --setglobalstate on")))
                : Finding("Firewall", .ok, "On")]
        },

        Check("stealth", .security) {
            let out = await sh("\(socketfilterfw) --getstealthmode").lowercased()
            let off = out.contains("off") || out.contains("disabled")
            return [off
                ? Finding("Firewall stealth mode", .low, "Off: this Mac answers pings and port probes",
                          fix: Fix("Turn On", .admin("\(socketfilterfw) --setstealthmode on")))
                : Finding("Firewall stealth mode", .ok, "On")]
        },

        Check("backup", .security) {
            let dest = await sh("tmutil destinationinfo")
            if dest.isEmpty || dest.contains("No destinations") {
                return [Finding("Backups (Time Machine)", .critical,
                                "No backup destination. A disk failure, theft or ransomware would lose all data.",
                                fix: Fix("Set Up Time Machine", Pane.timeMachine))]
            }
            let latest = await sh("tmutil latestbackup 2>/dev/null")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            guard let day = match(#"(\d{4}-\d{2}-\d{2})-\d{6}"#, in: latest), let date = formatter.date(from: day) else {
                return [Finding("Backups (Time Machine)", .ok,
                                "Destination configured (give MacScan Full Disk Access to see the last backup date)")]
            }
            let days = Int(Date().timeIntervalSince(date) / 86_400)
            return [days > 7
                ? Finding("Backups (Time Machine)", .medium, "Last backup was \(days) days ago (\(day))",
                          fix: Fix("Open Time Machine", Pane.timeMachine))
                : Finding("Backups (Time Machine)", .ok, "Last backup: \(day)")]
        },

        Check("updates.auto", .security) {
            let prefs = "/Library/Preferences/com.apple.SoftwareUpdate"
            let macos = await sh("defaults read \(prefs) AutomaticallyInstallMacOSUpdates 2>/dev/null")
            let critical = await sh("defaults read \(prefs) CriticalUpdateInstall 2>/dev/null")
            var off: [String] = []
            if macos == "0" { off.append("macOS updates") }
            if critical == "0" { off.append("security responses & system files") }
            return [off.isEmpty
                ? Finding("Automatic updates", .ok, "Security updates install automatically")
                : Finding("Automatic updates", .low, "Not installed automatically: " + off.joined(separator: ", "),
                          fix: Fix("Open Settings", Pane.softwareUpdate))]
        },

        Check("autologin", .security) {
            let user = await sh("defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null")
            return [user.isEmpty
                ? Finding("Automatic login", .ok, "Off")
                : Finding("Automatic login", .medium, "On: the Mac logs in without a password at startup",
                          fix: Fix("Open Settings", Pane.users))]
        },

        Check("screenlock", .security) {
            let out = await sh("sysadminctl -screenLock status 2>&1")
            if out.contains("is off") {
                return [Finding("Password after sleep / screen saver", .medium, "Not required",
                                fix: Fix("Open Settings", Pane.lockScreen))]
            }
            if let seconds = match(#"delay is (\d+) seconds"#, in: out).flatMap(Int.init), seconds > 60 {
                return [Finding("Password after sleep / screen saver", .low,
                                "Required only after \(seconds / 60) min. Set it to Immediately.",
                                fix: Fix("Open Settings", Pane.lockScreen))]
            }
            if out.contains("immediate") || match(#"delay is (\d+) seconds"#, in: out) != nil {
                return [Finding("Password after sleep / screen saver", .ok, "Required immediately")]
            }
            return [Finding("Password after sleep / screen saver", .info, "Couldn't read the setting on this macOS version",
                            fix: Fix("Open Settings", Pane.lockScreen))]
        },

        Check("listeners", .security) {
            // User processes listening on all interfaces (not just 127.0.0.1).
            let out = await sh(#"lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $9 ~ /^\*:/ {print $1, substr($9, 3)}' | sort -u"#)
            var ollama = false, airplay = false
            var others: [String] = []
            for line in lines(out) {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count == 2 else { continue }
                let (process, port) = (parts[0].replacingOccurrences(of: "\\x20", with: " "), parts[1])
                if process.lowercased().hasPrefix("ollama") { ollama = true }
                else if process.hasPrefix("ControlCe") { airplay = true }
                else if ["rapportd", "sharingd", "identitys"].contains(process) { continue }   // Apple Continuity
                else { others.append("\(process) on port \(port)") }
            }
            var results: [Finding] = []
            if ollama {
                results.append(Finding("Ollama API open to the network", .medium,
                    "Ollama listens on all interfaces without authentication: anyone on your Wi-Fi can use, download or delete models. The fix makes it listen on 127.0.0.1 only (persists across reboots) and restarts Ollama. If it is still exposed afterwards, turn off \"Expose Ollama to the network\" in Ollama's settings.",
                    fix: Fix("Restrict to Localhost", .shell(ollamaLocalhostFix))))
            }
            if airplay {
                results.append(Finding("AirPlay Receiver", .low,
                    "Listening on ports 5000/7000. Turn it off if you don't stream to this Mac.",
                    fix: Fix("Turn Off", .shell("defaults -currentHost write com.apple.controlcenter AirplayRecieverEnabled -bool false && killall ControlCenter; sleep 2"))))
            }
            if !others.isEmpty {
                results.append(Finding("Apps reachable from the network", .low,
                    "These apps accept connections from other devices. Fine if intended; otherwise the firewall blocks them.\n" + bullets(others)))
            }
            if results.isEmpty {
                results.append(Finding("Apps reachable from the network", .ok, "No apps listen on external interfaces"))
            }
            return results
        },

        Check("sharing", .security) {
            let out = await sh(#"netstat -an -p tcp | awk '$NF=="LISTEN" {print $4}' | sort -u"#)
            let open = Set(lines(out))
            let services = [("22", "Remote Login (SSH)"), ("5900", "Screen Sharing"),
                            ("445", "File Sharing (SMB)"), ("3283", "Remote Management")]
            let on = services.filter { open.contains("*.\($0.0)") }.map(\.1)
            return [on.isEmpty
                ? Finding("Sharing services", .ok, "Remote Login, Screen Sharing and File Sharing are off")
                : Finding("Sharing services", .low, "On: " + on.joined(separator: ", ") + ". Turn off any you don't use.",
                          fix: Fix("Open Sharing", Pane.sharing))]
        },

        Check("plist.secrets", .security) {
            // Launch items whose plist embeds a token/password and that every account can read.
            let out = await sh(#"""
                for f in /Library/LaunchDaemons/*.plist /Library/LaunchAgents/*.plist ~/Library/LaunchAgents/*.plist; do
                  [[ -r $f ]] || continue
                  grep -qiE 'token|password|secret|api[_-]?key' "$f" 2>/dev/null || continue
                  perms=$(stat -f '%Lp' "$f")
                  [[ ${perms: -1} == [4567] ]] && echo "$f"
                done
                """#)
            let files = lines(out)
            guard !files.isEmpty else {
                return [Finding("Secrets in startup items", .ok, "No world-readable launch items with embedded tokens")]
            }
            // Per-user agents in /Library/LaunchAgents may stop loading if made root-only, so they are reported but not changed.
            let fixable = files.filter { !$0.hasPrefix("/Library/LaunchAgents/") }
            let command = "chmod 600 " + fixable.map(quote).joined(separator: " ")
            let needsRoot = fixable.contains { $0.hasPrefix("/Library/") }
            return [Finding("Secrets in startup items", .medium,
                "These launch items contain what looks like a token or password and are readable by every account on this Mac. Restrict them, and consider rotating the secret.\n" + bullets(files.map(tilde)),
                fix: fixable.isEmpty ? nil : Fix("Restrict Permissions", needsRoot ? .admin(command) : .shell(command)))]
        },

        Check("ssh", .security) {
            let out = await sh(#"""
                [[ -d ~/.ssh ]] || exit 0
                echo "dir $(stat -f '%Lp' ~/.ssh)"
                for k in ~/.ssh/id_*; do
                  [[ $k == *.pub ]] && continue
                  pass=yes; ssh-keygen -y -P '' -f "$k" >/dev/null 2>&1 && pass=no
                  echo "key $(stat -f '%Lp' "$k") $pass $k"
                done
                """#)
            guard !out.isEmpty else { return [Finding("SSH keys", .ok, "No ~/.ssh folder")] }
            var results: [Finding] = []
            var badPerms: [String] = []
            var noPass: [String] = []
            for line in lines(out) {
                let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
                if parts.first == "dir", parts.count > 1, parts[1] != "700" { badPerms.append("~/.ssh (\(parts[1]))") }
                if parts.first == "key", parts.count == 4 {
                    if parts[1] != "600" && parts[1] != "400" { badPerms.append("\(tilde(parts[3])) (\(parts[1]))") }
                    if parts[2] == "no" { noPass.append(tilde(parts[3])) }
                }
            }
            if !badPerms.isEmpty {
                results.append(Finding("SSH permissions", .medium, "Too open:\n" + bullets(badPerms),
                    fix: Fix("Fix Permissions", .shell(#"chmod 700 ~/.ssh; for k in ~/.ssh/id_*; do [[ $k == *.pub ]] || chmod 600 "$k"; done"#))))
            }
            if !noPass.isEmpty {
                results.append(Finding("SSH keys without passphrase", .low,
                    "Anyone who copies these files can use them. Add a passphrase in Terminal with `ssh-keygen -p -f <key>`.\n" + bullets(noPass)))
            }
            if results.isEmpty { results.append(Finding("SSH keys", .ok, "Permissions are correct and keys have passphrases")) }
            return results
        },

        Check("env.files", .security) {
            let out = await sh("find ~/Downloads ~/Desktop -maxdepth 5 \\( -name node_modules -prune \\) -o -name '.env*' -type f -print 2>/dev/null | head -50")
            let files = lines(out).map(tilde)
            return [files.isEmpty
                ? Finding("Secrets in Downloads / Desktop", .ok, "No .env files")
                : Finding("Secrets in Downloads / Desktop", .low,
                          "\(files.count) .env file(s), which usually hold API keys, in folders that are often synced or shared. Delete stray copies.\n" + bullets(files))]
        },

        Check("mdm", .security) {
            let out = await sh("profiles status -type enrollment 2>&1")
            return [out.contains("MDM enrollment: Yes")
                ? Finding("Device management (MDM)", .info, "This Mac is managed by an organization, which can install profiles and apps")
                : Finding("Device management (MDM)", .ok, "Not enrolled")]
        },
    ]

    // MARK: Performance

    static let performance: [Check] = [
        Check("memory", .performance) {
            let free = await sh("memory_pressure -Q 2>/dev/null")
            let swap = await sh("sysctl -n vm.swapusage")
            var results: [Finding] = []
            if let pct = match(#"(\d+)%"#, in: free).flatMap(Int.init) {
                let sev: Severity = pct < 15 ? .medium : pct < 30 ? .low : .ok
                results.append(Finding("Memory", sev, "\(pct)% free" + (sev == .ok ? "" : ". Quit apps you aren't using.")))
            }
            if let used = match(#"used = ([\d.]+)M"#, in: swap).flatMap(Double.init) {
                let gb = used / 1024
                let sev: Severity = gb > 8 ? .medium : gb > 2 ? .low : .ok
                results.append(Finding("Swap", sev, String(format: "%.1f GB used", gb) + (sev == .ok ? "" : ". The Mac is short on RAM for this workload.")))
            }
            return results
        },

        Check("cpu", .performance) {
            let load = await sh("sysctl -n vm.loadavg")
            let cores = Double(await sh("sysctl -n hw.ncpu")) ?? 8
            let top = await sh("ps -Ao pcpu=,comm= -r | head -5")
            let averages = load.split(separator: " ").compactMap { Double($0) }
            guard averages.count >= 2 else { return [] }
            let ratio = averages[1] / cores
            let sev: Severity = ratio > 1 ? .medium : ratio > 0.7 ? .low : .ok
            let procs = lines(top).map { line -> String in
                let parts = line.split(separator: " ", maxSplits: 1)
                let name = parts.count > 1 ? (String(parts[1]) as NSString).lastPathComponent : line
                return "\(name) \(parts.first ?? "")%"
            }
            var detail = String(format: "Load %.1f / %.0f cores (5-min avg). Top: ", averages[1], cores) + procs.joined(separator: ", ")
            if top.contains("mds_stores") { detail += "\nSpotlight is indexing; this settles on its own." }
            return [Finding("CPU load", sev, detail)]
        },

        Check("processes", .performance) {
            let count = Int(await sh("ps -A -o pid= | wc -l").trimmingCharacters(in: .whitespaces)) ?? 0
            let ides = lines(await sh(#"ps -Ao comm= | grep -oE '/Applications/(Visual Studio Code|Cursor|Antigravity|Windsurf|Zed|Xcode|IntelliJ IDEA[^/]*|PyCharm[^/]*|WebStorm[^/]*|Android Studio)\.app' | sort -u"#))
                .map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
            var results = [Finding("Running processes", count > 800 ? .low : .ok, "\(count) processes")]
            if ides.count >= 2 {
                results.append(Finding("Several IDEs open", .low,
                    "\(ides.joined(separator: ", ")) are running together; each uses 1–3 GB of RAM plus indexers."))
            }
            return results
        },

        Check("thermal", .performance) {
            let out = await sh("pmset -g therm")
            let calm = out.contains("No thermal warning") && out.contains("No performance warning")
            let limit = match(#"CPU_Speed_Limit\s*=\s*(\d+)"#, in: out).flatMap(Int.init)
            if calm || (limit ?? 100) >= 100 { return [Finding("Thermal throttling", .ok, "None")] }
            return [Finding("Thermal throttling", .medium, "The CPU is being slowed down by heat.\n" + out)]
        },

        Check("sleep", .performance) {
            let out = await sh("pmset -g assertions")
            let blockers = Set(allMatches(#"pid \d+\(([^)]+)\):.*PreventUserIdleSystemSleep"#, in: out)).subtracting(["powerd"]).sorted()
            return [blockers.isEmpty
                ? Finding("Sleep blockers", .ok, "Nothing keeps the Mac awake")
                : Finding("Sleep blockers", .low, "Keeping the Mac awake: " + blockers.joined(separator: ", "))]
        },

        Check("uptime", .performance) {
            guard let boot = match(#"sec = (\d+)"#, in: await sh("sysctl -n kern.boottime")).flatMap(Double.init) else { return [] }
            let days = Int(Date().timeIntervalSince1970 - boot) / 86_400
            return [days > 14
                ? Finding("Uptime", .low, "\(days) days since restart. Restart to apply updates and clear leaks.")
                : Finding("Uptime", .ok, days == 0 ? "Restarted today" : "\(days) day(s)")]
        },

        Check("battery", .performance) {
            let out = await sh("system_profiler SPPowerDataType")
            guard let cycles = match(#"Cycle Count: (\d+)"#, in: out) else { return [] }   // desktop Mac
            let condition = match(#"Condition: (.+)"#, in: out) ?? "Unknown"
            let capacity = match(#"Maximum Capacity: (\d+)%"#, in: out).flatMap(Int.init)
            let sev: Severity = condition != "Normal" ? .medium : (capacity ?? 100) < 80 ? .low : .ok
            let cap = capacity.map { "\($0)% capacity, " } ?? ""
            return [Finding("Battery", sev, "\(cap)\(cycles) cycles, condition \(condition)")]
        },
    ]

    // MARK: Disk

    private struct Cache {
        let id: String
        let name: String
        let paths: String
        let clean: String
        var batchable = true
    }

    private static let caches: [Cache] = [
        Cache(id: "trash", name: "Trash", paths: "~/.Trash", clean: #"osascript -e 'tell application "Finder" to empty trash'"#, batchable: false),
        Cache(id: "nvm", name: "nvm download cache", paths: "~/.nvm/.cache", clean: "rm -rf ~/.nvm/.cache"),
        Cache(id: "npm", name: "npm cache", paths: "~/.npm/_cacache", clean: "rm -rf ~/.npm/_cacache"),
        Cache(id: "yarn", name: "Yarn cache", paths: "~/Library/Caches/Yarn", clean: "rm -rf ~/Library/Caches/Yarn"),
        Cache(id: "pnpm", name: "pnpm store", paths: "~/Library/pnpm/store", clean: "command -v pnpm >/dev/null && pnpm store prune || rm -rf ~/Library/pnpm/store"),
        Cache(id: "uv", name: "uv cache", paths: "~/.cache/uv", clean: "command -v uv >/dev/null && uv cache clean || rm -rf ~/.cache/uv"),
        Cache(id: "pip", name: "pip cache", paths: "~/Library/Caches/pip", clean: "rm -rf ~/Library/Caches/pip"),
        Cache(id: "brew", name: "Homebrew downloads", paths: "~/Library/Caches/Homebrew", clean: "command -v brew >/dev/null && brew cleanup --prune=all; rm -rf ~/Library/Caches/Homebrew/downloads"),
        Cache(id: "shipit", name: "App updater leftovers (ShipIt)", paths: "~/Library/Caches/*.ShipIt", clean: "rm -rf ~/Library/Caches/*.ShipIt"),
        Cache(id: "playwright", name: "Playwright browsers", paths: "~/Library/Caches/ms-playwright", clean: "rm -rf ~/Library/Caches/ms-playwright"),
        Cache(id: "gradle", name: "Gradle caches", paths: "~/.gradle/caches", clean: "rm -rf ~/.gradle/caches"),
        Cache(id: "cocoapods", name: "CocoaPods cache", paths: "~/Library/Caches/CocoaPods", clean: "rm -rf ~/Library/Caches/CocoaPods"),
        Cache(id: "derived", name: "Xcode DerivedData", paths: "~/Library/Developer/Xcode/DerivedData", clean: "rm -rf ~/Library/Developer/Xcode/DerivedData"),
        Cache(id: "simulators", name: "Unavailable iOS simulators", paths: "~/Library/Developer/CoreSimulator/Devices", clean: "xcrun simctl delete unavailable"),
    ]

    private struct ModelStore {
        let id: String
        let name: String
        let paths: String
        let app: String?
    }

    private static let modelStores: [ModelStore] = [
        ModelStore(id: "lmstudio", name: "LM Studio models", paths: "~/.cache/lm-studio/models ~/.lmstudio/models", app: "LM Studio"),
        ModelStore(id: "ollama", name: "Ollama models", paths: "~/.ollama/models", app: nil),
        ModelStore(id: "hf", name: "Hugging Face cache", paths: "~/.cache/huggingface", app: nil),
        ModelStore(id: "whisper", name: "Whisper models", paths: "~/.cache/whisper", app: nil),
        ModelStore(id: "diffusionbee", name: "DiffusionBee models", paths: "~/.diffusionbee", app: "DiffusionBee"),
        ModelStore(id: "comfy", name: "ComfyUI models", paths: "~/ComfyUI/models ~/Documents/ComfyUI/models", app: nil),
    ]

    static let disk: [Check] = [
        Check("disk.free", .disk) {
            let out = await sh("df -k /System/Volumes/Data 2>/dev/null || df -k /")
            let fields = lines(out).last?.split(separator: " ").compactMap { Int64($0) } ?? []
            guard fields.count >= 3 else { return [] }
            let (total, used, free) = (fields[0], fields[1], fields[2])
            let pct = Int(Double(used) / Double(total) * 100)
            let sev: Severity = pct > 90 ? .critical : pct > 80 ? .medium : pct > 70 ? .low : .ok
            return [Finding("Free space", sev, "\(bytes(kb: free)) free of \(bytes(kb: total)) (\(pct)% used)"
                            + (sev == .ok ? "" : ". macOS slows down and updates fail when the disk is nearly full."))]
        },

        Check("disk.smart", .disk) {
            let status = match(#"SMART Status:\s+(.+)"#, in: await sh("diskutil info disk0")) ?? "Unknown"
            let sev: Severity = status.contains("Verified") ? .ok : status.contains("Fail") ? .critical : .info
            return [Finding("SSD health (SMART)", sev, sev == .critical ? "\(status). Back up now and get the drive replaced." : status)]
        },

        Check("downloads.old", .disk) {
            let count = Int(await sh("find ~/Downloads -mindepth 1 -maxdepth 1 -mtime +180 2>/dev/null | wc -l").trimmingCharacters(in: .whitespaces)) ?? 0
            let size = await sizeKB("~/Downloads")
            return [count > 50
                ? Finding("Old downloads", .low, "\(count) items older than 6 months (Downloads total \(bytes(kb: size)))",
                          fix: Fix("Open Downloads", .shell("open ~/Downloads"), batchable: false))
                : Finding("Old downloads", .ok, "Downloads: \(bytes(kb: size))")]
        },

        Check("node.versions", .disk) {
            let versions = lines(await sh("ls ~/.nvm/versions/node 2>/dev/null"))
            // Node.js release lines still receiving security fixes (update as new LTS lines ship).
            let supported: Set<Int> = [22, 24, 26]
            let eol = versions.filter { v in
                guard let major = Int(v.dropFirst().split(separator: ".").first ?? "") else { return false }
                return !supported.contains(major)
            }
            guard !eol.isEmpty else { return versions.isEmpty ? [] : [Finding("Node.js versions (nvm)", .ok, versions.joined(separator: ", "))] }
            let uninstall = "source ~/.nvm/nvm.sh && nvm deactivate >/dev/null; " + eol.map { "nvm uninstall \($0)" }.joined(separator: " && ")
            return [Finding("End-of-life Node.js versions", .low,
                "\(eol.joined(separator: ", ")) no longer get security fixes. Remove them unless a project still needs them.",
                fix: Fix("Uninstall", .shell(uninstall), batchable: false))]
        },
    ]
    + caches.map { cache in
        Check("cache.\(cache.id)", .disk) {
            let kb = await sizeKB(cache.paths)
            guard kb > 500 * 1024 else { return [] }    // only report > 500 MB
            return [Finding(cache.name, .low, "\(bytes(kb: kb)) can be freed. It is rebuilt automatically when needed.",
                            fix: Fix("Clean", .shell(cache.clean), batchable: cache.batchable))]
        }
    }
    + modelStores.map { store in
        Check("models.\(store.id)", .disk) {
            let kb = await sizeKB(store.paths)
            guard kb > 2 * 1024 * 1024 else { return [] }   // only report > 2 GB
            let biggest = lines(await sh(#"set -- \#(store.paths); (( $# )) && find "$@" -type f -size +500M -exec du -k {} + 2>/dev/null | sort -rn | head -8"#))
                .compactMap { line -> String? in
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    guard parts.count == 2, let size = Int64(parts[0]) else { return nil }
                    let path = String(parts[1])
                    // Hugging Face stores blobs by hash; show the repo name instead.
                    let name = match(#"models--([^/]+)"#, in: path)?.replacingOccurrences(of: "--", with: "/")
                        ?? (path as NSString).lastPathComponent
                    return "\(name) — \(bytes(kb: size))"
                }
            let fix = store.app.map { Fix("Open \($0)", .shell("open -a \(quote($0))"), batchable: false) }
            return [Finding(store.name, kb > 30 * 1024 * 1024 ? .low : .info,
                            "\(bytes(kb: kb)). Remove models you no longer use.\n" + bullets(biggest), fix: fix)]
        }
    }

    // MARK: Apps

    private static let discontinued: [(app: String, severity: Severity, why: String)] = [
        ("Visual Studio", .medium, "Retired by Microsoft in Aug 2024; no more security updates. Use VS Code or Rider."),
        ("Android File Transfer", .low, "Abandoned by Google and Intel-only. Use OpenMTP or MacDroid."),
        ("Adobe Flash Player", .critical, "Discontinued in 2020 and a common malware vector."),
        ("Microsoft Silverlight", .medium, "Discontinued in 2021."),
        ("Java for OS X", .medium, "Apple's Java 6 is long unsupported."),
    ]

    static let apps: [Check] = [
        Check("macos.updates", .apps) {
            let out = await sh("softwareupdate -l 2>&1", timeout: 180)
            if out.contains("No new software available") { return [Finding("macOS updates", .ok, "Up to date")] }
            let labels = allMatches(#"Title: ([^,]+)"#, in: out)
            guard !labels.isEmpty else { return [Finding("macOS updates", .info, "Couldn't check for updates")] }
            return [Finding("macOS updates", .medium, "Available:\n" + bullets(labels), fix: Fix("Open Software Update", Pane.softwareUpdate))]
        },

        Check("brew", .apps) {
            guard !(await sh("command -v brew")).isEmpty else { return [] }
            let outdated = lines(await sh("brew outdated --quiet 2>/dev/null", timeout: 120))
            return [outdated.isEmpty
                ? Finding("Homebrew packages", .ok, "All up to date")
                : Finding("Homebrew packages", .low, "\(outdated.count) outdated: " + outdated.prefix(15).joined(separator: ", "),
                          fix: Fix("Upgrade All", .shell("brew update && brew upgrade")))]
        },

        Check("apps.intel", .apps) {
            guard await sh("sysctl -n hw.optional.arm64 2>/dev/null") == "1" else { return [] }   // Intel Mac
            let out = await sh(#"""
                for app in /Applications/*.app /Applications/*/*.app ~/Applications/*.app; do
                  exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null) || continue
                  archs=$(lipo -archs "$app/Contents/MacOS/$exe" 2>/dev/null) || continue
                  [[ $archs == *arm64* ]] || echo "${app:t:r}"
                done
                """#, timeout: 120)
            let apps = lines(out)
            return [apps.isEmpty
                ? Finding("Intel-only apps", .ok, "All apps run natively on Apple Silicon")
                : Finding("Intel-only apps", .low,
                          "These run through Rosetta: slower, more battery, and Rosetta is being phased out. Update them or find native alternatives.\n" + bullets(apps))]
        },

        Check("apps.discontinued", .apps) {
            let fm = FileManager.default
            let found = discontinued.filter { fm.fileExists(atPath: "/Applications/\($0.app).app") }
            guard !found.isEmpty else { return [Finding("Discontinued apps", .ok, "None found")] }
            return found.map { item in
                Finding("\(item.app) (discontinued)", item.severity, item.why,
                        fix: Fix("Move to Trash", .shell(#"osascript -e 'tell application "Finder" to delete (POSIX file "/Applications/\#(item.app).app" as alias)'"#), batchable: false))
            }
        },

        Check("startup", .apps) {
            let out = await sh("ls /Library/LaunchDaemons /Library/LaunchAgents ~/Library/LaunchAgents 2>/dev/null | grep '\\.plist$' | grep -v '^com\\.apple\\.' | sed 's/\\.plist$//' | sort -u")
            let items = lines(out)
            return [Finding("Background startup items", items.count > 10 ? .low : items.isEmpty ? .ok : .info,
                            items.isEmpty ? "None" : "\(items.count) third-party launch agents/daemons. Disable the ones you don't need.\n" + bullets(items, limit: 20),
                            fix: items.isEmpty ? nil : Fix("Open Login Items", Pane.loginItems))]
        },

        Check("sysext", .apps) {
            // Rows look like: *  *  TEAMID  bundle.id (1.0/1)  Display Name  [activated enabled]
            let rows = lines(await sh("systemextensionsctl list 2>/dev/null | grep 'activated enabled'")).map {
                $0.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let names = rows.compactMap { fields -> String? in
                guard let i = fields.firstIndex(where: { $0.hasPrefix("[activated") }), i > 0 else { return nil }
                return fields[i - 1]
            }
            guard !names.isEmpty else { return [Finding("System extensions", .ok, "None")] }
            let network = names.filter { n in ["network", "vpn", "tunnel", "proxy"].contains { n.lowercased().contains($0) } }
            return [Finding("System extensions", network.count > 1 ? .low : .info,
                            (network.count > 1 ? "Several network/VPN extensions are active; they can conflict over DNS and routing.\n" : "")
                            + bullets(names),
                            fix: Fix("Open Login Items & Extensions", Pane.loginItems))]
        },
    ]
}

/// Makes Ollama listen on 127.0.0.1 now and after every login, then restarts it.
private let ollamaLocalhostFix = #"""
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/local.ollama-localhost.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.ollama-localhost</string>
  <key>ProgramArguments</key><array><string>/bin/launchctl</string><string>setenv</string><string>OLLAMA_HOST</string><string>127.0.0.1:11434</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl setenv OLLAMA_HOST 127.0.0.1:11434
osascript -e 'quit app "Ollama"' 2>/dev/null; sleep 3
pkill -f 'ollama serve' 2>/dev/null; sleep 1
open -a Ollama 2>/dev/null; sleep 5
true
"""#
