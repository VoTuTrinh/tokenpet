// Server-side quota (opt-in). Read-only: reuses the logins Claude Code / Codex already saved,
// sends each token only to its own vendor's usage endpoint, never refreshes or writes credentials.
// Endpoint contracts follow github.com/burakgon/ai-usage-menubar docs/provider-contracts.md.
import Foundation
import Security

struct FetchResult {
    var limits: [Limit] = []
    var extra: [String] = []          // e.g. "Extra usage: $3.20 / $50"
    var error: String?                // human-readable, shown in UI
    var retryAfter: Double?           // seconds, on 429
    var raw: Any?                     // for --probe
}

enum Server {
    static func httpGet(_ url: URL, headers: [String: String]) -> (Int, Data?, [AnyHashable: Any]) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, Data?, [AnyHashable: Any]) = (0, nil, [:])
        URLSession.shared.dataTask(with: req) { d, r, _ in
            let h = r as? HTTPURLResponse
            out = (h?.statusCode ?? 0, d, h?.allHeaderFields ?? [:])
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    static func time(_ v: Any?) -> Double {
        if let n = v as? NSNumber { let d = n.doubleValue; return d > 1e12 ? d / 1000 : d }
        if let s = v as? String {
            if let d = Double(s) { return d > 1e12 ? d / 1000 : d }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        return 0
    }

    static func retryAfter(_ h: [AnyHashable: Any]) -> Double? {
        for (k, v) in h where (k as? String)?.lowercased() == "retry-after" {
            if let s = v as? String, let d = Double(s) { return d }
        }
        return nil
    }

    // MARK: Claude

    static func claudeToken(allowUI: Bool) -> (String?, String?) {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "Claude Code-credentials",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowUI { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: AnyObject?
        var data: Data?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess { data = out as? Data }
        if data == nil {
            data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"))
        }
        guard let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let oa = o["claudeAiOauth"] as? [String: Any], let tok = oa["accessToken"] as? String else {
            return (nil, allowUI ? "Chưa có quyền đọc login Claude (Keychain)" : "Cần quyền Keychain — bấm Làm mới")
        }
        let exp = time(oa["expiresAt"])
        if exp > 0 && exp < Date().timeIntervalSince1970 {
            return (nil, "Token Claude hết hạn — mở Claude Code là tự làm mới")
        }
        return (tok, nil)
    }

    static func fetchClaude(allowUI: Bool = true) -> FetchResult {
        var r = FetchResult()
        let (tok, err) = claudeToken(allowUI: allowUI)
        guard let token = tok else { r.error = err; return r }
        let (code, data, hdr) = httpGet(URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                                        headers: ["Authorization": "Bearer \(token)",
                                                  "anthropic-beta": "oauth-2025-04-20",
                                                  "User-Agent": "TokenPet"])
        if code == 429 { r.error = "Server Claude báo gọi quá dày (429)"; r.retryAfter = retryAfter(hdr) ?? 600; return r }
        if code == 401 || code == 403 { r.error = "Token Claude bị từ chối — mở Claude Code để làm mới"; return r }
        guard code == 200, let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            r.error = "Server Claude lỗi (\(code))"; return r
        }
        r.raw = o
        let now = Date().timeIntervalSince1970
        func pct(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber else { return nil }
            return n.doubleValue   // API returns 0–100
        }
        func add(_ key: String, _ id: String, _ label: String, _ win: Double) {
            guard let w = o[key] as? [String: Any], let u = pct(w["utilization"]) else { return }
            r.limits.append(Limit(id: id, tool: "claude", label: label, used: u, resetsAt: time(w["resets_at"]),
                                  windowSec: win, source: "server", observedAt: now))
        }
        add("five_hour", "claude.5h", "5 giờ", 5 * 3600)
        add("seven_day", "claude.week", "Tuần · mọi model", 7 * 86400)
        add("seven_day_sonnet", "claude.week.sonnet", "Tuần · Sonnet", 7 * 86400)
        add("seven_day_opus", "claude.week.opus", "Tuần · Opus", 7 * 86400)
        // Every entry in limits[]: model-scoped weeklies (Fable…) and any kind we don't map yet.
        var seenScoped = Set<String>()
        if let arr = o["limits"] as? [[String: Any]] {
            for l in arr {
                guard let kind = l["kind"] as? String, let u = pct(l["percent"] ?? l["utilization"]) else { continue }
                if kind == "weekly_all" && o["seven_day"] is [String: Any] { continue }
                let weekly = (l["group"] as? String) == "weekly" || kind.hasPrefix("weekly")
                var id = "claude.\(kind)", label = kind
                if kind == "weekly_all" { id = "claude.week"; label = "Tuần" }
                if kind == "weekly_scoped" {
                    let scope = l["scope"] as? [String: Any]
                    let model = (scope?["model"] as? [String: Any])?["display_name"] as? String ?? "?"
                    id = "claude.week." + model.lowercased().replacingOccurrences(of: " ", with: "-")
                    label = "Tuần · \(model)"; seenScoped.insert(model.lowercased())
                }
                r.limits.append(Limit(id: id, tool: "claude", label: label, used: u, resetsAt: time(l["resets_at"]),
                                      windowSec: weekly ? 7 * 86400 : 5 * 3600, source: "server", observedAt: now))
            }
        }
        if seenScoped.isEmpty, let w = o["seven_day_overage_included"] as? [String: Any], let u = pct(w["utilization"]) {
            r.limits.append(Limit(id: "claude.week.fable", tool: "claude", label: "Tuần · Fable", used: u,
                                  resetsAt: time(w["resets_at"]), windowSec: 7 * 86400, source: "server", observedAt: now))
        }
        if let bd = o["seven_day_breakdown"] as? [String: Any], let rows = bd["rows"] as? [[String: Any]] {
            let parts = rows.compactMap { row -> (String, Double)? in
                guard let n = row["display_name"] as? String, let p = (row["percent"] as? NSNumber)?.doubleValue, p > 0 else { return nil }
                return (n, p)
            }.sorted { $0.1 > $1.1 }
            if !parts.isEmpty { r.extra.append("Quota tuần tiêu ở: " + parts.map { "\($0.0) \(Int($0.1))%" }.joined(separator: " · ")) }
        }
        if let ex = o["extra_usage"] as? [String: Any], (ex["is_enabled"] as? Bool) == true {
            let dp = (ex["decimal_places"] as? NSNumber)?.intValue ?? 2
            let div = pow(10.0, Double(dp))
            let used = ((ex["used_credits"] as? NSNumber)?.doubleValue ?? 0) / div
            let cap = ((ex["monthly_limit"] as? NSNumber)?.doubleValue ?? 0) / div
            let cur = (ex["currency"] as? String) ?? "USD"
            r.extra.append(cap > 0 ? String(format: "Extra usage tháng: %.2f / %.2f %@", used, cap, cur)
                                   : String(format: "Extra usage tháng: %.2f %@", used, cur))
        }
        return r
    }

    // MARK: Codex

    static func fetchCodex(allowUI: Bool = true) -> FetchResult {
        var r = FetchResult()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("auth.json") }
            ?? home.appendingPathComponent(".codex/auth.json")
        guard let d = try? Data(contentsOf: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["tokens"] as? [String: Any], let token = t["access_token"] as? String else {
            r.error = "Không đọc được login ChatGPT của Codex"; return r
        }
        if let exp = jwtExp(token), exp < Date().timeIntervalSince1970 {
            r.error = "Token Codex hết hạn — chạy Codex là tự làm mới"; return r
        }
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "TokenPet"]
        if let acc = t["account_id"] as? String { headers["ChatGPT-Account-Id"] = acc }
        let (code, data, hdr) = httpGet(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        if code == 429 { r.error = "Server Codex báo gọi quá dày (429)"; r.retryAfter = retryAfter(hdr) ?? 600; return r }
        if code == 401 || code == 403 { r.error = "Token Codex bị từ chối — chạy Codex để làm mới"; return r }
        guard code == 200, let body = data, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            r.error = "Server Codex lỗi (\(code))"; return r
        }
        r.raw = j
        let now = Date().timeIntervalSince1970
        func windows(_ rl: [String: Any]?, prefix: String, name: String) {
            guard let rl = rl else { return }
            for k in ["primary_window", "secondary_window"] {
                guard let w = rl[k] as? [String: Any], let u = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let secs = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? (k == "primary_window" ? 18000 : 604800)
                var reset = time(w["reset_at"])
                let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue
                if reset == 0, let a = after { reset = now + a }
                if u == 0, let a = after, a >= secs - 120 { reset = 0 }   // window not started yet
                let isWeek = secs >= 86400
                let label = (name.isEmpty ? "" : "\(name) · ") + (isWeek ? "Tuần" : (secs == 18000 ? "5 giờ" : "\(Int(secs / 3600)) giờ"))
                r.limits.append(Limit(id: "\(prefix).\(isWeek ? "week" : "5h")", tool: "codex", label: label, used: u,
                                      resetsAt: reset, windowSec: secs, source: "server", observedAt: now))
            }
        }
        windows(j["rate_limit"] as? [String: Any], prefix: "codex", name: "")
        if let extra = j["additional_rate_limits"] as? [[String: Any]] {
            for a in extra {
                let name = (a["limit_name"] as? String) ?? (a["metered_feature"] as? String) ?? "Khác"
                let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
                windows(a["rate_limit"] as? [String: Any], prefix: "codex.\(slug)", name: name)
            }
        }
        if let c = j["credits"] as? [String: Any], (c["has_credits"] as? Bool) == true {
            r.extra.append("Credits: \((c["balance"] as? String) ?? "\(c["balance"] ?? "?")")")
        }
        if let rc = j["rate_limit_reset_credits"] as? [String: Any], let n = (rc["available_count"] as? NSNumber)?.intValue, n > 0 {
            r.extra.append("Lượt reset để dành: \(n)")
        }
        return r
    }

    static func jwtExp(_ jwt: String) -> Double? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["exp"] as? NSNumber)?.doubleValue
    }
}

/// Strip anything identifying before printing a probe response.
func scrubbed(_ x: Any) -> Any {
    if let d = x as? [String: Any] {
        var o: [String: Any] = [:]
        for (k, v) in d {
            let lk = k.lowercased()
            o[k] = ["email", "user", "account", "token", "org", "id"].contains(where: { lk.contains($0) }) && !(v is [String: Any]) && !(v is [Any])
                ? "<redacted>" : scrubbed(v)
        }
        return o
    }
    if let a = x as? [Any] { return a.map(scrubbed) }
    return x
}
