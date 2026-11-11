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
        var line = "chưa có dữ liệu", warn = false
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
                    Text("\(s.running) đang chạy").font(.system(size: 9, weight: .medium)).foregroundStyle(s.color).lineLimit(1)
                        .help("\(s.running) session \(s.name) đang làm việc; danh sách ở ngay dưới")
                }
            }
            .frame(width: 66)
            if rows.isEmpty {
                Text("chưa có dữ liệu").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(rows.indices, id: \.self) { k in StatTile(i: rows[k], color: s.color) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

/// `Tuần · mọi model` / `62%` / bar / `↻ T6 14:20 · 4d 12h`
struct StatTile: View {
    var i: Insight
    var color: Color
    var body: some View {
        let c = i.level == 0 ? color : levelColor(i.level)
        VStack(alignment: .leading, spacing: 3) {
            Text(i.limit.label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Text("\(Int(i.used.rounded()))%").font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(i.level == 0 ? .white : c)
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
            Text(resetText).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).monospacedDigit().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// When exactly it resets (day + time), and how long that is from now.
    var resetText: String {
        if i.used == 0 && (i.stale || i.limit.resetsAt == 0) { return "chưa dùng" }
        if i.stale { return "đã reset" }
        guard i.resetIn > 0 else { return "" }
        return "↻ \(fmtWhen(i.limit.resetsAt)) · \(fmtDur(i.resetIn))"
    }
}

extension Model {
    /// The two numbers that matter: the plain 5h and weekly windows. Everything else (per-model weeks,
    /// Codex's Spark limits) is detail.
    func mainRows(_ tool: String) -> [Insight] {
        let ins = insights(tool)
        guard !ins.isEmpty else { return [] }
        return [("\(tool).5h", "5 giờ", 5 * 3600.0), ("\(tool).week", "Tuần", 7 * 86400.0)].map { id, label, win in
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
                Text("Chưa bật công cụ nào. Bật Claude hoặc Codex trong Cài đặt.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(12)
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
                        Text(openD ? "Thu gọn" : "Chi tiết quota")
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 12)
                if openD { details.padding(.horizontal, 12).padding(.bottom, 4) }
            }
            MachineCard(model: model)
            HStack {
                Spacer()
                Button(action: { AppDelegate.shared?.openSettings() }) {
                    Label("Cài đặt", systemImage: "gearshape")
                }.buttonStyle(.plain).labelStyle(.titleAndIcon).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 12)
        }
        .environment(\.colorScheme, .dark)
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
                    ForEach(extra, id: \.self) { e in
                        Text(e).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.stats.ready {
                let st = model.stats
                Text("24 giờ qua: Claude \(fmtTok(st.c24hTok)) tok (~\(fmtUSD(st.c24hUSD)) giá API) · Codex \(fmtTok(st.x24hTok)) tok")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).padding(.top, 2)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Máy: shared pieces for the glance card, the window and the toast

struct MachineGroup { var label: String; var unit: String; var mb: Double; var n: Int; var color: Color }

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
        var t = "\(pct)% RAM máy · RAM còn \(freePct)%"
        if swapUsedGB >= 0.5 { t += String(format: " · swap %.1f GB", swapUsedGB) }
        return t
    }
    /// Why the machine feels slow, in the kernel's terms but plain words.
    var pressureText: String {
        if pressure >= 4 { return "Máy hết RAM." }
        if swapUsedGB >= 4 { return String(format: "Máy đang phải đẩy %.0f GB ra swap.", swapUsedGB) }
        return "Máy đang bị áp lực RAM."
    }
    /// One sentence that says what to do.
    func advice(_ hours: Double) -> String {
        let c = cleanable(hours)
        if sessions.isEmpty && leftovers.isEmpty { return "Không có process AI nào đang chạy." }
        if c.mb == 0 { return heavy ? pressureText + " AI không có gì đáng dọn: thứ đang ăn RAM là app khác." : "Mọi thứ đang được dùng, không có gì đáng dọn." }
        var what: [String] = []
        if !c.sessions.isEmpty { what.append("\(c.sessions.count) session ngủ") }
        if !c.leftovers.isEmpty { what.append("\(c.leftovers.count) process bỏ quên") }
        return (heavy ? pressureText + " " : "") + "Đóng \(what.joined(separator: " và ")) để lấy lại \(fmtMB(c.mb))."
    }
    func groups(_ hours: Double) -> [MachineGroup] {
        let b = busy, i = idle(hours)
        let a = sessions.filter { !$0.busy && !$0.isIdle(hours) }
        return [MachineGroup(label: "Đang chạy", unit: "session", mb: b.reduce(0) { $0 + $1.footprintMB }, n: b.count, color: claudeColor),
                MachineGroup(label: "Mở, chưa ngủ", unit: "session", mb: a.reduce(0) { $0 + $1.footprintMB }, n: a.count, color: claudeColor.opacity(0.7)),
                MachineGroup(label: "Ngủ ≥ \(Int(hours))h", unit: "session", mb: i.reduce(0) { $0 + $1.footprintMB }, n: i.count, color: claudeColor.opacity(0.4)),
                MachineGroup(label: "Bỏ quên", unit: "process", mb: leftovers.reduce(0) { $0 + $1.footprintMB }, n: leftovers.count, color: Color.gray.opacity(0.7))]
    }
    /// Everything as rows in three groups: "Nên dọn" (safe), "Cân nhắc" (the user's call), "Đang chạy" (leave alone).
    /// The members of one stat column (0 running, 1 awake, 2 idle, 3 leftovers), as (title, detail, MB).
    func groupItems(_ k: Int, hours: Double) -> [(String, String, Double)] {
        let ss: [AgentSession]
        switch k {
        case 0: ss = busy
        case 1: ss = sessions.filter { !$0.busy && !$0.isIdle(hours) }
        case 2: ss = idle(hours)
        default: return leftovers.sorted { $0.footprintMB > $1.footprintMB }.map { ($0.command, [$0.kind, $0.byAgent ? "do agent chạy" : $0.project, fmtAge($0.age)].filter { !$0.isEmpty }.joined(separator: " · "), $0.footprintMB) }
        }
        return ss.sorted { $0.footprintMB > $1.footprintMB }.map { s in
            let where_ = [s.host, s.tty].filter { !$0.isEmpty }.joined(separator: " ")
            let st = s.busy ? "đang chạy" + (s.busyWith.isEmpty ? "" : " · \(s.busyWith)") : "ngủ \(fmtAge(s.idleFor))"
            return (s.name, [st, s.project, where_].filter { !$0.isEmpty }.joined(separator: " · "), s.footprintMB)
        }
    }
    func items(_ hours: Double) -> (clean: [MachineItem], review: [MachineItem], running: [MachineItem]) {
        var clean: [MachineItem] = [], review: [MachineItem] = [], running: [MachineItem] = []
        for s in sessions {
            let where_ = [s.host, s.tty].filter { !$0.isEmpty }.joined(separator: " ")
            let kind = (s.tool == "claude" ? "Claude Code" : "Codex") + (where_.isEmpty ? "" : " · \(where_)")
            let idle = s.isIdle(hours)
            let status = s.busy ? "đang chạy" + (s.busyWith.isEmpty ? "" : " · \(s.busyWith) \(Int(s.cpuPct))%") : "ngủ \(fmtAge(s.idleFor))"
            let it = MachineItem(id: s.id, isSession: true, title: s.name, kind: kind, status: status, cleanable: idle, mb: s.footprintMB, session: s)
            if s.busy { running.append(it) } else if idle { clean.append(it) } else { review.append(it) }
        }
        for l in leftovers {
            let kind = [l.kind, l.byAgent ? "do agent chạy" : l.project].filter { !$0.isEmpty }.joined(separator: " · ")
            let status = l.projectLive ? "bỏ quên \(fmtAge(l.age)) · project còn session mở" : "bỏ quên \(fmtAge(l.age))"
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
            out.append("\(n) session cùng mở project \(proj): mỗi session mang MCP server và LSP riêng của nó.")
        }
        var dup: [String: (Int, Double)] = [:]
        for s in sessions { for (name, mb) in s.members.dropFirst() where !ProcessCensus.shells.contains(name) { let c = dup[name] ?? (0, 0); dup[name] = (c.0 + 1, c.1 + mb) } }
        if let (name, c) = dup.max(by: { $0.value.0 < $1.value.0 }), c.0 >= 3 {
            out.append("\(c.0) bản \(name) giống nhau, một bản cho mỗi session · \(fmtMB(c.1)).")
        }
        if let top = others.first, top.footprintMB > aiMB {
            out.append("Riêng một process của \(top.name) đã giữ \(fmtMB(top.footprintMB)), nhiều hơn toàn bộ AI.")
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
                            .help("\(gr.label) · \(fmtMB(gr.mb)) · \(gr.n) \(gr.unit)")
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
            Text(g.n > 0 ? "\(g.n) \(g.unit)" : "không có").font(.system(size: 9)).foregroundStyle(dark ? Color.white.opacity(0.45) : Color.secondary).lineLimit(1)
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
                Text("Máy").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 66)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.sessions.isEmpty && m.leftovers.isEmpty ? "AI không chạy" : "AI đang giữ \(fmtMB(m.aiMB))")
                        .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Spacer(minLength: 6)
                    Text("RAM còn \(m.freePct)%" + (m.swapUsedGB >= 0.5 ? String(format: " · swap %.1f GB", m.swapUsedGB) : ""))
                        .font(.system(size: 9)).foregroundStyle(level > 0 ? levelColor(level) : .white.opacity(0.5)).monospacedDigit().lineLimit(1)
                }
                ShareBar(groups: m.groups(prefs.idleHours), ramMB: m.ramGB * 1024, dark: true, height: 4)
                Text(summary(m, c: c)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                HStack(spacing: 3) {
                    Text(c.mb > 0 ? "Xem & dọn · lấy lại \(fmtMB(c.mb))" : "Xem chi tiết")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(c.mb > 0 ? Color.orange : .white.opacity(0.7))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(c.mb > 0 ? Color.orange : .white.opacity(0.7))
                    Spacer()
                    Text("⌃⌥M").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.1 : 0.06)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { AppDelegate.shared?.openMachine() }
        .help("Bộ nhớ mà Claude Code / Codex, process con và process bỏ quên đang giữ. Bấm để xem chi tiết và dọn.")
    }
    /// "13 session · 5 ngủ ≥ 2h · 6 process bỏ quên" or "2 đang chạy · 3 mở"
    func summary(_ m: MachineState, c: (sessions: [AgentSession], leftovers: [Leftover], mb: Double)) -> String {
        if m.sessions.isEmpty && m.leftovers.isEmpty { return "Không có process Claude Code / Codex nào." }
        var parts: [String] = []
        let b = m.busy.count
        if b > 0 { parts.append("\(b) đang chạy") }
        let idle = m.idle(prefs.idleHours).count
        let awake = m.sessions.count - b - idle
        if awake > 0 { parts.append("\(awake) mở") }
        if idle > 0 { parts.append("\(idle) ngủ ≥ \(Int(prefs.idleHours))h") }
        if !m.leftovers.isEmpty { parts.append("\(m.leftovers.count) bỏ quên") }
        return (["\(m.sessions.count) session"] + parts).joined(separator: " · ")
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
                Text(i.resetIn > 0 ? "↻ \(fmtWhen(i.limit.resetsAt)) · \(fmtDur(i.resetIn))" : "")
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
