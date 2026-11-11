// Quota windows from every source, their history, and what they mean for the developer:
// will I be cut off before reset, am I on pace for the week, is the burn abnormal, which limit binds.
import Foundation

struct Limit: Codable {
    var id: String            // stable key, e.g. "claude.week.fable", "codex.5h"
    var tool: String          // "claude" | "codex"
    var label: String
    var used: Double          // 0–100
    var resetsAt: Double      // epoch seconds, 0 = unknown
    var windowSec: Double
    var source: String        // "server" | "statusline" | "log"
    var observedAt: Double
    var weekly: Bool { windowSec >= 86400 }
}

struct Sample: Codable { var ts: Double; var used: Double; var resetsAt: Double }

/// Keeps every observation per limit id (persisted, 21 days) and the freshest current value.
final class LimitStore {
    private(set) var current: [String: Limit] = [:]
    private(set) var history: [String: [Sample]] = [:]
    private let url = supportDir.appendingPathComponent("quota-history.jsonl")
    private var pending: [String] = []
    private let readOnly: Bool
    static let rank = ["server": 3, "statusline": 2, "log": 1]

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cut = Date().timeIntervalSince1970 - 21 * 86400
        for line in s.split(separator: "\n") {
            autoreleasepool {
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let id = o["id"] as? String, let ts = (o["ts"] as? NSNumber)?.doubleValue, ts >= cut else { return }
                history[id, default: []].append(Sample(ts: ts, used: (o["used"] as? NSNumber)?.doubleValue ?? 0,
                                                       resetsAt: (o["resetsAt"] as? NSNumber)?.doubleValue ?? 0))
            }
        }
        for k in history.keys { history[k]!.sort { $0.ts < $1.ts } }
        if !readOnly { rewrite() }   // compact old lines away
    }

    /// Feed observations from any source. The freshest observation per id wins.
    /// One source per window: a lower-ranked source is used only when the better one is >15 min old,
    /// so two sources rounding differently don't write ±1% noise into history.
    func ingest(_ limits: [Limit]) {
        for l in limits.sorted(by: { $0.observedAt < $1.observedAt }) {
            if let c = current[l.id] {
                let better = (LimitStore.rank[c.source] ?? 0) > (LimitStore.rank[l.source] ?? 0)
                if l.observedAt <= c.observedAt { continue }
                if better && l.observedAt - c.observedAt < 900 { continue }
            }
            current[l.id] = l
            recordSample(l)
        }
    }

    private func recordSample(_ l: Limit) {
        var h = history[l.id] ?? []
        if let last = h.last {
            if l.observedAt <= last.ts { return }   // already have this or newer (log replays arrive in order)
            if last.used == l.used && abs(last.resetsAt - l.resetsAt) < 60 && l.observedAt - last.ts < 900 { return }
        }
        h.append(Sample(ts: l.observedAt, used: l.used, resetsAt: l.resetsAt))
        history[l.id] = h
        let line: [String: Any] = ["id": l.id, "ts": l.observedAt, "used": l.used, "resetsAt": l.resetsAt]
        if let d = try? JSONSerialization.data(withJSONObject: line), let s = String(data: d, encoding: .utf8) { pending.append(s) }
    }

    func flush() {
        guard !pending.isEmpty, !readOnly else { pending.removeAll(); return }
        let text = pending.joined(separator: "\n") + "\n"; pending.removeAll()
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(text.data(using: .utf8)!); try? fh.close()
        } else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Runs at init, i.e. before the run loop exists: without its own pool every JSON temporary
    /// (one writer + a 4 KB buffer per line, ~14k lines) would stay alive for the life of the app.
    private func rewrite() {
        autoreleasepool {
            var lines: [String] = []
            for (id, h) in history { for s in h {
                let o: [String: Any] = ["id": id, "ts": s.ts, "used": s.used, "resetsAt": s.resetsAt]
                if let d = try? JSONSerialization.data(withJSONObject: o), let t = String(data: d, encoding: .utf8) { lines.append(t) }
            } }
            try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// What a limit means right now.
struct Insight {
    var limit: Limit
    var used: Double                 // 0 if the window already reset
    var resetIn: Double              // seconds, 0 if unknown/reset
    var stale: Bool                  // window reset since last observation
    var ratePerHour: Double?         // recent burn, %/h
    var rateBasis = ""
    var hitAt: Double?               // projected 100% time, if before reset
    var typicalPerHour: Double?
    var anomaly: Double?             // ratio vs typical when ≥ 2
    var paceDiff: Double?            // weekly: used% − elapsed%
    var perDayLeft: Double?          // weekly: % per remaining day
    var level = 0                    // 0 ok, 1 watch, 2 act now
    var headline = ""                // forecast sentence
    var details: [String] = []

    var minutesToEmpty: Double? { hitAt.map { ($0 - Date().timeIntervalSince1970) / 60 } }
}

func analyze(_ l: Limit, _ hist: [Sample], now: Double) -> Insight {
    var i = Insight(limit: l, used: l.used, resetIn: 0, stale: false)
    if l.resetsAt > 0 && l.resetsAt <= now {
        i.stale = true; i.used = 0; i.headline = ""
        return i
    }
    i.resetIn = l.resetsAt > 0 ? l.resetsAt - now : 0
    if l.used == 0 && l.resetsAt == 0 {
        i.headline = ""
        return i
    }
    let same = hist.filter { l.resetsAt == 0 || abs($0.resetsAt - l.resetsAt) < 600 }

    // Rates from deltas over a fixed lookback (1h for 5h windows, 3h for weekly) to smooth integer steps.
    let look: Double = l.weekly ? 3 * 3600 : 3600
    func usedAt(_ t: Double, _ hs: [Sample]) -> Sample? { hs.last { $0.ts <= t } }
    if let e = same.last, let f = usedAt(now - look, same) ?? same.first(where: { $0.ts >= now - look }),
       e.ts - f.ts >= look / 3 {
        i.ratePerHour = max(0, e.used - f.used) / (e.ts - f.ts) * 3600
        i.rateBasis = l.weekly ? "3 giờ qua" : "1 giờ qua"
    }
    // Typical rate while active: median over 14 days of the same lookback, sampled every half lookback.
    var rates: [Double] = []
    let all = hist.filter { $0.ts >= now - 14 * 86400 }
    if let first = all.first {
        var t = first.ts + look, k = 0, j = 0
        while t <= now - look {
            while k + 1 < all.count && all[k + 1].ts <= t { k += 1 }
            while j + 1 < all.count && all[j + 1].ts <= t - look { j += 1 }
            let b0 = all[j], b1 = all[k]
            if abs(b0.resetsAt - b1.resetsAt) < 600 && b1.used > b0.used && b1.ts - b0.ts >= look / 3 {
                rates.append((b1.used - b0.used) / (b1.ts - b0.ts) * 3600)
            }
            t += look / 2
        }
    }
    if rates.count >= 5 { rates.sort(); i.typicalPerHour = rates[rates.count / 2] }
    if let r = i.ratePerHour, let t = i.typicalPerHour, t > 0, r >= 2 * t, r >= (l.weekly ? 1 : 5) { i.anomaly = r / t }

    var rate = i.ratePerHour ?? 0
    if rate == 0 && l.weekly && l.resetsAt > 0 {
        let start = l.resetsAt - l.windowSec
        if now - start > 3600 { rate = l.used / (now - start) * 3600; i.rateBasis = "trung bình tuần" }
    }
    if l.used >= 100 {
        i.headline = "hết"
    } else if rate > 0 {
        let hit = now + (100 - l.used) / rate * 3600
        if l.resetsAt == 0 || hit < l.resetsAt {
            i.hitAt = hit
            i.headline = "sẽ hết ~\(fmtWhen(hit))"
        } else {
            i.headline = ""
        }
    } else {
        i.headline = ""
    }
    if l.weekly && l.resetsAt > 0 {
        let start = l.resetsAt - l.windowSec
        let elapsedPct = min(100, max(0, (now - start) / l.windowSec * 100))
        i.paceDiff = l.used - elapsedPct
        let days = max(0.1, (l.resetsAt - now) / 86400)
        i.perDayLeft = (100 - l.used) / days
    }
    if let a = i.anomaly { i.details.append(String(format: "tiêu gấp %.1f×", a)) }
    let soon = i.minutesToEmpty.map { $0 < 60 } ?? false
    i.level = (i.used >= 90 || soon) ? 2 : ((i.used >= 70 || i.hitAt != nil || i.anomaly != nil) ? 1 : 0)
    return i
}

/// The limit that will stop you first.
func binding(_ ins: [Insight]) -> Insight? {
    ins.filter { !$0.stale }.max { a, b in
        if a.level != b.level { return a.level < b.level }
        let ta = a.hitAt ?? .infinity, tb = b.hitAt ?? .infinity
        if ta != tb { return ta > tb }
        return a.used < b.used
    }
}
