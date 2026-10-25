import Foundation

enum Report {
    static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func counts(_ findings: [Finding]) -> [(Severity, Int)] {
        [Severity.critical, .medium, .low, .ok].map { sev in (sev, findings.filter { $0.severity == sev }.count) }
    }

    // MARK: Markdown

    static func markdown(_ findings: [Finding], machine: MachineInfo, date: Date) -> String {
        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
        }
        var md = "# MacScan Report\n\n"
        md += "**\(machine.summary)**  \nScanned \(dateString(date))\n\n"
        md += counts(findings).map { "**\($0.0.label):** \($0.1)" }.joined(separator: " · ") + "\n"
        for category in Category.allCases {
            let items = Scanner.sorted(findings.filter { $0.category == category })
            guard !items.isEmpty else { continue }
            md += "\n## \(category.rawValue)\n\n| Severity | Item | Details | Suggested fix |\n|---|---|---|---|\n"
            for f in items {
                let fix = f.severity.isIssue ? f.fix.map { fix in
                    fix.action.command.contains("\n") ? fix.label : "\(fix.label): `\(cell(fix.action.command))`"
                } ?? "" : ""
                md += "| \(f.severity.label) | \(cell(f.title)) | \(cell(f.detail)) | \(fix) |\n"
            }
        }
        return md
    }

    // MARK: HTML

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func css(_ s: Severity) -> String {
        switch s {
        case .critical: "crit"
        case .medium: "med"
        case .low: "low"
        case .info: "info"
        case .ok: "ok"
        }
    }

    static func html(_ findings: [Finding], machine: MachineInfo, date: Date) -> String {
        var body = ""
        for category in Category.allCases {
            let items = Scanner.sorted(findings.filter { $0.category == category })
            guard !items.isEmpty else { continue }
            body += "<section><h2>\(escape(category.rawValue))</h2>"
            for f in items {
                let fix = f.severity.isIssue ? f.fix.map {
                    "<details><summary>Fix: \(escape($0.label))\($0.action.needsAdmin ? " (admin)" : "")</summary><pre>\(escape($0.action.command))</pre></details>"
                } ?? "" : ""
                body += """
                <div class="row"><span class="badge \(css(f.severity))">\(f.severity.label)</span>
                <div><div class="title">\(escape(f.title))</div><div class="detail">\(escape(f.detail))</div>\(fix)</div></div>
                """
            }
            body += "</section>"
        }
        let pills = counts(findings).map { "<span class=\"badge \(css($0.0))\">\($0.1) \($0.0.label)</span>" }.joined(separator: " ")
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>MacScan Report</title>
        <style>
        :root { --bg:#f6f6f8; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea;
                --crit:#d70015; --med:#c93400; --low:#9a7400; --info:#5e5ce6; --ok:#248a3d; }
        @media (prefers-color-scheme: dark) { :root { --bg:#1c1c1e; --card:#2c2c2e; --text:#f5f5f7; --muted:#a1a1a6; --line:#3a3a3c;
                --crit:#ff453a; --med:#ff9f0a; --low:#ffd60a; --info:#7d7aff; --ok:#30d158; } }
        * { box-sizing:border-box } body { margin:0; padding:32px 16px; background:var(--bg); color:var(--text);
          font:15px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif }
        main { max-width:900px; margin:0 auto } h1 { margin:0 0 4px; font-size:28px } .sub { color:var(--muted); margin-bottom:12px }
        section { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:4px 20px; margin:20px 0 }
        h2 { font-size:17px; margin:16px 0 8px } .row { display:flex; gap:14px; padding:12px 0; border-top:1px solid var(--line) }
        h2 + .row { border-top:none } .title { font-weight:600 } .detail { color:var(--muted); white-space:pre-wrap; overflow-wrap:anywhere }
        .badge { flex:0 0 auto; display:inline-block; min-width:68px; text-align:center; font-size:12px; font-weight:700;
          padding:2px 8px; border-radius:99px; height:fit-content; color:var(--c); background:color-mix(in srgb, var(--c) 15%, transparent) }
        .crit{--c:var(--crit)} .med{--c:var(--med)} .low{--c:var(--low)} .info{--c:var(--info)} .ok{--c:var(--ok)}
        details { margin-top:6px } summary { cursor:pointer; color:var(--info); font-size:13px }
        pre { background:var(--bg); border-radius:8px; padding:10px; overflow-x:auto; font-size:12px; white-space:pre-wrap }
        </style></head><body><main>
        <h1>MacScan Report</h1><div class="sub">\(escape(machine.summary))<br>Scanned \(escape(dateString(date)))</div>
        <div>\(pills)</div>
        \(body)
        </main></body></html>
        """
    }
}
