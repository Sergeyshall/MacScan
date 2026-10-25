import Foundation

enum Severity: Int, Comparable, CaseIterable {
    case ok, info, low, medium, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .ok: "OK"
        case .info: "Info"
        case .low: "Low"
        case .medium: "Medium"
        case .critical: "Critical"
        }
    }

    var isIssue: Bool { self >= .low }
}

enum Category: String, CaseIterable, Identifiable {
    case security = "Security"
    case performance = "Performance"
    case disk = "Disk & Storage"
    case apps = "Apps & Startup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .security: "lock.shield"
        case .performance: "speedometer"
        case .disk: "internaldrive"
        case .apps: "square.grid.2x2"
        }
    }
}

enum FixAction {
    case shell(String)   // runs as the current user
    case admin(String)   // runs as root after the macOS password prompt
    case open(String)    // opens a URL, e.g. a System Settings pane

    var command: String {
        switch self {
        case .shell(let c), .admin(let c): c
        case .open(let url): "open \"\(url)\""
        }
    }

    var needsAdmin: Bool {
        if case .admin = self { return true }
        return false
    }

    var isManual: Bool {
        if case .open = self { return true }
        return false
    }
}

struct Fix {
    let label: String
    let action: FixAction
    /// Whether "Fix All" may include it. Off for destructive fixes (deleting apps, runtimes).
    var batchable = true

    init(_ label: String, _ action: FixAction, batchable: Bool = true) {
        self.label = label
        self.action = action
        self.batchable = batchable
    }
}

struct Finding: Identifiable {
    let id = UUID()
    var checkID = ""
    var category = Category.security
    let title: String
    let severity: Severity
    let detail: String
    var fix: Fix?

    init(_ title: String, _ severity: Severity, _ detail: String, fix: Fix? = nil) {
        self.title = title
        self.severity = severity
        self.detail = detail
        self.fix = fix
    }
}

struct Check {
    let id: String
    let category: Category
    let run: () async -> [Finding]

    init(_ id: String, _ category: Category, run: @escaping () async -> [Finding]) {
        self.id = id
        self.category = category
        self.run = run
    }

    func execute() async -> [Finding] {
        await run().map { finding in
            var f = finding
            f.checkID = id
            f.category = category
            return f
        }
    }
}

struct MachineInfo {
    var model = ""
    var chip = ""
    var memory = ""
    var os = ""

    var summary: String {
        [model, chip, memory, os].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func load() async -> MachineInfo {
        let hw = await Shell.run("system_profiler SPHardwareDataType").out
        func field(_ key: String) -> String {
            hw.split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) } ?? ""
        }
        var info = MachineInfo()
        info.model = field("Model Name")
        info.chip = field("Chip").isEmpty ? field("Processor Name") : field("Chip")
        info.memory = field("Memory")
        info.os = "macOS " + (await Shell.run("sw_vers -productVersion").out)
        return info
    }
}

enum Scanner {
    /// Runs every check concurrently and returns all findings.
    static func runAll(_ checks: [Check] = Checks.all, progress: (@Sendable () async -> Void)? = nil) async -> [Finding] {
        await withTaskGroup(of: [Finding].self) { group in
            for check in checks { group.addTask { await check.execute() } }
            var all: [Finding] = []
            for await findings in group {
                all.append(contentsOf: findings)
                await progress?()
            }
            return all
        }
    }

    static func sorted(_ findings: [Finding]) -> [Finding] {
        findings.sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
    }
}
