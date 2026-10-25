import SwiftUI
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        // `MacScan --report [--html]` prints a report to stdout without opening a window.
        if CommandLine.arguments.contains("--report") {
            let html = CommandLine.arguments.contains("--html")
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                async let machine = MachineInfo.load()
                let findings = await Scanner.runAll()
                let text = html ? Report.html(findings, machine: await machine, date: Date())
                                : Report.markdown(findings, machine: await machine, date: Date())
                print(text)
                done.signal()
            }
            done.wait()
            return
        }
        MacScanApp.main()
    }
}

struct MacScanApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var auditor = Auditor()

    var body: some Scene {
        WindowGroup("MacScan") {
            ContentView()
                .environmentObject(auditor)
                .frame(minWidth: 760, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Scan Again") { Task { await auditor.scan() } }
                    .keyboardShortcut("r")
                    .disabled(auditor.isScanning)
                Divider()
                Button("Export HTML Report…") { auditor.export(.html) }
                    .keyboardShortcut("s")
                    .disabled(auditor.findings.isEmpty)
                Button("Export Markdown Report…") { auditor.export(.markdown) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(auditor.findings.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - State

enum ReportFormat { case html, markdown }

@MainActor
final class Auditor: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var machine = MachineInfo()
    @Published var isScanning = false
    @Published var completed = 0
    @Published var lastScan: Date?
    @Published var fixing: Set<String> = []          // check IDs with a fix in progress
    @Published var message: String?                  // fix errors shown in an alert

    let checks = Checks.all

    var batchFixes: [Finding] {
        findings.filter { $0.severity.isIssue && ($0.fix.map { $0.batchable && !$0.action.isManual } ?? false) }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        completed = 0
        findings = []
        async let info = MachineInfo.load()
        await withTaskGroup(of: [Finding].self) { group in
            for check in checks { group.addTask { await check.execute() } }
            for await result in group {
                findings.append(contentsOf: result)
                completed += 1
            }
        }
        machine = await info
        lastScan = Date()
        isScanning = false
    }

    func apply(_ targets: [Finding]) async {
        let ids = Set(targets.map(\.checkID))
        fixing.formUnion(ids)
        var errors: [String] = []

        // All admin commands share one password prompt.
        let admin = targets.compactMap { $0.fix?.action }.filter(\.needsAdmin).map(\.command)
        if !admin.isEmpty {
            let result = Shell.runAsAdmin(admin.joined(separator: "; "))
            if !result.ok && result.out != "Cancelled." { errors.append(result.out) }
        }
        for target in targets {
            guard let fix = target.fix else { continue }
            switch fix.action {
            case .admin: continue
            case .open(let url):
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            case .shell(let command):
                let result = await Shell.run(command, timeout: 1800)
                if result.status != 0 { errors.append("\(target.title): \(result.out.isEmpty ? "exit code \(result.status)" : result.out)") }
            }
        }

        for id in ids { await rerun(id) }
        fixing.subtract(ids)
        if !errors.isEmpty { message = errors.joined(separator: "\n\n") }
    }

    func rerun(_ id: String) async {
        guard let check = checks.first(where: { $0.id == id }) else { return }
        let fresh = await check.execute()
        findings.removeAll { $0.checkID == id }
        findings.append(contentsOf: fresh)
    }

    func export(_ format: ReportFormat) {
        let date = lastScan ?? Date()
        let panel = NSSavePanel()
        let stamp = date.formatted(.iso8601.year().month().day())
        switch format {
        case .html:
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = "MacScan Report \(stamp).html"
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "MacScan Report \(stamp).md"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .html ? Report.html(findings, machine: machine, date: date)
                                   : Report.markdown(findings, machine: machine, date: date)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if format == .html { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            message = "Couldn't save the report: \(error.localizedDescription)"
        }
    }
}

// MARK: - Views

extension Severity {
    var color: Color {
        switch self {
        case .critical: .red
        case .medium: .orange
        case .low: Color(red: 0.78, green: 0.58, blue: 0.0)
        case .info: .indigo
        case .ok: .green
        }
    }

    var symbol: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .medium: "exclamationmark.triangle.fill"
        case .low: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        }
    }
}

private struct PendingFix: Identifiable {
    let id = UUID()
    let findings: [Finding]

    var title: String {
        findings.count == 1 ? "\(findings[0].fix?.label ?? "Fix"): \(findings[0].title)?" : "Apply \(findings.count) fixes?"
    }

    var message: String {
        let admin = findings.contains { $0.fix?.action.needsAdmin == true }
        let body: String
        if findings.count == 1, let action = findings[0].fix?.action {
            body = action.isManual ? "Opens System Settings so you can change this yourself." : "This will run:\n\n\(action.command)"
        } else {
            body = findings.map { f in
                let command = f.fix?.action.command ?? ""
                return "• \(f.title)\n   \(command.contains("\n") ? (f.fix?.label ?? "") : command)"
            }.joined(separator: "\n")
        }
        return body + (admin ? "\n\nmacOS will ask for your administrator password." : "")
    }
}

struct ContentView: View {
    @EnvironmentObject private var auditor: Auditor
    @State private var issuesOnly = false
    @State private var pending: PendingFix?

    var body: some View {
        VStack(spacing: 0) {
            SummaryHeader()
            Divider()
            if auditor.findings.isEmpty && !auditor.isScanning {
                VStack(spacing: 12) {
                    Image(systemName: "stethoscope").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No scan yet").font(.title2.bold())
                    Button("Scan This Mac") { Task { await auditor.scan() } }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                findingsList
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $issuesOnly) { Label("Issues Only", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Show only items that need attention")
                Button {
                    pending = PendingFix(findings: auditor.batchFixes)
                } label: { Label("Fix All", systemImage: "wand.and.stars") }
                    .help("Apply every automatic fix (asks first)")
                    .disabled(auditor.isScanning || auditor.batchFixes.isEmpty)
                Menu {
                    Button("HTML…") { auditor.export(.html) }
                    Button("Markdown…") { auditor.export(.markdown) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(auditor.findings.isEmpty || auditor.isScanning)
                Button {
                    Task { await auditor.scan() }
                } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .disabled(auditor.isScanning)
            }
        }
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button(p.findings.count == 1 ? (p.findings[0].fix?.label ?? "Run") : "Apply All") {
                Task { await auditor.apply(p.findings) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
        .alert("Some fixes didn't complete", isPresented: Binding(get: { auditor.message != nil }, set: { if !$0 { auditor.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(auditor.message ?? "")
        }
        .task { if auditor.lastScan == nil { await auditor.scan() } }
    }

    private var findingsList: some View {
        List {
            ForEach(Category.allCases) { category in
                let items = Scanner.sorted(auditor.findings.filter { $0.category == category && (!issuesOnly || $0.severity.isIssue) })
                if !items.isEmpty {
                    Section {
                        ForEach(items) { finding in
                            FindingRow(finding: finding, busy: auditor.fixing.contains(finding.checkID)) {
                                pending = PendingFix(findings: [finding])
                            }
                        }
                    } header: {
                        Label(category.rawValue, systemImage: category.icon).font(.headline).padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }
}

private struct SummaryHeader: View {
    @EnvironmentObject private var auditor: Auditor

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(auditor.machine.summary.isEmpty ? "MacScan" : auditor.machine.summary)
                    .font(.title3.weight(.semibold))
                if auditor.isScanning {
                    ProgressView(value: Double(auditor.completed), total: Double(auditor.checks.count)) {
                        Text("Scanning… \(auditor.completed) of \(auditor.checks.count) checks").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 320)
                } else if let date = auditor.lastScan {
                    Text("Scanned \(Report.dateString(date))").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            ForEach([Severity.critical, .medium, .low, .ok], id: \.self) { sev in
                let count = auditor.findings.filter { $0.severity == sev }.count
                VStack(spacing: 2) {
                    Text("\(count)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(count > 0 ? sev.color : .secondary)
                    Text(sev.label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 56)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct FindingRow: View {
    let finding: Finding
    let busy: Bool
    let onFix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.severity.symbol)
                .foregroundStyle(finding.severity.color)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(finding.title).font(.body.weight(.semibold))
                    Text(finding.severity.label)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(finding.severity.color)
                        .background(finding.severity.color.opacity(0.15), in: Capsule())
                }
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if busy {
                ProgressView().controlSize(.small).frame(width: 60)
            } else if let fix = finding.fix, finding.severity.isIssue || finding.severity == .info {
                Button(action: onFix) {
                    if fix.action.needsAdmin { Label(fix.label, systemImage: "lock.fill") } else { Text(fix.label) }
                }
                .buttonStyle(.bordered)
                .tint(finding.severity >= .medium ? finding.severity.color : nil)
                .help(fix.action.isManual ? "Opens System Settings" : fix.action.command)
            }
        }
        .padding(.vertical, 6)
    }
}
