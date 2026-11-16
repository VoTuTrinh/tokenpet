// The compact view shared by the notch, the edge dock and the menu bar popover. Exactly what the user asked for
// and nothing else: per tool, how much of 5h and of the week is used and when each resets (day + time).
// No forecasts here; those only drive notifications.
import SwiftUI

struct ToolSummary {
    var name: String; var tool: String; var color: Color
    var tight: Insight?; var mood: Mood; var running: Int
    var kind: PetKind = .blob
    var line: String              // forecast if it matters, otherwise reset countdown
    var lineIsWarning: Bool
}

extension Model {
    func summary(_ tool: String) -> ToolSummary {
        let ins = insights(tool)
        let b = binding(ins)
        let now = Date().timeIntervalSince1970
        let ss = sessions.filter { $0.tool == tool }
        let run = ss.filter { $0.running }.count
        let idle = now - (ss.map { $0.lastActive }.max() ?? 0)
        var line = L("no data yet", "chưa có dữ liệu"), warn = false
        if let b = b {
            if !b.headline.isEmpty { line = b.headline; warn = b.level >= 1 }
            else if b.resetIn > 0 { line = "↻ \(fmtDur(b.resetIn))" }
            else { line = "" }
        }
        return ToolSummary(name: tool == "claude" ? "Claude" : "Codex", tool: tool, color: tool == "claude" ? claudeColor : codexColor,
                           tight: b, mood: mood(ins, running: run > 0, idleFor: idle), running: run, kind: Prefs.shared.kind(tool), line: line, lineIsWarning: warn)
    }
    /// The single most urgent thing, for the closed notch / menu bar.
    var worst: ToolSummary? {
        Prefs.shared.tools.map { summary($0) }.filter { $0.tight != nil }
            .max { ($0.tight!.level, $0.tight!.used) < ($1.tight!.level, $1.tight!.used) }
    }
}

/// One tool as a card: the mascot (ring = tightest limit) on the left, one stat tile per quota window on the
/// right: "5 giờ", "Tuần · mọi model", "Tuần · Fable" — % used, a thin bar, and the exact reset time.
struct ToolCardView: View {
    var s: ToolSummary
    var rows: [Insight]
    var animate: Bool
    var showPet: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 4) {
                PetRing(color: s.color, used: s.tight?.used, level: s.tight?.level ?? 0, mood: s.mood, animate: animate, size: 46, showPet: showPet, kind: s.kind)
                Text(s.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                if s.running > 0 {
                    Text(L("\(s.running) running", "\(s.running) đang chạy")).font(.system(size: 9, weight: .medium)).foregroundStyle(s.color).lineLimit(1)
                        .help(L("\(s.running) \(s.name) \(s.running == 1 ? "session" : "sessions") working; listed just below", "\(s.running) session \(s.name) đang làm việc; danh sách ở ngay dưới"))
                }
            }
            .frame(width: 66)
            if rows.isEmpty {
                // Empty invites the next step: Claude needs a source switched on, Codex only needs to be used once.
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.tool == "claude" ? L("No quota numbers yet", "Chưa có số quota") : L("No data yet", "Chưa có dữ liệu")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    if s.tool == "claude" {
                        Button { AppDelegate.shared?.openSettings() } label: {
                            Text(L("Pick a source in Settings › Data ›", "Chọn nguồn trong Cài đặt › Dữ liệu ›")).font(.system(size: 10, weight: .medium)).foregroundStyle(s.color)
                        }.buttonStyle(.plain)
                    } else {
                        Text(L("Numbers appear after the next Codex run", "Số sẽ hiện sau lần chạy Codex tiếp theo")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(rows.indices, id: \.self) { k in StatTile(i: rows[k], color: s.color) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(CardGlow(tint: s.tight.map { $0.level == 0 ? s.color : levelColor($0.level) } ?? s.color))
    }
}

/// `Week · all models` / `62% used` / bar / `resets Fri 14:20 · in 4d 12h` / `on pace`
struct StatTile: View {
    var i: Insight
    var color: Color
    var body: some View {
        let c = i.level == 0 ? color : levelColor(i.level)
        VStack(alignment: .leading, spacing: 3) {
            Text(i.limit.label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(i.used.rounded()))%").font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(i.level == 0 ? .white : c)
                Text(L("used", "đã dùng")).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(c).frame(width: max(3, g.size.width * min(1, i.used / 100)))
                    if let p = i.paceDiff, !i.stale {   // tick: where an even weekly pace would be
                        Rectangle().fill(Color.white.opacity(0.7)).frame(width: 1.5, height: 7)
                            .offset(x: g.size.width * min(1, max(0, (i.used - p) / 100)))
                    }
                }
            }.frame(height: 4)
            .help(i.paceDiff != nil ? L("The tick marks where an even pace through the week would be now.", "Vạch là vị trí của nhịp dùng đều trong tuần tính tới lúc này.") : "")
            Text(resetText).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).monospacedDigit().lineLimit(1)
                .padding(.top, 3)
            if let v = verdict {
                Text(v.0).font(.system(size: 9, weight: .semibold)).foregroundStyle(v.1).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// When exactly it resets (day + time), and how long that is from now.
    var resetText: String {
        if i.used == 0 && (i.stale || i.limit.resetsAt == 0) { return L("unused", "chưa dùng") }
        if i.stale { return L("has reset", "đã reset") }
        guard i.resetIn > 0 else { return "" }
        return L("resets \(fmtWhen(i.limit.resetsAt)) · in \(fmtDur(i.resetIn))", "reset \(fmtWhen(i.limit.resetsAt)) · còn \(fmtDur(i.resetIn))")
    }
    /// The answer the bar alone does not give: will this last until the reset?
    var verdict: (String, Color)? {
        guard !i.stale, i.limit.resetsAt > 0, i.used > 0 else { return nil }
        let quiet = Color.white.opacity(0.45)
        if i.used >= 100 { return (L("out until the reset", "hết, chờ reset"), levelColor(2)) }
        if let m = i.minutesToEmpty, m > 0 { return (L("runs out in ~\(fmtDur(m * 60))", "sẽ hết sau ~\(fmtDur(m * 60))"), levelColor(max(1, i.level))) }
        if let p = i.paceDiff { return p > 5 ? (L("\(Int(p.rounded()))% ahead of an even pace", "nhanh hơn nhịp đều \(Int(p.rounded()))%"), Color.white.opacity(0.7)) : (L("on pace", "đúng nhịp"), quiet) }
        if i.ratePerHour != nil { return (L("lasts until the reset", "đủ dùng tới reset"), quiet) }
        return nil
    }
}

extension Model {
    /// The two numbers that matter: the plain 5h and weekly windows. Everything else (per-model weeks,
    /// Codex's Spark limits) is detail.
    func mainRows(_ tool: String) -> [Insight] {
        let ins = insights(tool)
        guard !ins.isEmpty else { return [] }
        return [("\(tool).5h", L("5 hours", "5 giờ"), 5 * 3600.0), ("\(tool).week", L("Week", "Tuần"), 7 * 86400.0)].map { id, label, win in
            // Claude Code and both servers omit a window until it has been used: missing = 0%.
            ins.first { $0.limit.id == id } ?? Insight(limit: Limit(id: id, tool: tool, label: label, used: 0, resetsAt: 0, windowSec: win, source: "none", observedAt: 0), used: 0, resetIn: 0, stale: false)
        }
    }
    func detailRows(_ tool: String) -> [Insight] { insights(tool).filter { $0.limit.id != "\(tool).5h" && $0.limit.id != "\(tool).week" } }
}

struct GlanceView: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    var animate: Bool
    var forceDetails: Bool? = nil     // --snapshot
    @State private var showDetails = false     // always collapsed when the glance opens; not remembered

    var body: some View {
        let openD = forceDetails ?? showDetails
        VStack(alignment: .leading, spacing: 8) {
            if prefs.tools.isEmpty {
                Text(L("No tools enabled. Turn on Claude or Codex in Settings.", "Chưa bật công cụ nào. Bật Claude hoặc Codex trong Cài đặt.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(12)
            }
            ForEach(prefs.tools, id: \.self) { tool in
                ToolCardView(s: model.summary(tool), rows: model.mainRows(tool), animate: animate, showPet: prefs.pet)
            }
            // Quota detail folds out right under the quota cards, before the machine card, so it reads as one block.
            if !prefs.tools.isEmpty {
                Button(action: {
                    withAnimation(prefs.transitions ? .spring(response: 0.3, dampingFraction: 0.85) : nil) { showDetails.toggle() }
                    model.statsWanted = prefs.floating || showDetails
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: openD ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        Text(L("Quota details", "Chi tiết quota"))
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 12)
                if openD { details.padding(.horizontal, 12).padding(.bottom, 4) }
            }
            MachineCard(model: model)
            HStack(spacing: 6) {
                // How fresh the numbers are, and a way to ask again: a quota figure with no age cannot be trusted.
                if let t = model.insights.map({ $0.limit.observedAt }).max(), t > 0 {
                    let age = Date().timeIntervalSince1970 - t
                    Text(age < 90 ? L("Updated just now", "Vừa cập nhật") : L("Updated \(fmtAge(age)) ago", "Cập nhật \(fmtAge(age)) trước"))
                }
                Button(action: { model.refresh(userInitiated: true) }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help(L("Refresh now", "Làm mới ngay"))
                Spacer()
                Button(action: { AppDelegate.shared?.openSettings() }) {
                    Label(L("Settings", "Cài đặt"), systemImage: "gearshape")
                }.buttonStyle(.plain).labelStyle(.titleAndIcon)
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 12)
        }
        .environment(\.colorScheme, .dark)
    }

    /// "Label: value" as a row with the value on the right, so a column of facts lines up instead of reading as prose.
    func fact(_ e: String) -> some View {
        let parts = e.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(parts.first ?? e).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 4)
            if parts.count > 1 { Text(parts[1]).foregroundStyle(.white.opacity(0.9)).monospacedDigit().multilineTextAlignment(.trailing) }
        }.font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
    }
    /// Detail: per-model weeks and extra limits as rows, what the servers add (extra usage, where the week went,
    /// credits), and today's tokens / API-equivalent $ when the stats are built.
    @ViewBuilder var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(prefs.tools, id: \.self) { tool in
                let rows = model.detailRows(tool)
                let extra = tool == "claude" ? model.claudeSrv.extra : model.codexSrv.extra
                if !rows.isEmpty || !extra.isEmpty {
                    Text(tool == "claude" ? "CLAUDE" : "CODEX").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tool == "claude" ? claudeColor : codexColor).padding(.top, 2)
                    ForEach(rows.indices, id: \.self) { k in DetailRow(i: rows[k], color: tool == "claude" ? claudeColor : codexColor) }
                    ForEach(extra, id: \.self) { e in fact(e) }
                }
            }
            if model.stats.ready {
                let st = model.stats
                Text(L("LAST 24 HOURS", "24 GIỜ QUA")).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
                if st.c24hTok > 0 { fact(L("Claude: \(fmtTok(st.c24hTok)) tokens · ~\(fmtUSD(st.c24hUSD)) at API prices", "Claude: \(fmtTok(st.c24hTok)) token · ~\(fmtUSD(st.c24hUSD)) theo giá API")) }
                if st.x24hTok > 0 { fact(L("Codex: \(fmtTok(st.x24hTok)) tokens", "Codex: \(fmtTok(st.x24hTok)) token")) }
                if st.c24hTok == 0 && st.x24hTok == 0 { fact(L("No tokens used", "Chưa dùng token nào")) }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Máy: shared pieces for the glance card, the window and the toast

struct MachineGroup {
    var label: String; var unit: String; var mb: Double; var n: Int; var color: Color
    /// "5 sessions" / "1 process"; Vietnamese has no plural.
    var countText: String { L(enCount(n, unit), "\(n) \(unit)") }
    /// One meaning per colour, everywhere: green is in use, grey is open but quiet, orange is asleep (worth
    /// closing), purple is a process nobody owns any more.
    static let running = Color.green, awake = Color.gray, asleep = Color.orange, leftover = Color.purple
}
/// English count with a plural: "1 session", "3 sessions", "2 processes".
func enCount(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)\(word.hasSuffix("s") ? "es" : "s")" }

/// One row shape for both kinds of thing: a session or a leftover process. Grouped by what to do about it.
struct MachineItem: Identifiable {
    var id: pid_t
    var isSession: Bool
    var title: String          // session name, or the typed command
    var kind: String           // "Claude Code · cmux ttys005" / "Next.js dev server · kitemetric-web"
    var status: String         // "ngủ 16h" / "đang chạy · pytest 98%" / "project còn session mở"
    var cleanable: Bool        // in the "Nên dọn" group
    var mb: Double
    var session: AgentSession? = nil
    var leftover: Leftover? = nil
    var color: Color { isSession ? (session?.tool == "codex" ? codexColor : claudeColor) : Color.gray }
}

extension MachineState {
    /// The pet's face for the machine: alarmed at critical pressure, worried under pressure, busy while agents run.
    var mood: Mood {
        if pressure >= 4 { return .alarmed }
        if heavy { return .worried }
        return busy.isEmpty ? .calm : .busy
    }
    /// "46% RAM máy · còn 9% · swap 14.5 GB"
    var verdict: String {
        let pct = Int((aiMB / max(1, ramGB * 1024) * 100).rounded())
        var t = L("\(pct)% of this Mac's RAM · memory pressure \(pressureWord)", "\(pct)% RAM máy · áp lực bộ nhớ \(pressureWord)")
        if swapUsedGB >= 0.5 { t += String(format: " · swap %.1f GB", swapUsedGB) }
        return t
    }
    /// The kernel's own verdict in a word. Free percent alone misleads: macOS keeps RAM full on purpose.
    var pressureWord: String { pressure >= 4 ? L("critical", "nguy cấp") : (heavy ? L("high", "cao") : L("normal", "bình thường")) }
    /// Why the machine feels slow, in the kernel's terms but plain words.
    var pressureText: String {
        if pressure >= 4 { return L("This Mac is out of RAM.", "Máy hết RAM.") }
        if swapUsedGB >= 4 { return String(format: L("This Mac is pushing %.1f GB out to swap.", "Máy đang phải đẩy %.1f GB ra swap."), swapUsedGB) }
        return L("This Mac is under memory pressure.", "Máy đang bị áp lực RAM.")
    }
    /// One sentence that says what to do.
    func advice(_ hours: Double) -> String {
        let c = cleanable(hours)
        if sessions.isEmpty && leftovers.isEmpty { return L("No agent processes running.", "Không có process AI nào đang chạy.") }
        if c.mb == 0 { return heavy ? pressureText + L(" Nothing from the agents is worth closing: other apps are using the RAM.", " AI không có gì đáng dọn: thứ đang ăn RAM là app khác.") : L("Everything is in use, nothing worth closing.", "Mọi thứ đang được dùng, không có gì đáng dọn.") }
        var what: [String] = []
        if !c.sessions.isEmpty { what.append(L(enCount(c.sessions.count, "asleep session"), "\(c.sessions.count) session ngủ")) }
        if !c.leftovers.isEmpty { what.append(L(enCount(c.leftovers.count, "leftover process"), "\(c.leftovers.count) process bỏ quên")) }
        return (heavy ? pressureText + " " : "") + L("Close \(what.joined(separator: " and ")) to get back \(fmtMB(c.mb)).", "Đóng \(what.joined(separator: " và ")) để lấy lại \(fmtMB(c.mb)).")
    }
    func groups(_ hours: Double) -> [MachineGroup] {
        let b = busy, i = idle(hours)
        let a = sessions.filter { !$0.busy && !$0.isIdle(hours) }
        return [MachineGroup(label: L("Running", "Đang chạy"), unit: "session", mb: b.reduce(0) { $0 + $1.footprintMB }, n: b.count, color: MachineGroup.running),
                MachineGroup(label: L("Open, awake", "Mở, chưa ngủ"), unit: "session", mb: a.reduce(0) { $0 + $1.footprintMB }, n: a.count, color: MachineGroup.awake),
                MachineGroup(label: L("Asleep ≥ \(Int(hours))h", "Ngủ ≥ \(Int(hours))h"), unit: "session", mb: i.reduce(0) { $0 + $1.footprintMB }, n: i.count, color: MachineGroup.asleep),
                MachineGroup(label: L("Leftover", "Bỏ quên"), unit: "process", mb: leftovers.reduce(0) { $0 + $1.footprintMB }, n: leftovers.count, color: MachineGroup.leftover)]
    }
    /// Everything as rows in three groups: "Nên dọn" (safe), "Cân nhắc" (the user's call), "Đang chạy" (leave alone).
    /// The members of one stat column (0 running, 1 awake, 2 idle, 3 leftovers), as (title, detail, MB).
    func groupItems(_ k: Int, hours: Double) -> [(String, String, Double)] {
        let ss: [AgentSession]
        switch k {
        case 0: ss = busy
        case 1: ss = sessions.filter { !$0.busy && !$0.isIdle(hours) }
        case 2: ss = idle(hours)
        default: return leftovers.sorted { $0.footprintMB > $1.footprintMB }.map { ($0.command, [$0.kind, $0.byAgent ? L("started by an agent", "do agent chạy") : $0.project, fmtAge($0.age)].filter { !$0.isEmpty }.joined(separator: " · "), $0.footprintMB) }
        }
        return ss.sorted { $0.footprintMB > $1.footprintMB }.map { s in
            let where_ = [s.host, s.tty].filter { !$0.isEmpty }.joined(separator: " ")
            let st = s.busy ? L("running", "đang chạy") + (s.busyWith.isEmpty ? "" : " · \(s.busyWith)")
                            : (s.isIdle(hours) ? L("asleep \(fmtAge(s.idleFor))", "ngủ \(fmtAge(s.idleFor))") : L("quiet for \(fmtAge(s.idleFor))", "yên \(fmtAge(s.idleFor))"))
            return (s.name, [st, s.project, where_].filter { !$0.isEmpty }.joined(separator: " · "), s.footprintMB)
        }
    }
    func items(_ hours: Double) -> (clean: [MachineItem], review: [MachineItem], running: [MachineItem]) {
        var clean: [MachineItem] = [], review: [MachineItem] = [], running: [MachineItem] = []
        for s in sessions {
            let kind = (s.tool == "claude" ? "Claude Code" : "Codex") + (s.project.isEmpty ? "" : " · \(s.project)")
            let idle = s.isIdle(hours)
            let status = s.busy ? L("running", "đang chạy") + (s.busyWith.isEmpty ? "" : " \(s.busyWith)")
                                : (idle ? L("asleep \(fmtAge(s.idleFor))", "ngủ \(fmtAge(s.idleFor))") : L("quiet for \(fmtAge(s.idleFor))", "yên \(fmtAge(s.idleFor))"))
            let it = MachineItem(id: s.id, isSession: true, title: s.name, kind: kind, status: status, cleanable: idle, mb: s.footprintMB, session: s)
            if s.busy { running.append(it) } else if idle { clean.append(it) } else { review.append(it) }
        }
        for l in leftovers {
            let port = l.ports.isEmpty ? "" : L(l.ports.count == 1 ? "port " : "ports ", "cổng ") + l.ports.map(String.init).joined(separator: ", ")
            let kind = [l.kind, l.byAgent ? L("started by an agent", "do agent chạy") : l.project, port].filter { !$0.isEmpty }.joined(separator: " · ")
            let status = l.projectLive ? L("running \(fmtAge(l.age)) · its project still has a session", "chạy \(fmtAge(l.age)) · project còn session mở") : L("leftover \(fmtAge(l.age))", "bỏ quên \(fmtAge(l.age))")
            let it = MachineItem(id: l.id, isSession: false, title: l.command, kind: kind, status: status, cleanable: !l.projectLive, mb: l.footprintMB, leftover: l)
            if l.projectLive { review.append(it) } else { clean.append(it) }
        }
        clean.sort { $0.mb > $1.mb }; review.sort { $0.mb > $1.mb }; running.sort { $0.mb > $1.mb }
        return (clean, review, running)
    }
    /// Why it adds up: the patterns behind the number, at most two lines.
    var insights: [String] {
        var out: [String] = []
        var perProject: [String: Int] = [:]
        for s in sessions { perProject[s.project, default: 0] += 1 }
        if let (proj, n) = perProject.max(by: { $0.value < $1.value }), n >= 3 {
            out.append(L("\(n) sessions are open on project \(proj): each one carries its own MCP servers and LSP.", "\(n) session cùng mở project \(proj): mỗi session mang MCP server và LSP riêng của nó."))
        }
        var dup: [String: (Int, Double)] = [:]
        for s in sessions { for (name, mb) in s.members.dropFirst() where !ProcessCensus.shells.contains(name) { let c = dup[name] ?? (0, 0); dup[name] = (c.0 + 1, c.1 + mb) } }
        if let (name, c) = dup.max(by: { $0.value.0 < $1.value.0 }), c.0 >= 3 {
            out.append(L("\(c.0) identical copies of \(name), one per session · \(fmtMB(c.1)).", "\(c.0) bản \(name) giống nhau, một bản cho mỗi session · \(fmtMB(c.1))."))
        }
        if let top = others.first, top.footprintMB > aiMB {
            out.append(L("A single \(top.name) process holds \(fmtMB(top.footprintMB)), more than all the agents together.", "Riêng một process của \(top.name) đã giữ \(fmtMB(top.footprintMB)), nhiều hơn toàn bộ AI."))
        }
        return Array(out.prefix(2))
    }
}

/// AI's share of physical RAM, one segment per group, on a track that is the whole machine. Hover a segment
/// for "Mở, chưa ngủ · 4.0 GB · 12 session"; `selected` dims the others.
struct ShareBar: View {
    var groups: [MachineGroup]
    var ramMB: Double
    var dark: Bool
    var height: CGFloat = 6
    var selected: Int? = nil
    var onTap: ((Int) -> Void)? = nil
    @State private var hovered: Int? = nil
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(groups.indices, id: \.self) { k in
                    let gr = groups[k]
                    let w = max(0, g.size.width * CGFloat(min(1, gr.mb / max(1, ramMB))))
                    if w > 0 {
                        Rectangle().fill(gr.color)
                            .opacity((selected != nil && selected != k) ? 0.35 : (hovered == k ? 1 : 0.9))
                            .frame(width: w)
                            .help("\(gr.label) · \(fmtMB(gr.mb)) · \(gr.countText)")
                            .onHover { hovered = $0 ? k : (hovered == k ? nil : hovered) }
                            .onTapGesture { onTap?(k) }
                    }
                }
                Spacer(minLength: 0)
            }
            .background(dark ? Color.white.opacity(0.1) : Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }.frame(height: height)
    }
}

/// `● Ngủ ≥ 2h` / `3.1 GB` / `5 session`: the same shape as the quota stat tiles.
struct MachineStat: View {
    var g: MachineGroup
    var dark: Bool
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(g.color).frame(width: 6, height: 6)
                Text(g.label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(dark ? Color.white.opacity(0.55) : Color.secondary).lineLimit(1)
            }
            Text(g.n > 0 ? fmtMB(g.mb) : "—").font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(dark ? (g.n > 0 ? Color.white : Color.white.opacity(0.4)) : (g.n > 0 ? Color.primary : Color.secondary))
            Text(g.n > 0 ? g.countText : L("none", "không có")).font(.system(size: 9)).foregroundStyle(dark ? Color.white.opacity(0.45) : Color.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? (dark ? Color.white.opacity(0.1) : Color.primary.opacity(0.08)) : Color.clear))
        .contentShape(Rectangle())
    }
}

/// The third card in the glance, under the two quota cards: what AI tooling holds, in one look. The whole card
/// is the click target (a hover panel is a bad place for small tabs); it opens the Máy window for the detail
/// and the buttons. Ring on the left = AI's share of RAM, coloured by memory pressure.
struct MachineCard: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    @State private var hover = false
    var body: some View {
        let m = model.machine
        let c = m.cleanable(prefs.idleHours)
        let share = m.aiMB / max(1, m.ramGB * 1024)
        let level = m.pressure >= 4 ? 2 : (m.heavy ? 1 : 0)
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.16), lineWidth: 4)
                    Circle().trim(from: 0, to: CGFloat(min(1, share)))
                        .stroke(level == 0 ? Color.white.opacity(0.75) : levelColor(level), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((share * 100).rounded()))%").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                }.frame(width: 46, height: 46)
                Text(L("Mac", "Máy")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 66)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.sessions.isEmpty && m.leftovers.isEmpty ? L("No agents running", "AI không chạy") : L("Agents hold \(fmtMB(m.aiMB))", "AI đang giữ \(fmtMB(m.aiMB))"))
                        .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Spacer(minLength: 6)
                    Text(L("pressure \(m.pressureWord)", "áp lực \(m.pressureWord)") + (m.swapUsedGB >= 0.5 ? String(format: " · swap %.1f GB", m.swapUsedGB) : ""))
                        .font(.system(size: 9)).foregroundStyle(level > 0 ? levelColor(level) : .white.opacity(0.5)).monospacedDigit().lineLimit(1)
                }
                ShareBar(groups: m.groups(prefs.idleHours), ramMB: m.ramGB * 1024, dark: true, height: 4)
                Text(summary(m, c: c)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                HStack(spacing: 3) {
                    Text(c.mb > 0 ? L("Review & free · get back \(fmtMB(c.mb))", "Xem & dọn · lấy lại \(fmtMB(c.mb))") : L("View details", "Xem chi tiết"))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(c.mb > 0 ? Color.orange : .white.opacity(0.7))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(c.mb > 0 ? Color.orange : .white.opacity(0.7))
                    Spacer()
                    Text("⌃⌥M").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(CardGlow(tint: m.heavy ? .orange : claudeColor, lift: hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { AppDelegate.shared?.openMachine() }
        .help(L("Memory held by Claude Code / Codex, their child processes and leftover processes. Click for details and to free it.", "Bộ nhớ mà Claude Code / Codex, process con và process bỏ quên đang giữ. Bấm để xem chi tiết và dọn."))
    }
    /// "13 session · 5 ngủ ≥ 2h · 6 process bỏ quên" or "2 đang chạy · 3 mở"
    func summary(_ m: MachineState, c: (sessions: [AgentSession], leftovers: [Leftover], mb: Double)) -> String {
        if m.sessions.isEmpty && m.leftovers.isEmpty { return L("No Claude Code / Codex processes.", "Không có process Claude Code / Codex nào.") }
        var parts: [String] = []
        let b = m.busy.count
        if b > 0 { parts.append(L("\(b) running", "\(b) đang chạy")) }
        let idle = m.idle(prefs.idleHours).count
        let awake = m.sessions.count - b - idle
        if awake > 0 { parts.append(L("\(awake) open", "\(awake) mở")) }
        if idle > 0 { parts.append(L("\(idle) asleep ≥ \(Int(prefs.idleHours))h", "\(idle) ngủ ≥ \(Int(prefs.idleHours))h")) }
        if !m.leftovers.isEmpty { parts.append(L("\(m.leftovers.count) leftover", "\(m.leftovers.count) bỏ quên")) }
        return ([L(enCount(m.sessions.count, "session"), "\(m.sessions.count) session")] + parts).joined(separator: " · ")
    }
}

/// `Tuần · Fable   ↻ CN 00:05 · 3d 0h   12%` with a thin bar under it.
struct DetailRow: View {
    var i: Insight
    var color: Color
    var body: some View {
        let c = i.level == 0 ? color : levelColor(i.level)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(i.limit.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 4)
                Text(i.resetIn > 0 ? L("resets \(fmtWhen(i.limit.resetsAt)) · in \(fmtDur(i.resetIn))", "reset \(fmtWhen(i.limit.resetsAt)) · còn \(fmtDur(i.resetIn))") : "")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                Text("\(Int(i.used.rounded()))%").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(i.level == 0 ? .white : c).frame(width: 34, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(c).frame(width: max(3, g.size.width * min(1, i.used / 100)))
                }
            }.frame(height: 3)
        }
    }
}

struct SessionRow: View {
    var s: SessionInfo
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(s.tool == "claude" ? claudeColor : codexColor).frame(width: 6, height: 6)
            Text(s.project).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if s.subagents > 0 {
                Text("+\(s.subagents) sub").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text(s.tokPerHour > 0 ? "\(fmtTok(Int(s.tokPerHour)))/h" : "").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

func fmtMB(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB" }

/// Shapes follow the system: continuous corners, and an inner radius that is the outer one minus the padding
/// between them (26 − 14 = 12), so cards sit concentric inside the panel that holds them.
enum Surface {
    static let panelRadius: CGFloat = 26, cardRadius: CGFloat = 12
    static var flat = false       // --snapshot: no window server, so no glass
}

extension View {
    /// A panel floating over the desktop (menu bar panel, edge card, low-memory card): the system's own glass on
    /// macOS 26 and later, darkened so white text keeps its contrast over any window; opaque black before that.
    /// The notch panel never uses this: it has to stay the black of the hardware notch.
    @ViewBuilder func floatingSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: Surface.panelRadius, style: .continuous)
        if #available(macOS 26.0, *), !Surface.flat {
            self.glassEffect(.regular.tint(Color.black.opacity(0.68)), in: shape)
        } else {
            self.background(shape.fill(Color.black.opacity(0.94))).overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }
}

/// Card surface, content layer: a plain fill with the card's own colour falling in from the top right corner, so
/// each card says whose it is and how it is doing before any text is read. No glass here (HIG, Materials: "Don't
/// use Liquid Glass in the content layer"); only the panel that holds the cards is glass. Static, one draw.
struct CardGlow: View {
    var tint: Color
    var lift = false
    var radius: CGFloat = Surface.cardRadius
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        GeometryReader { g in
            ZStack {
                Color.white.opacity(lift ? 0.1 : 0.06)
                RadialGradient(colors: [tint.opacity(0.26), tint.opacity(0.08), .clear],
                               center: UnitPoint(x: 0.88, y: 0.0), startRadius: 0, endRadius: max(g.size.width * 0.6, 120))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}
