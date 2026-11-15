// The "Máy" window: a plain macOS window (not the glance) that makes the cost of AI tooling visible and
// gives it back. Top: the pet, one big number, one sentence of advice and the one button that does it. Then
// two groups by what to do: "Nên dọn" (sessions asleep, processes nobody uses) and "Đang dùng, để yên". Every
// row carries the evidence a developer would check by hand (path, terminal, times, the process tree with sizes,
// ports); every action names the pids and what happens before doing it; "…" copies the equivalent kill command.
import SwiftUI
import AppKit

struct MachineView: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    var snapshot = false          // --snapshot: ImageRenderer cannot draw a ScrollView, so lay the content out flat
    @State private var expanded = Set<pid_t>()
    @State private var statGroup: Int? = nil      // which stat column is folded out under the share bar
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        let m = model.machine
        let c = m.cleanable(prefs.idleHours)
        let (clean, review, running) = m.items(prefs.idleHours)
        let content = VStack(alignment: .leading, spacing: 18) {
            hero(m, c: c)
            if !clean.isEmpty {
                section("Nên dọn", count: clean.count, mb: clean.reduce(0) { $0 + $1.mb }, color: .orange,
                        sub: "session ngủ ≥ \(Int(prefs.idleHours))h, process chạy nền mà không còn session nào của project đó") {
                    rows(clean)
                }
            }
            if !review.isEmpty {
                section("Cân nhắc", count: review.count, mb: review.reduce(0) { $0 + $1.mb }, color: .primary,
                        sub: "mới dùng gần đây, hoặc project còn session mở: tự quyết") {
                    rows(review)
                }
            }
            if !running.isEmpty {
                section("Đang chạy, để yên", count: running.count, mb: running.reduce(0) { $0 + $1.mb }, color: .secondary,
                        sub: "đang chạy lệnh hoặc vừa ghi transcript") {
                    rows(running)
                }
            }
            if !m.others.isEmpty { othersSection(m) }
            if m.sessions.isEmpty && m.leftovers.isEmpty {
                Text("Không có process Claude Code / Codex nào đang chạy, không có process bỏ quên.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
            }
        }
        .padding(20)
        VStack(spacing: 0) {
            if snapshot { content } else { ScrollView { content } }
            Divider()
            footer
        }
        .frame(minWidth: 540)
        .onAppear { model.rescanProcs() }
        .onReceive(refresh) { _ in model.rescanProcs() }
    }

    // MARK: hero

    @ViewBuilder func hero(_ m: MachineState, c: (sessions: [AgentSession], leftovers: [Leftover], mb: Double)) -> some View {
        let groups = m.groups(prefs.idleHours)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                if prefs.pet { PetView(color: claudeColor, mood: m.mood, kind: prefs.petClaude, fullness: Double(m.freePct) / 100, animate: false, size: 60) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("AI đang giữ \(fmtMB(m.aiMB))").font(.system(size: 26, weight: .bold, design: .rounded))
                        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                            .help("Bộ nhớ vật lý như cột Memory của Activity Monitor, gồm cả phần đã bị nén hoặc đẩy ra swap. Một session ngủ nhìn \"nhẹ\" trong ps nhưng vẫn chiếm chỗ và phải nạp lại khi dùng.")
                    }
                    Text(m.verdict).font(.system(size: 12)).foregroundStyle(m.heavy ? Color.orange : .secondary)
                    Text(m.advice(prefs.idleHours)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(m.insights, id: \.self) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "lightbulb").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if c.mb > 0 {
                        Button(action: { confirmAll(c) }) { Text("Dọn hết · lấy lại \(fmtMB(c.mb))").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 6) }
                            .keyboardShortcut(.defaultAction).help("\(c.sessions.count) session ngủ + \(c.leftovers.count) process bỏ quên. Hỏi lại trước khi làm.")
                    }
                    Button(action: { model.rescanProcs() }) { Image(systemName: "arrow.clockwise") }.controlSize(.small).help("Quét lại (tự quét mỗi 10 giây khi cửa sổ mở)")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ShareBar(groups: groups, ramMB: m.ramGB * 1024, dark: false, height: 8, selected: statGroup, onTap: { toggleGroup($0) })
                HStack(spacing: 6) {
                    ForEach(groups.indices, id: \.self) { k in
                        MachineStat(g: groups[k], dark: false, selected: statGroup == k)
                            .onTapGesture { toggleGroup(k) }
                            .help(groups[k].n > 0 ? "Bấm để xem \(groups[k].n) \(groups[k].unit) này" : "")
                    }
                }
                if let k = statGroup {
                    let list = m.groupItems(k, hours: prefs.idleHours)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list.indices, id: \.self) { i in
                            if i > 0 { Divider() }
                            HStack(spacing: 8) {
                                Circle().fill(groups[k].color).frame(width: 6, height: 6)
                                Text(list[i].0).font(.system(size: 11, weight: .medium, design: k == 3 ? .monospaced : .default)).lineLimit(1)
                                Text(list[i].1).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(fmtMB(list[i].2)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                        if list.isEmpty { Text("Không có.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .transition(.opacity)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder func rows(_ items: [MachineItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { k, it in
            if k > 0 { Divider() }
            row(it)
        }
    }
    /// What else holds the RAM, so AI is not blamed for Chrome. Read-only: TokenPet only touches AI tooling.
    @ViewBuilder func othersSection(_ m: MachineState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ngoài AI").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                Text("process lớn nhất của mỗi app · chỉ để so sánh").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Activity Monitor") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(m.others.enumerated()), id: \.element.id) { k, o in
                    if k > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: o.isApp ? "app" : "gearshape.2").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
                        Text(o.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(o.procs > 1 ? "+ \(o.procs - 1) process con" : "").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text(fmtMB(o.footprintMB)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        }
    }
    func toggleGroup(_ k: Int) {
        withAnimation(prefs.transitions ? .easeInOut(duration: 0.15) : nil) { statGroup = statGroup == k ? nil : k }
    }
    func section<C: View>(_ title: String, count: Int, mb: Double, color: Color, sub: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
                Text("\(count) · \(fmtMB(mb))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .padding(.top, 4)
        }
    }

    // MARK: rows

    @ViewBuilder func row(_ it: MachineItem) -> some View {
        let members = it.session?.members ?? it.leftover?.members ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if it.isSession { Circle().fill(it.color).opacity(it.cleanable ? 0.5 : 1).frame(width: 8, height: 8) }
                    else { Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.frame(width: 12).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.title).font(.system(size: 13, weight: .semibold, design: it.isSession ? .default : .monospaced)).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(it.status).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                            .foregroundStyle(it.cleanable ? Color.orange : (it.session?.busy == true ? it.color : Color.secondary))
                        Text("·").foregroundStyle(.secondary)
                        Text(it.kind).font(.system(size: 11)).foregroundStyle(it.leftover?.byAgent == true ? Color.orange : Color.primary.opacity(0.8)).lineLimit(1)
                        if let s = it.session {
                            if model.autoCloseScheduled.contains(s.id) { chip("tự đóng sau 5 phút", .red) }
                            if model.kept.contains(s.id) { chip("giữ", .secondary) }
                        }
                    }
                    Text(meta(it)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(fmtMB(it.mb)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 64, alignment: .trailing).padding(.top, 1)
                HStack(spacing: 4) { actions(it) }
            }
            if members.count > 1 { tree(it.id, members) }
        }
        .padding(.vertical, 9)
    }
    @ViewBuilder func actions(_ it: MachineItem) -> some View {
        if let s = it.session {
            if model.autoCloseScheduled.contains(s.id) { Button("Giữ") { model.kept.insert(s.id); model.objectWillChange.send() }.controlSize(.small) }
            Button("Đóng") { confirmClose(s) }.controlSize(.small).disabled(s.busy)
                .help(s.busy ? "Đang chạy: không đóng khi session còn làm việc" : "Gửi SIGTERM cho claude (pid \(s.id)) và \(s.children) process con. Tab terminal vẫn mở; mở lại bằng claude --resume.")
            copyButton("kill -TERM \(s.id)   # \(s.name): claude + \(s.children) process con")
        } else if let l = it.leftover {
            Button("Dọn") { confirmClean(l) }.controlSize(.small)
                .help("Gửi SIGTERM cho \(l.tree.count) process (pid \(l.id)…), sau 3 giây SIGKILL nếu còn. Chỉ tắt process, không động vào file.")
            copyButton("kill -TERM \(l.tree.map { String($0.pid) }.joined(separator: " "))   # \(l.command)")
        }
    }
    func meta(_ it: MachineItem) -> String {
        if let s = it.session {
            var parts = [short(s.cwd), "pid \(s.id)", "mở \(fmtWhen(s.startedAt))"]
            if !s.busy && s.idleFor > 0 { parts.append("ngủ từ \(fmtWhen(Date().timeIntervalSince1970 - s.idleFor))") }
            parts.append("CLI \(fmtMB(s.ownMB))" + (s.children > 0 ? " + \(s.children) con \(fmtMB(max(0, s.footprintMB - s.ownMB)))" : ""))
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        guard let l = it.leftover else { return "" }
        var parts = [short(l.cwd), "pid \(l.id)", "chạy từ \(fmtWhen(l.startedAt)) (\(fmtAge(l.age)))"]
        if !l.ports.isEmpty { parts.append("cổng " + l.ports.map(String.init).joined(separator: ", ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    @ViewBuilder func tree(_ id: pid_t, _ members: [(String, Double)]) -> some View {
        Button(action: { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }) {
            HStack(spacing: 4) {
                Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                Text(expanded.contains(id) ? "cây process" : members.prefix(4).map { "\($0.0) \(fmtMB($0.1))" }.joined(separator: " · ") + (members.count > 4 ? " · +\(members.count - 4)" : ""))
                    .font(.system(size: 10, design: .monospaced)).lineLimit(1)
            }.foregroundStyle(.secondary)
        }.buttonStyle(.plain).padding(.leading, 22)
        if expanded.contains(id) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(members.indices, id: \.self) { k in
                    HStack {
                        Text((k == 0 ? "" : "  └ ") + members[k].0).font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text(fmtMB(members[k].1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }.padding(.leading, 36).padding(.vertical, 2)
        }
    }
    func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold)).foregroundStyle(c).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.12)))
    }
    func copyButton(_ cmd: String) -> some View {
        Button(action: { copy(cmd) }) { Image(systemName: "doc.on.doc") }.controlSize(.small)
            .help("Sao chép lệnh kill vào clipboard để tự chạy trong terminal:\n\(cmd)")
    }

    // MARK: footer and confirms

    var footer: some View {
        HStack(spacing: 10) {
            Text("Đóng / Dọn gửi SIGTERM như Ctrl+C và luôn hỏi lại trước. Không bao giờ tự động, trừ khi bật \"Tự đóng session ngủ\" trong Cài đặt.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cài đặt…") { AppDelegate.shared?.openSettings() }.controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    /// "~/Projects/x" for the home folder; a Claude scratchpad becomes "scratchpad Claude · <project>".
    func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if ProcessCensus.scratchpad(path) {
            let parts = path.split(separator: "/").map(String.init)
            if let k = parts.firstIndex(where: { $0.hasPrefix("claude-") }), k + 1 < parts.count {
                let proj = parts[k + 1].split(separator: "-").last.map(String.init) ?? parts[k + 1]
                return "scratchpad Claude · \(proj)"
            }
            return "scratchpad Claude"
        }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    func confirm(_ title: String, _ info: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = info
        a.addButton(withTitle: button); a.addButton(withTitle: "Hủy")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    func confirmClose(_ s: AgentSession) {
        let kids = s.members.dropFirst().map { "\($0.0) \(fmtMB($0.1))" }.joined(separator: ", ")
        let info = "Gửi SIGTERM cho claude pid \(s.id)" + (s.children > 0 ? " và \(s.children) process con (\(kids))" : "") + ".\n\n"
            + "Tab terminal \(s.tty.isEmpty ? "" : s.tty + " ")vẫn mở, chỉ còn dấu nhắc shell. Transcript đã lưu; mở lại bằng:\n   claude --resume\n\nLấy lại \(fmtMB(s.footprintMB))."
        if confirm("Đóng session \(s.name)?", info, button: "Đóng session") { model.close(s) }
    }
    func confirmClean(_ l: Leftover) {
        let tree = l.members.map { "\($0.0) \(fmtMB($0.1))" }.joined(separator: ", ")
        let info = "Gửi SIGTERM cho \(l.tree.count) process (\(tree)), sau 3 giây SIGKILL nếu còn.\n\n"
            + "Thư mục: \(short(l.cwd))\nChạy từ \(fmtWhen(l.startedAt))" + (l.ports.isEmpty ? "" : ", đang giữ cổng " + l.ports.map(String.init).joined(separator: ", "))
            + ".\n\nChỉ tắt process, không động vào file. Chạy lại khi cần bằng chính lệnh đó.\(l.projectLive ? "\n\nLưu ý: vẫn có session agent mở trong project này, có thể nó đang dùng server này." : "")"
        if confirm("Dọn \(l.command)?", info, button: "Dọn") { model.clean(l) }
    }
    func confirmAll(_ c: (sessions: [AgentSession], leftovers: [Leftover], mb: Double)) {
        var lines: [String] = []
        for s in c.sessions { lines.append("• session \(s.name) · ngủ \(fmtAge(s.idleFor)) · \(fmtMB(s.footprintMB))") }
        for l in c.leftovers { lines.append("• \(l.command) · \(fmtAge(l.age)) · \(fmtMB(l.footprintMB))") }
        let info = lines.joined(separator: "\n") + "\n\nSession đang chạy, session chưa ngủ đủ \(Int(prefs.idleHours))h và process của project còn session mở KHÔNG bị đụng tới. Session đóng mở lại bằng claude --resume."
        if confirm("Dọn \(c.sessions.count) session ngủ và \(c.leftovers.count) process bỏ quên, lấy lại \(fmtMB(c.mb))?", info, button: "Dọn tất cả") { model.cleanAll() }
    }
}
