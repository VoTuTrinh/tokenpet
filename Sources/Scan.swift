// TokenPet — floating usage widget for Claude Code + Codex.
// Reads only local logs (~/.claude/projects, ~/.codex/sessions). No network, no credentials.
import Cocoa
import SwiftUI
import Darwin

// MARK: - Helpers

@inline(__always) func parseISO(_ s: String) -> Double? {
    // "2026-11-10T06:27:50.988Z" (UTC)
    let u = Array(s.utf8)
    guard u.count >= 19 else { return nil }
    func n(_ a: Int, _ b: Int) -> Int32 { var v: Int32 = 0; for i in a..<b { v = v * 10 + Int32(u[i]) - 48 }; return v }
    var t = tm()
    t.tm_year = n(0, 4) - 1900; t.tm_mon = n(5, 7) - 1; t.tm_mday = n(8, 10)
    t.tm_hour = n(11, 13); t.tm_min = n(14, 16); t.tm_sec = n(17, 19)
    var frac = 0.0
    if u.count > 20 && u[19] == 46 {
        var i = 20, scale = 0.1
        while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
    }
    return Double(timegm(&t)) + frac
}

func int(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }

func fmtTok(_ v: Int) -> String {
    let d = Double(v)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0fK", d / 1e3) }
    return "\(v)"
}
func fmtUSD(_ v: Double) -> String { v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
func fmtDur(_ s: Double) -> String {
    let m = Int(max(0, s) / 60)
    if m >= 1440 { return "\(m / 1440)d \((m % 1440) / 60)h" }
    if m >= 60 { return "\(m / 60)h\(String(format: "%02d", m % 60))" }
    return "\(m)m"
}
func fmtClock(_ t: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: t))
}
/// "14:25" if today, otherwise "T5 14:25".
func fmtWhen(_ t: Double) -> String {
    let d = Date(timeIntervalSince1970: t)
    if Calendar.current.isDateInToday(d) { return fmtClock(t) }
    let wd = Calendar.current.component(.weekday, from: d)   // 1 = Sunday
    return (wd == 1 ? "CN" : "T\(wd)") + " " + fmtClock(t)
}
let supportDir: URL = {
    let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TokenPet")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

let cal = Calendar.current
func startOfDay(_ t: Double) -> Double { cal.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970 }

// MARK: - Pricing (API-equivalent estimate, $ per 1M tokens)

struct Price: Codable { var input: Double; var output: Double; var cacheRead: Double }

final class Pricing {
    static let defaults: [String: Price] = [
        "claude-fable-5-2": Price(input: 8, output: 40, cacheRead: 0.20),
        "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1.0),
        "claude-mythos-5-2": Price(input: 8, output: 40, cacheRead: 0.20),
        "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
        "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-8": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-7": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-6": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-5": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4": Price(input: 15, output: 75, cacheRead: 1.50),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.10),
        "claude-sonnet-5": Price(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-4": Price(input: 3, output: 15, cacheRead: 0.30),
        "claude-haiku-5-5": Price(input: 0.10, output: 0.50, cacheRead: 0.01),
        "claude-haiku-4-5": Price(input: 1, output: 5, cacheRead: 0.10),
    ]
    let url: URL
    var table: [String: Price]

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenPet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("pricing.json")
        table = Pricing.defaults
        if let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([String: Price].self, from: d) {
            table = t
        } else {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(table).write(to: url)
        }
    }

    func price(_ model: String) -> Price? {
        let m = model.lowercased()
        var best: (String, Price)?
        for (k, p) in table where m.hasPrefix(k) {
            if best == nil || k.count > best!.0.count { best = (k, p) }
        }
        return best?.1
    }

    /// Cache writes: 1.25x input (5m TTL), 2x input (1h TTL). Fast mode ~2x.
    func cost(_ e: CEvent) -> Double? {
        guard let p = price(e.model) else { return nil }
        var c = Double(e.inp) * p.input + Double(e.out) * p.output + Double(e.cr) * p.cacheRead
            + Double(e.cw5) * p.input * 1.25 + Double(e.cw1) * p.input * 2
        if e.fast { c *= 2 }
        return c / 1e6
    }
}

// MARK: - Events

struct CEvent {
    var ts: Double; var model: String; var project: String
    var inp = 0, out = 0, cw5 = 0, cw1 = 0, cr = 0; var fast = false
    var work: Int { inp + out + cw5 + cw1 }          // tokens excluding cache reads
    var all: Int { work + cr }
}
struct XEvent { var ts: Double; var project: String; var inp: Int; var cached: Int; var out: Int
    var work: Int { inp - cached + out } }

// MARK: - Scanner (incremental, offset-based)

final class Scanner {
    struct FState {
        var offset: UInt64 = 0; var xTotals: [Int] = [0, 0, 0]; var cwd = ""
        var mtime = 0.0                       // last write = last activity of this session
        var burn: [(Double, Int)] = []        // (ts, work tokens) within the last 5h, for per-session burn
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let horizon: Double = 8 * 86400
    var files: [String: FState] = [:]
    var claude: [String: CEvent] = [:]
    var codex: [XEvent] = []
    var newLimits: [Limit] = []           // quota observations from logs/statusline since last drain
    var codexPlan = ""
    var activeDays: Set<Double> = []      // start-of-day of any activity (incl. older file mtimes)
    let claudeRateURL = supportDir.appendingPathComponent("claude-statusline.json")
    private var claudeRateMtime = 0.0

    /// Claude Code passes `rate_limits` to the statusline command; our opt-in tee script saves it here.
    func readClaudeRate() {
        guard let mt = (try? claudeRateURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970, mt != claudeRateMtime,
              let d = try? Data(contentsOf: claudeRateURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rl = o["rate_limits"] as? [String: Any] else { return }
        claudeRateMtime = mt
        for (k, id, label, win) in [("five_hour", "claude.5h", "5 giờ", 5 * 3600.0), ("seven_day", "claude.week", "Tuần · mọi model", 7 * 86400.0)] {
            guard let w = rl[k] as? [String: Any], let u = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            newLimits.append(Limit(id: id, tool: "claude", label: label, used: u, resetsAt: Server.time(w["resets_at"]),
                                   windowSec: win, source: "statusline", observedAt: mt))
        }
    }

    var claudeRoot: String { "\(home)/.claude/projects" }
    var codexRoots: [String] { ["\(home)/.codex/sessions", "\(home)/.codex/archived_sessions"] }
    var watchRoots: [String] { [claudeRoot] + codexRoots }

    /// Full scan walks every log directory (launch, and a slow safety net). With `only`, reads just the files
    /// FSEvents reported as changed, so a steady-state update costs a few stat()s instead of walking ~6k files.
    private var scanNow = 0.0
    func scan(only changed: Set<String>? = nil) {
        let now = Date().timeIntervalSince1970
        scanNow = now
        readClaudeRate()
        if let changed = changed {
            // Only log files under the watched roots; the statusline file and our own history live elsewhere.
            for p in changed where p.hasSuffix(".jsonl") && (p.hasPrefix(claudeRoot) || codexRoots.contains(where: { p.hasPrefix($0) })) {
                let isCodex = !p.hasPrefix(claudeRoot)
                var sb = stat()
                guard stat(p, &sb) == 0 else { continue }
                visit(p, mt: Double(sb.st_mtimespec.tv_sec), size: UInt64(sb.st_size), now: now, codex: isCodex)
            }
        } else {
            walk(claudeRoot, now: now, codex: false)
            for root in codexRoots { walk(root, now: now, codex: true) }
        }
        codex.sort { $0.ts < $1.ts }
        for k in files.keys where !(files[k]!.burn.isEmpty) { files[k]!.burn.removeAll { $0.0 < now - 5 * 3600 } }
        // drop very old data to bound memory
        let cut = now - horizon
        if claude.count > 50_000 { claude = claude.filter { $0.value.ts >= cut } }
        codex.removeAll { $0.ts < cut }
    }

    private func walk(_ root: String, now: Double, codex isCodex: Bool) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return }
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mt = rv.contentModificationDate?.timeIntervalSince1970 else { continue }
            visit(u.path, mt: mt, size: UInt64(rv.fileSize ?? 0), now: now, codex: isCodex)
        }
    }

    private func visit(_ path: String, mt: Double, size: UInt64, now: Double, codex isCodex: Bool) {
        activeDays.insert(startOfDay(mt))
        guard mt >= now - horizon else { return }
        var st = files[path] ?? FState()
        if size < st.offset { st = FState() }   // truncated / rewritten
        st.mtime = mt
        if size > st.offset { read(path, &st, codex: isCodex) }
        files[path] = st
    }

    /// Streams the file from the saved offset in fixed chunks with one reusable buffer, so memory stays flat
    /// no matter how big the log is. Only complete lines are consumed; the offset never passes a partial line.
    /// Lines that can't hold a match are skipped without allocating; matched lines are parsed inside an
    /// autoreleasepool so Foundation temporaries are freed per line, not at the end of the scan.
    private static let chunk = 1 << 20
    private static let maxLine = 32 << 20
    private var buf = [UInt8](repeating: 0, count: Scanner.chunk)
    private func read(_ path: String, _ st: inout FState, codex isCodex: Bool) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let needle: [UInt8] = Array((isCodex ? "\"token_count\"" : "\"usage\"").utf8)
        let metaNeedle: [UInt8] = Array("\"session_meta\"".utf8)
        var fileOff = st.offset
        var have = 0                       // bytes in buf not yet consumed (a partial line carried over)
        var skipping = false               // inside a line longer than the buffer: discard until its newline
        while true {
            if have == buf.count {         // one line fills the buffer: grow (rare, huge assistant message) or give up on it
                if buf.count < Scanner.maxLine { buf += [UInt8](repeating: 0, count: buf.count) }
                else { skipping = true; fileOff += UInt64(have); have = 0 }
            }
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + have, $0.count - have, off_t(fileOff) + off_t(have)) }
            if n <= 0 { break }
            let total = have + n
            var start = 0
            buf.withUnsafeBufferPointer { bp in
                let base = bp.baseAddress!
                while start < total {
                    guard let p = memchr(base + start, 0x0A, total - start) else { break }
                    let end = UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self) - base
                    let len = end - start
                    if skipping { skipping = false }
                    else if len > 0 {
                        let line = base + start
                        let hit = memmem(line, len, needle, needle.count) != nil
                        let meta = isCodex && st.cwd.isEmpty && memmem(line, len, metaNeedle, metaNeedle.count) != nil
                        if hit || meta {
                            autoreleasepool {
                                if let obj = try? JSONSerialization.jsonObject(with: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: len, deallocator: .none)) as? [String: Any] {
                                    if isCodex { handleCodex(obj, &st) } else { handleClaude(obj, &st) }
                                }
                            }
                        }
                    }
                    start = end + 1
                }
            }
            fileOff += UInt64(start)
            have = total - start
            if have > 0 && start > 0 { buf.withUnsafeMutableBytes { _ = memmove($0.baseAddress!, $0.baseAddress! + start, have) } }
            st.offset = fileOff
        }
        if buf.count > Scanner.chunk { buf = [UInt8](repeating: 0, count: Scanner.chunk) }   // give back a grown buffer
    }

    private func handleClaude(_ o: [String: Any], _ st: inout FState) {
        guard (o["type"] as? String) == "assistant",
              let msg = o["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let id = msg["id"] as? String,
              let model = msg["model"] as? String, model != "<synthetic>",
              let tss = o["timestamp"] as? String, let ts = parseISO(tss) else { return }
        let cc = usage["cache_creation"] as? [String: Any]
        let cwTotal = int(usage, "cache_creation_input_tokens")
        var cw1 = int(cc, "ephemeral_1h_input_tokens")
        var cw5 = int(cc, "ephemeral_5m_input_tokens")
        if cc == nil || cw1 + cw5 != cwTotal { cw5 = max(0, cwTotal - cw1); if cw5 + cw1 > cwTotal { cw1 = 0; cw5 = cwTotal } }
        let project = ((o["cwd"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "?"
        if st.cwd.isEmpty { st.cwd = project }
        var e = CEvent(ts: ts, model: model, project: project)
        e.inp = int(usage, "input_tokens"); e.out = int(usage, "output_tokens")
        e.cr = int(usage, "cache_read_input_tokens"); e.cw5 = cw5; e.cw1 = cw1
        e.fast = (usage["speed"] as? String) == "fast"
        // Same message id is written on several lines (one per content block) and copied
        // into resumed/forked sessions. Keep one record per id, max of each field.
        if var old = claude[id] {
            old.inp = max(old.inp, e.inp); old.out = max(old.out, e.out); old.cr = max(old.cr, e.cr)
            old.cw5 = max(old.cw5, e.cw5); old.cw1 = max(old.cw1, e.cw1); old.ts = min(old.ts, e.ts)
            claude[id] = old
        } else {
            claude[id] = e
            if ts >= scanNow - 5 * 3600 { st.burn.append((ts, e.work)) }
        }
    }

    private func handleCodex(_ o: [String: Any], _ st: inout FState) {
        guard let payload = o["payload"] as? [String: Any] else { return }
        let type = o["type"] as? String
        if type == "session_meta" {
            st.cwd = ((payload["cwd"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "?"
            return
        }
        guard type == "event_msg", (payload["type"] as? String) == "token_count",
              let tss = o["timestamp"] as? String, let ts = parseISO(tss) else { return }
        // total_token_usage is cumulative per session -> take deltas.
        if let info = payload["info"] as? [String: Any], let tot = info["total_token_usage"] as? [String: Any] {
            let cur = [int(tot, "input_tokens"), int(tot, "cached_input_tokens"), int(tot, "output_tokens")]
            var d = zip(cur, st.xTotals).map { $0 - $1 }
            if d.contains(where: { $0 < 0 }) { d = cur }   // session counter reset
            if d.contains(where: { $0 > 0 }) {
                let x = XEvent(ts: ts, project: st.cwd.isEmpty ? "?" : st.cwd, inp: d[0], cached: d[1], out: d[2])
                codex.append(x)
                if ts >= scanNow - 5 * 3600 { st.burn.append((ts, x.work)) }
            }
            st.xTotals = cur
        }
        if let rl = payload["rate_limits"] as? [String: Any] {
            let lid = (rl["limit_id"] as? String) ?? "codex"
            if let p = rl["plan_type"] as? String { codexPlan = p }
            let prefix = lid == "codex" ? "codex" : "codex.\(lid)"
            let name = lid == "codex" ? "" : "\(lid.capitalized) · "
            for k in ["primary", "secondary"] {
                guard let w = rl[k] as? [String: Any], let u = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let mins = Double(int(w, "window_minutes"))
                let win = mins > 0 ? mins * 60 : (k == "primary" ? 18000 : 604800)
                let isWeek = win >= 86400
                newLimits.append(Limit(id: "\(prefix).\(isWeek ? "week" : "5h")", tool: "codex",
                                       label: name + (isWeek ? "Tuần" : "5 giờ"), used: u,
                                       resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue ?? 0,
                                       windowSec: win, source: "log", observedAt: ts))
            }
        }
    }
}

