<p align="center"><img src="Resources/AppIcon.png" width="160" alt="MacScan icon"></p>

<h1 align="center">MacScan</h1>

<p align="center">A native macOS app that audits your Mac's security, performance, storage and apps,<br>
rates every item <b>OK / Low / Medium / Critical</b>, and offers a one-click <b>Fix</b> where possible.</p>

---

- **Fast:** about 50 checks run in parallel and a scan takes about 5 seconds.
- **Read-only by default:** scanning never changes anything. Fixes run only when you click them.
- **Transparent:** every fix shows the exact command before it runs.
- **Exportable:** save reports as HTML or Markdown (⌘S / ⇧⌘S), or print one from the command line.
- **Universal:** runs natively on Apple Silicon and Intel Macs with macOS 14 Sonoma or later.

## Privacy & safety

MacScan is designed to be safe to run on any Mac:

- **No network access.** It makes no connections, has no analytics or telemetry, and never updates itself.
- **Nothing leaves your Mac and nothing is stored.** The only files it writes are reports you choose to export.
- **The scan only reads.** It uses the standard built-in macOS tools (`csrutil`, `fdesetup`, `socketfilterfw`,
  `tmutil`, `lsof`, `du`, `system_profiler`, …). Some checks look at sensitive files locally, such as testing
  whether SSH keys have a passphrase or launch items contain a token. Their contents are never shown, saved or sent.
- **Reports hide your username.** Your home folder appears as `~`. Reports do list installed apps, startup items
  and open services, so review one before posting it publicly.
- **Fixes are explicit.** Each fix shows its command first. Admin fixes use the standard macOS password dialog,
  and MacScan never sees or stores your password.
- **Fix All is conservative.** It shows every command and asks once. It never includes fixes that can't be
  undone or that remove things: emptying the Trash, moving apps to the Trash, uninstalling Node.js versions.
  Items that need a decision only open the right System Settings pane.
- **No hidden code.** Everything is in [`Sources/MacScan`](Sources/MacScan): about 1,250 lines of Swift with no
  dependencies. Read it, or build it yourself (see below).

## What it checks

| Area | Checks |
|---|---|
| **Security** | SIP, Gatekeeper, FileVault, firewall & stealth mode, Time Machine backups, automatic updates, auto-login, screen-lock delay, apps listening on the network (incl. Ollama and AirPlay Receiver), sharing services (SSH, Screen/File Sharing, Remote Management), launch items with world-readable secrets, SSH key permissions & passphrases, `.env` files in Downloads/Desktop, MDM enrollment |
| **Performance** | Memory pressure, swap, CPU load & top processes, process count, several IDEs open at once, thermal throttling, sleep blockers, uptime, battery health |
| **Disk & Storage** | Free space, SSD SMART status, old downloads, end-of-life Node.js versions (nvm), developer caches (npm, Yarn, pnpm, uv, pip, Homebrew, nvm, Gradle, CocoaPods, Playwright, Xcode DerivedData, simulators, app-updater leftovers, Trash), local AI model stores (LM Studio, Ollama, Hugging Face, Whisper, DiffusionBee, ComfyUI) |
| **Apps & Startup** | macOS updates, outdated Homebrew packages, Intel-only apps (on Apple Silicon), discontinued apps, third-party launch agents & daemons, system extensions / competing VPNs |

Items that don't apply are skipped, such as battery on a desktop Mac, Intel-only apps on an Intel Mac,
or caches under 500 MB.

## Install

### Download

Download `MacScan.zip` from [Releases](../../releases), unzip it, and move **MacScan.app** to Applications.

MacScan is not notarized by Apple, so macOS blocks it the first time you open it:

1. Open MacScan once and dismiss the warning.
2. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
   On macOS 14 you can instead right-click the app and choose **Open**.

Or remove the quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/MacScan.app
```

### Build from source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone <this repo> && cd macscan
./build.sh             # → build/MacScan.app (universal)
./build.sh --install   # also copies it to /Applications
./build.sh --zip       # also creates build/MacScan.zip for sharing
```

### Optional: Full Disk Access

Grant MacScan **Full Disk Access** in System Settings → Privacy & Security so it can read the date of your
last Time Machine backup and the size of the Trash. Everything else works without it.

## Command line

Print a report without opening a window, for example from a cron job:

```sh
/Applications/MacScan.app/Contents/MacOS/MacScan --report > report.md
/Applications/MacScan.app/Contents/MacOS/MacScan --report --html > report.html
```

## Project layout

```
Sources/MacScan/
  Checks.swift   all checks and their fixes
  Model.swift    Severity, Finding, Fix, Check, the scanner
  Shell.swift    runs commands (and admin commands via the macOS password prompt)
  Report.swift   HTML and Markdown export
  App.swift      SwiftUI app, fix confirmation, export
scripts/make-icon.swift   draws the app icon (Resources/AppIcon.icns)
build.sh                  builds, signs (ad hoc) and packages the .app
```

## Adding a check

Each check is a closure that runs shell commands and returns `Finding`s, optionally with a `Fix`:
`.shell` runs as the user, `.admin` asks for the password, and `.open` opens a URL or Settings pane.

```swift
Check("my.check", .security) {
    let out = await sh("some-command")
    return [out.contains("bad")
        ? Finding("My check", .medium, "What's wrong and why it matters",
                  fix: Fix("Fix It", .admin("fix-command")))
        : Finding("My check", .ok, "All good")]
}
```

Pass `batchable: false` to any fix that deletes data or can't be undone, so **Fix All** skips it.

## Disclaimer

MacScan is an early, personal project, provided as is under the MIT license, with no warranty.
Fixes change system settings and delete caches. Read each command before you confirm it, and keep a backup.

The icon shows a generic apple and is not the Apple logo. MacScan is not affiliated with or endorsed by
Apple Inc. Mac and macOS are trademarks of Apple Inc.

## License

[MIT](LICENSE)
