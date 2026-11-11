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
                HStack(spacing: 3) {
                    Text(s.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    if s.running > 0 { Text("\(s.running)▶").font(.system(size: 9, weight: .bold)).foregroundStyle(s.color) }
                }
            }
            .frame(width: 60)
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
    @State private var showDetails = UserDefaults.standard.bool(forKey: "glanceDetails")

    var body: some View {
        let open = forceDetails ?? showDetails
        VStack(alignment: .leading, spacing: 8) {
            if prefs.tools.isEmpty {
                Text("Chưa bật công cụ nào. Bật Claude hoặc Codex trong Cài đặt.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(12)
            }
            ForEach(prefs.tools, id: \.self) { tool in
                ToolCardView(s: model.summary(tool), rows: model.mainRows(tool), animate: animate, showPet: prefs.pet)
            }
            let running = model.sessions.filter { $0.running && prefs.tools.contains($0.tool) }
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(running.prefix(3)) { s in SessionRow(s: s) }
                    if running.count > 3 {
                        Text("+\(running.count - 3) session khác").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    }
                }.padding(.horizontal, 12).padding(.top, 2)
            }
            if open { details.padding(.horizontal, 12) }
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation(prefs.transitions ? .spring(response: 0.3, dampingFraction: 0.85) : nil) { showDetails.toggle() }
                    UserDefaults.standard.set(showDetails, forKey: "glanceDetails")
                    model.statsWanted = prefs.floating || showDetails
                }) {
                    Label(open ? "Thu gọn" : "Chi tiết", systemImage: open ? "chevron.up" : "chevron.down")
                }
                Spacer()
                if model.procs.count > 0 {
                    Text("agent \(model.procs.count) process · \(fmtMB(model.procs.footprintMB))").help("RAM của các process claude/codex")
                }
                Button(action: { AppDelegate.shared?.openSettings() }) { Image(systemName: "gearshape") }.help("Cài đặt")
            }
            .buttonStyle(.plain).labelStyle(.titleAndIcon)
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
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
