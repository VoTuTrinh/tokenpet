// macOS notifications for the moments a developer must act: crossing a threshold,
// about to run out before reset, abnormal burn, and quota coming back.
import Foundation
import UserNotifications
import AppKit

final class Notifier {
    static let allThresholds = [50, 70, 80, 90, 95]
    var p: Prefs { Prefs.shared }
    var thresholds: [Int] {
        get { (UserDefaults.standard.array(forKey: "thresholds") as? [Int]) ?? p.thresholds }
        set { p.thresholds = newValue }
    }
    var warnBeforeEmpty: Bool { get { p.warnBeforeEmpty } set { p.warnBeforeEmpty = newValue } }
    var warnAnomaly: Bool { get { p.warnAnomaly } set { p.warnAnomaly = newValue } }
    var notifyReset: Bool { get { p.notifyReset } set { p.notifyReset = newValue } }
    /// Every alert also goes here (level 1 = watch, 2 = act now, 3 = good news) so the notch can peek.
    var onAlert: ((String, Int) -> Void)?
    /// "Máy nặng": the app shows a toast with the pet and the concrete suggestions (and the usual notification).
    var onCleanup: ((MachineState, [(String, Double)]) -> Void)?
    private var weekDay: [String: Double] = [:]
    private var wasRunning: [String: Double] = [:]   // session id -> running since
    private var ramWarnedAt = 0.0

    private var sent = Set<String>()
    private var lastUsed: [String: (Double, Double)] = [:]   // id -> (used, resetsAt)
    private var primed = false
    private var useUN = false

    init(requestAuth: Bool = true) {
        guard requestAuth, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in self.useUN = ok }
    }

    func evaluate(_ ins: [Insight]) {
        var out: [(String, String, Int)] = []
        for i in ins {
            let l = i.limit
            let name = "\(l.tool == "claude" ? "Claude" : "Codex") · \(l.label)"
            let win = "\(l.id)@\(Int((l.resetsAt + 1800) / 3600))"
            // reset: was ≥ 70% in an older window, now the window rolled over
            if let (u, r) = lastUsed[l.id], u >= 70, r > 0, (i.stale || abs(r - l.resetsAt) > 600), notifyReset {
                out.append(("\(name) đã reset", "Quota dùng lại được.", 3))
            }
            lastUsed[l.id] = (i.used, i.stale ? 0 : l.resetsAt)
            if i.stale { continue }
            for t in thresholds where i.used >= Double(t) {
                let k = "\(win)#t\(t)"
                if sent.insert(k).inserted, primed {
                    out.append(("\(name) đã dùng \(Int(i.used))%", i.headline.isEmpty ? "Reset sau \(fmtDur(i.resetIn))." : "Dự báo \(i.headline). Reset sau \(fmtDur(i.resetIn)).", i.used >= 100 ? 2 : 1))
                }
            }
            if warnBeforeEmpty, let m = i.minutesToEmpty, m < Double(p.emptyMinutes) {
                let k = "\(win)#empty"
                if sent.insert(k).inserted, primed {
                    out.append(("\(name) sắp hết (~\(Int(m)) phút)", "Còn \(Int(100 - i.used))%. Reset sau \(fmtDur(i.resetIn)). Nên lưu lại tiến độ.", 2))
                }
            }
            if warnAnomaly, let a = i.anomaly {
                let k = "\(win)#anom\(Int(Date().timeIntervalSince1970 / 3600))"
                if sent.insert(k).inserted, primed {
                    out.append(("\(name) tụt nhanh bất thường", String(format: "Gấp %.1f lần bình thường. Kiểm tra agent/subagent đang chạy.", a), 1))
                }
            }
            // Weekly won't last until reset: at most once a day, and only when it's more than a few hours out.
            if p.warnWeek, l.weekly, let h = i.hitAt, h - Date().timeIntervalSince1970 > Double(p.emptyMinutes) * 60 {
                // A forecast is a state, not a past event: do not swallow today's warning on the priming pass
                // (the app launched while the week was already predicted to run out); it fires on the next tick.
                let day = startOfDay(Date().timeIntervalSince1970)
                if weekDay[l.id] != day, primed {
                    weekDay[l.id] = day
                    out.append(("\(name) sẽ hết trước reset", "Dự báo \(i.headline), reset \(fmtWhen(l.resetsAt)). Còn \(String(format: "%.0f", i.perDayLeft ?? 0))%/ngày.", 1))
                }
            }
        }
        // First pass only records the current state, so restarting the app doesn't replay old alerts.
        if !primed { primed = true; return }
        // Several at once → one notification.
        if out.count > 2 {
            let lv = out.map { $0.2 }.max() ?? 1
            post("\(out.count) việc cần chú ý", out.map { $0.0 }.joined(separator: " · "), level: lv)
        } else { for (t, b, lv) in out { post(t, b, level: lv) } }
    }

    /// A session that ran ≥ 5 min went quiet (off by default); the machine is under memory pressure and AI
    /// tooling has something to clean (idle sessions, leftover processes), at most once an hour.
    func evaluate(sessions: [SessionInfo], machine m: MachineState) {
        let now = Date().timeIntervalSince1970
        var still: [String: Double] = [:]
        for s in sessions where s.running { still[s.id] = wasRunning[s.id] ?? now }
        if p.taskDone {
            for (id, since) in wasRunning where still[id] == nil && now - since >= 300 {
                if let s = sessions.first(where: { $0.id == id }) {
                    post("\(s.project) xong", "\(s.tool == "claude" ? "Claude" : "Codex") chạy \(fmtDur(now - since)) · \(fmtTok(s.tok5h)) tok trong 5h.", level: 3)
                }
            }
        }
        wasRunning = still
        guard p.agentRAM, now - ramWarnedAt > 3600 else { return }
        let c = m.cleanable(p.idleHours)
        let tooMuch = m.aiMB / 1024 >= p.agentRAMGB
        guard (m.heavy && c.mb > 0) || tooMuch else { return }
        ramWarnedAt = now
        var what: [String] = []
        if !c.sessions.isEmpty { what.append("\(c.sessions.count) session ngủ ≥ \(Int(p.idleHours))h") }
        if !c.leftovers.isEmpty { what.append("\(c.leftovers.count) process bỏ quên") }
        let title = m.heavy ? "Máy sắp hết RAM · AI giữ \(fmtMB(m.aiMB))" : "AI đang giữ \(fmtMB(m.aiMB))"
        let sug = m.suggestions(p.idleHours)
        let body = (what.isEmpty ? "" : what.joined(separator: " · ") + " (\(fmtMB(c.mb))). ")
            + (sug.first.map { "Nên: \($0.0) → \(fmtMB($0.1)). " } ?? "") + "⌃⌥M mở bảng Máy."
        post(title, body, level: m.pressure >= 4 ? 2 : 1)
        if sink == nil { DispatchQueue.main.async { self.onCleanup?(m, sug) } }
    }

    var sink: ((String, String) -> Void)?    // tests: capture instead of posting

    /// Level 2 (act now) always reaches macOS notifications; level 1/3 only peek in the notch unless "Báo hết".
    func post(_ title: String, _ body: String, level: Int = 2) {
        if let sink = sink { sink(title, body); return }
        DispatchQueue.main.async { self.onAlert?(title, level) }
        guard level == 2 || p.preset == .all else { return }
        if useUN {
            let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = p.sound ? .default : nil
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let pr = Process(); pr.launchPath = "/usr/bin/osascript"
            pr.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\"" + (self.p.sound ? " sound name \"Glass\"" : "")]
            try? pr.run()
        }
    }
}
