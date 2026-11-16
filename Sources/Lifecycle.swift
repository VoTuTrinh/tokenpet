// What a shipped app needs around its features: who it is (version, links), the Claude statusline
// source switched from inside the app, a check for a newer release, and a clean way out.
import Foundation
import AppKit
import ServiceManagement

extension Notification.Name {
    /// Posted whenever the glance opens on any surface. Onboarding listens to it ("bạn vừa mở bảng").
    static let glanceOpened = Notification.Name("TokenPetGlanceOpened")
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    /// "owner/name" on GitHub; empty in a build that was not configured for releases.
    static var repository: String { Bundle.main.object(forInfoDictionaryKey: "TPRepository") as? String ?? "" }
    static var homepage: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "TPHomepage") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
    static var releasesPage: URL? { repository.isEmpty ? nil : URL(string: "https://github.com/\(repository)/releases/latest") }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var hasClaude: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) }
    static var hasCodex: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) }
}

/// Claude Code sends `rate_limits` to its statusLine command on stdin. Enabling wraps the user's current
/// command: the payload is saved to TokenPet's folder, then passed unchanged to the original command, so
/// the statusline looks the same. Disabling puts the original command back. Same files as the two shell
/// scripts in the repo, so either can undo the other.
enum StatuslineHook {
    struct Failure: Error { let message: String }
    static var settingsURL: URL { AppInfo.home.appendingPathComponent(".claude/settings.json") }
    private static var orig: URL { supportDir.appendingPathComponent("orig-statusline.sh") }
    private static var tee: URL { supportDir.appendingPathComponent("statusline-tee.sh") }
    private static let command = "\"$HOME/Library/Application Support/TokenPet/statusline-tee.sh\""
    static var enabled: Bool { FileManager.default.fileExists(atPath: orig.path) }

    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }      // no file yet: start empty
        guard let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: L("Can't read ~/.claude/settings.json (invalid JSON). TokenPet changed nothing.", "Không đọc được ~/.claude/settings.json (JSON không hợp lệ). TokenPet không sửa gì."))
        }
        return cfg
    }
    private static func write(_ cfg: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    static func enable() throws {
        guard !enabled else { return }
        guard AppInfo.hasClaude else { throw Failure(message: L("Claude Code not found on this Mac (no ~/.claude).", "Chưa thấy Claude Code trên máy này (không có ~/.claude).")) }
        let fm = FileManager.default
        var cfg = try read()
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = supportDir.appendingPathComponent("settings.backup.json")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        var sl = cfg["statusLine"] as? [String: Any] ?? [:]
        let original = sl["command"] as? String ?? ""
        let script = """
        #!/bin/sh
        D="$HOME/Library/Application Support/TokenPet"
        payload=$(cat)
        case "$payload" in
          *'"rate_limits"'*) printf '%s' "$payload" > "$D/claude-statusline.json.tmp" && mv "$D/claude-statusline.json.tmp" "$D/claude-statusline.json" ;;
        esac
        printf '%s\\n' "$payload" | /bin/sh "$D/orig-statusline.sh"

        """
        do {
            try ("#!/bin/sh\n" + original + "\n").write(to: orig, atomically: true, encoding: .utf8)
            try script.write(to: tee, atomically: true, encoding: .utf8)
            for u in [orig, tee] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
            sl["type"] = "command"; sl["command"] = command
            cfg["statusLine"] = sl
            try write(cfg)
        } catch {
            try? fm.removeItem(at: orig); try? fm.removeItem(at: tee)     // half-done is worse than not done
            throw Failure(message: L("Can't write: \(error.localizedDescription)", "Không ghi được: \(error.localizedDescription)"))
        }
    }

    static func disable() throws {
        guard enabled else { return }
        let fm = FileManager.default
        let saved = (try? String(contentsOf: orig, encoding: .utf8)) ?? ""
        let original = saved.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first
            .map { String($0).trimmingCharacters(in: .newlines) } ?? ""
        var cfg = try read()
        var sl = cfg["statusLine"] as? [String: Any] ?? [:]
        // Only put the old command back if the statusline is still ours; the user may have changed it since.
        if (sl["command"] as? String) == command {
            if original.isEmpty { cfg.removeValue(forKey: "statusLine") } else { sl["command"] = original; cfg["statusLine"] = sl }
            do { try write(cfg) } catch { throw Failure(message: L("Can't write ~/.claude/settings.json: \(error.localizedDescription)", "Không ghi được ~/.claude/settings.json: \(error.localizedDescription)")) }
        }
        for u in [orig, tee, supportDir.appendingPathComponent("claude-statusline.json")] { try? fm.removeItem(at: u) }
    }
}

/// Asks GitHub for the latest release. Manual only (a button in Settings): TokenPet never phones home by itself.
enum UpdateCheck {
    enum Result { case upToDate, newer(version: String, page: URL), failed(String) }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let n = { (s: String) in s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
        let x = n(a), y = n(b)
        for k in 0..<max(x.count, y.count) {
            let l = k < x.count ? x[k] : 0, r = k < y.count ? y[k] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func run(_ done: @escaping (Result) -> Void) {
        guard !AppInfo.repository.isEmpty, let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest") else {
            done(.failed(L("This build is not linked to a release repository.", "Bản build này không gắn với kho phát hành nào."))); return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("TokenPet", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let out: Result
            if let err = err { out = .failed(err.localizedDescription) }
            else if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tag = j["tag_name"] as? String {
                let page = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesPage ?? url
                out = isNewer(tag, than: AppInfo.version) ? .newer(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")), page: page) : .upToDate
            } else if (resp as? HTTPURLResponse)?.statusCode == 404 { out = .failed(L("No releases yet.", "Chưa có bản phát hành nào.")) }
            else { out = .failed(L("Couldn't read GitHub's reply.", "GitHub trả lời không đọc được.")) }
            DispatchQueue.main.async { done(out) }
        }.resume()
    }
}

/// Removes everything TokenPet put on this Mac, then quits. Nothing outside this list is touched.
enum Uninstaller {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.tokenpet" }
    /// The .app we are running from, if we are inside one (a bare binary from `swiftc` is left alone).
    static var appBundle: URL? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil }

    static var plan: [String] {
        var p: [String] = []
        if StatuslineHook.enabled { p.append(L("Restore the Claude Code status line", "Trả statusline của Claude Code về như cũ")) }
        if SMAppService.mainApp.status == .enabled { p.append(L("Stop opening at login", "Bỏ mở cùng máy")) }
        p.append(L("Delete data: quota history, price table, settings (~/Library/Application Support/TokenPet)", "Xóa dữ liệu: lịch sử quota, bảng giá, cài đặt (~/Library/Application Support/TokenPet)"))
        if let a = appBundle { p.append(L("Move \(a.lastPathComponent) to the Trash", "Chuyển \(a.lastPathComponent) vào Thùng rác")) }
        return p
    }

    static func confirmAndRun() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("Uninstall TokenPet from this Mac?", "Gỡ TokenPet khỏi máy này?")
        a.informativeText = plan.map { "•  " + $0 }.joined(separator: "\n")
            + L("\n\nYour Claude Code and Codex logins, logs and sessions are not touched.", "\n\nLogin Claude Code và Codex, log và session của bạn không bị đụng tới.")
        a.addButton(withTitle: L("Uninstall TokenPet", "Gỡ TokenPet"))
        a.addButton(withTitle: L("Cancel", "Hủy"))
        a.buttons.first?.hasDestructiveAction = true
        a.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    static func run() {
        let fm = FileManager.default
        var problems: [String] = []
        do { try StatuslineHook.disable() } catch let e as StatuslineHook.Failure { problems.append(e.message) } catch {}
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        let lib = AppInfo.home.appendingPathComponent("Library")
        let leftovers = ["Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID).binarycookies",
                         "Saved Application State/\(bundleID).savedState", "WebKit/\(bundleID)"]
        // The statusline could not be restored: keep the folder, the hook script in it is still in use.
        if problems.isEmpty { try? fm.removeItem(at: supportDir) }
        for l in leftovers { try? fm.removeItem(at: lib.appendingPathComponent(l)) }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        if let app = appBundle { try? fm.trashItem(at: app, resultingItemURL: nil) }
        if !problems.isEmpty {
            let a = NSAlert()
            a.messageText = L("Uninstalled, with one thing left to do by hand", "Đã gỡ, còn một việc phải làm tay")
            a.informativeText = problems.joined(separator: "\n") + L("\nOpen ~/.claude/settings.json and fix the statusLine entry, then delete the folder ~/Library/Application Support/TokenPet.", "\nMở ~/.claude/settings.json và sửa mục statusLine, rồi xóa thư mục ~/Library/Application Support/TokenPet.")
            a.runModal()
        }
        exit(0)
    }
}
