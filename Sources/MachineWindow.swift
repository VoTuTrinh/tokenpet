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
                section(L("Worth closing", "Nên dọn"), count: clean.count, mb: clean.reduce(0) { $0 + $1.mb }, color: .orange,
                        sub: L("Asleep ≥ \(Int(prefs.idleHours))h, or nobody owns it any more. Nothing is lost: transcripts are saved (claude --resume), servers start again with the same command.", "Ngủ ≥ \(Int(prefs.idleHours))h, hoặc không còn ai dùng. Không mất gì: transcript đã lưu (claude --resume), server chạy lại bằng đúng lệnh cũ.")) {
                    rows(clean)
                }
            }
            if !review.isEmpty {
                section(L("Your call", "Cân nhắc"), count: review.count, mb: review.reduce(0) { $0 + $1.mb }, color: .primary,
                        sub: L("Used recently, or its project still has a session that may need it.", "Mới dùng gần đây, hoặc project của nó còn session có thể đang cần.")) {
                    rows(review)
                }
            }
            if !running.isEmpty {
                section(L("Running, leave alone", "Đang chạy, để yên"), count: running.count, mb: running.reduce(0) { $0 + $1.mb }, color: .secondary,
                        sub: L("Working right now. TokenPet will not close these.", "Đang làm việc. TokenPet không đóng những cái này.")) {
                    rows(running)
                }
            }
            if !m.others.isEmpty { othersSection(m) }
            if m.sessions.isEmpty && m.leftovers.isEmpty {
                Text(L("No Claude Code / Codex processes running, no leftover processes.", "Không có process Claude Code / Codex nào đang chạy, không có process bỏ quên."))
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
                        Text(L("Agents hold \(fmtMB(m.aiMB))", "AI đang giữ \(fmtMB(m.aiMB))")).font(.system(size: 26, weight: .bold, design: .rounded))
                        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                            .help(L("Physical memory, like the Memory column in Activity Monitor, including what has been compressed or swapped out. An asleep session looks \"light\" in ps but still takes up space and has to be loaded back in when you use it.",
                                    "Bộ nhớ vật lý như cột Memory của Activity Monitor, gồm cả phần đã bị nén hoặc đẩy ra swap. Một session ngủ nhìn \"nhẹ\" trong ps nhưng vẫn chiếm chỗ và phải nạp lại khi dùng."))
                    }
                    Text(m.verdict).font(.system(size: 12)).foregroundStyle(m.heavy ? Color.orange : .secondary)
                    Text(m.advice(prefs.idleHours)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if let f = model.freed, Date().timeIntervalSince1970 - f.at < 60 {
                        Label(f.text, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                    }
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
                        Button(action: { confirmAll(c) }) { Text(L("Close all · get back \(fmtMB(c.mb))", "Dọn hết · lấy lại \(fmtMB(c.mb))")).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 6) }
                            .keyboardShortcut(.defaultAction).help(L("\(enCount(c.sessions.count, "asleep session")) + \(enCount(c.leftovers.count, "leftover process")). Asks before doing anything.", "\(c.sessions.count) session ngủ + \(c.leftovers.count) process bỏ quên. Hỏi lại trước khi làm."))
                    }
                    Button(action: { model.rescanProcs() }) { Image(systemName: "arrow.clockwise") }.controlSize(.small).help(L("Rescan (automatic every 10 seconds while this window is open)", "Quét lại (tự quét mỗi 10 giây khi cửa sổ mở)"))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ShareBar(groups: groups, ramMB: m.ramGB * 1024, dark: false, height: 8, selected: statGroup, onTap: { toggleGroup($0) })
                HStack(spacing: 6) {
                    ForEach(groups.indices, id: \.self) { k in
                        MachineStat(g: groups[k], dark: false, selected: statGroup == k)
                            .onTapGesture { toggleGroup(k) }
                            .help(groups[k].n > 0 ? L("Click to list \(groups[k].countText)", "Bấm để xem \(groups[k].n) \(groups[k].unit) này") : "")
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
                        if list.isEmpty { Text(L("None.", "Không có.")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4) }
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
                Text(L("Not agents", "Ngoài AI")).font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                Text(L("largest process of each app · for comparison only", "process lớn nhất của mỗi app · chỉ để so sánh")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Activity Monitor") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(m.others.enumerated()), id: \.element.id) { k, o in
                    if k > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: o.isApp ? "macwindow" : "gearshape.2").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
                        Text(o.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(o.procs > 1 ? L("+ \(enCount(o.procs - 1, "child process"))", "+ \(o.procs - 1) process con") : "").font(.system(size: 10)).foregroundStyle(.secondary)
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
            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .padding(.top, 4)
        }
    }

    // MARK: rows

    /// Two lines answer "what is it, and can I close it?": name and size, then state · what · where. The evidence
    /// a developer would check by hand (path, pid, terminal, times, the process tree) opens under the chevron.
    @ViewBuilder func row(_ it: MachineItem) -> some View {
        let members = it.session?.members ?? it.leftover?.members ?? []
        let open = expanded.contains(it.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: { if open { expanded.remove(it.id) } else { expanded.insert(it.id) } }) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 14, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("Path, pid, terminal and the process tree", "Đường dẫn, pid, terminal và cây process"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.title).font(.system(size: 13, weight: .semibold, design: it.isSession ? .default : .monospaced)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor(it)).frame(width: 6, height: 6)
                        Text(it.status).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(statusColor(it))
                        Text("·").foregroundStyle(.secondary)
                        Text(it.kind).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                        if let l = it.leftover, !l.exposed.isEmpty {
                            chip(L("all interfaces", "mọi giao diện mạng"), .orange)
                                .help(L("Port \(l.exposed.map(String.init).joined(separator: ", ")) listens on every network interface, not just localhost, so other devices on this network may be able to reach it unless the firewall blocks them. Many dev servers do this by default.", "Cổng \(l.exposed.map(String.init).joined(separator: ", ")) nghe trên mọi giao diện mạng, không chỉ localhost, nên thiết bị khác trong mạng có thể truy cập được nếu tường lửa không chặn. Nhiều dev server mặc định như vậy."))
                        }
                        if let s = it.session {
                            if model.autoCloseScheduled.contains(s.id) { chip(L("closes in 5 min", "tự đóng sau 5 phút"), .red) }
                            if model.kept.contains(s.id) { chip(L("kept", "giữ"), .secondary) }
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(fmtMB(it.mb)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 64, alignment: .trailing)
                HStack(spacing: 4) { actions(it) }.frame(width: 118, alignment: .trailing)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(evidence(it), id: \.0) { k, v in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(k).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 11))
                    }
                    if members.count > 1 {
                        ForEach(members.indices, id: \.self) { k in
                            HStack {
                                Text((k == 0 ? "" : "  └ ") + members[k].0).font(.system(size: 10.5, design: .monospaced))
                                Spacer()
                                Text(fmtMB(members[k].1)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 9)
    }
    /// Green: in use. Orange: asleep, worth closing. Purple: a process nobody owns. Grey: open but quiet.
    func statusColor(_ it: MachineItem) -> Color {
        if it.session?.busy == true { return MachineGroup.running }
        if it.leftover != nil { return it.cleanable ? MachineGroup.leftover : Color.secondary }
        return it.cleanable ? MachineGroup.asleep : Color.secondary
    }
    @ViewBuilder func actions(_ it: MachineItem) -> some View {
        if let s = it.session {
            if model.autoCloseScheduled.contains(s.id) { Button(L("Keep", "Giữ")) { model.kept.insert(s.id); model.objectWillChange.send() }.controlSize(.small) }
            if s.busy {
                Text(L("in use", "đang dùng")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(L("Working right now: TokenPet does not close a session in the middle of a turn.", "Đang làm việc: TokenPet không đóng session giữa chừng."))
            } else {
                Button(action: { confirmClose(s) }) { Text(L("Close", "Đóng")).frame(minWidth: 38) }.controlSize(.small)
                    .help(L("Sends SIGTERM to claude (pid \(s.id)) and \(enCount(s.children, "child process")). The terminal tab stays open; reopen with claude --resume.", "Gửi SIGTERM cho claude (pid \(s.id)) và \(s.children) process con. Tab terminal vẫn mở; mở lại bằng claude --resume."))
                copyButton("kill -TERM \(s.id)   # \(s.name): claude + " + L(enCount(s.children, "child process"), "\(s.children) process con"))
            }
        } else if let l = it.leftover {
            if let port = l.ports.first, let url = URL(string: "http://localhost:\(port)") {
                Button(action: { NSWorkspace.shared.open(url) }) { Image(systemName: "safari") }.controlSize(.small)
                    .help(L("Open localhost:\(port) in the browser, to see what it is before stopping it", "Mở localhost:\(port) trong trình duyệt, để xem nó là gì trước khi dọn"))
            }
            Button(action: { confirmClean(l) }) { Text(L("Stop", "Dọn")).frame(minWidth: 38) }.controlSize(.small)
                .help(L("Sends SIGTERM to \(enCount(l.tree.count, "process")) (pid \(l.id)…), then SIGKILL after 3 seconds if still alive. Only stops processes, never touches files.", "Gửi SIGTERM cho \(l.tree.count) process (pid \(l.id)…), sau 3 giây SIGKILL nếu còn. Chỉ tắt process, không động vào file."))
            copyButton("kill -TERM \(l.tree.map { String($0.pid) }.joined(separator: " "))   # \(l.command)")
        }
    }
    /// The evidence, as labelled facts.
    func evidence(_ it: MachineItem) -> [(String, String)] {
        var out: [(String, String)] = []
        if let s = it.session {
            out.append((L("Folder", "Thư mục"), short(s.cwd)))
            let term = [s.host, s.tty].filter { !$0.isEmpty }.joined(separator: " · ")
            if !term.isEmpty { out.append((L("Terminal", "Terminal"), term)) }
            out.append((L("Opened", "Mở lúc"), fmtWhen(s.startedAt)))
            if !s.busy && s.idleFor > 0 { out.append((L("Last used", "Dùng lần cuối"), fmtWhen(Date().timeIntervalSince1970 - s.idleFor))) }
            out.append(("PID", "\(s.id)"))
        } else if let l = it.leftover {
            if !l.cwd.isEmpty { out.append((L("Folder", "Thư mục"), short(l.cwd))) }
            out.append((L("Started", "Chạy từ"), "\(fmtWhen(l.startedAt)) (\(fmtAge(l.age)))"))
            if !l.ports.isEmpty { out.append((L("Ports", "Cổng"), l.ports.map { l.exposed.contains($0) ? L("\($0) (all interfaces)", "\($0) (mọi giao diện mạng)") : "\($0) (localhost)" }.joined(separator: ", "))) }
            out.append((L("Why leftover", "Vì sao bỏ quên"), L("its parent shell has exited, so closing the tab no longer stops it", "shell cha đã thoát, nên đóng tab không còn tắt được nó")))
            out.append(("PID", "\(l.id)"))
        }
        return out
    }
    func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold)).foregroundStyle(c).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.12)))
    }
    func copyButton(_ cmd: String) -> some View {
        Button(action: { copy(cmd) }) { Image(systemName: "terminal") }.controlSize(.small)
            .help(L("Copy the kill command to the clipboard to run it yourself in a terminal:\n\(cmd)", "Sao chép lệnh kill vào clipboard để tự chạy trong terminal:\n\(cmd)"))
    }

    // MARK: footer and confirms

    var footer: some View {
        HStack(spacing: 10) {
            Text(L("Close / Stop send SIGTERM, like Ctrl+C, and always ask first. Never automatic, unless you turn on \"Close sessions asleep for more than…\" in Settings.",
                   "Đóng / Dọn gửi SIGTERM như Ctrl+C và luôn hỏi lại trước. Không bao giờ tự động, trừ khi bật \"Tự đóng session ngủ\" trong Cài đặt."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("Settings…", "Cài đặt…")) { AppDelegate.shared?.openSettings() }.controlSize(.small)
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
                return L("Claude scratchpad · \(proj)", "scratchpad Claude · \(proj)")
            }
            return L("Claude scratchpad", "scratchpad Claude")
        }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    func confirm(_ title: String, _ info: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = info
        a.addButton(withTitle: button); a.addButton(withTitle: L("Cancel", "Hủy"))
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    func confirmClose(_ s: AgentSession) {
        let kids = s.members.dropFirst().map { "\($0.0) \(fmtMB($0.1))" }.joined(separator: ", ")
        let info = L("Sends SIGTERM to claude pid \(s.id)" + (s.children > 0 ? " and \(enCount(s.children, "child process")) (\(kids))" : "") + ".\n\n"
                         + "The terminal tab \(s.tty.isEmpty ? "" : s.tty + " ")stays open with just a shell prompt. The transcript is saved; reopen with:\n   claude --resume\n\nGets back \(fmtMB(s.footprintMB)).",
                     "Gửi SIGTERM cho claude pid \(s.id)" + (s.children > 0 ? " và \(s.children) process con (\(kids))" : "") + ".\n\n"
                         + "Tab terminal \(s.tty.isEmpty ? "" : s.tty + " ")vẫn mở, chỉ còn dấu nhắc shell. Transcript đã lưu; mở lại bằng:\n   claude --resume\n\nLấy lại \(fmtMB(s.footprintMB)).")
        if confirm(L("Close session \(s.name)?", "Đóng session \(s.name)?"), info, button: L("Close session", "Đóng session")) { model.close(s) }
    }
    func confirmClean(_ l: Leftover) {
        let tree = l.members.map { "\($0.0) \(fmtMB($0.1))" }.joined(separator: ", ")
        let ports = l.ports.map(String.init).joined(separator: ", ")
        let info = L("Sends SIGTERM to \(enCount(l.tree.count, "process")) (\(tree)), then SIGKILL after 3 seconds if still alive.\n\n"
                         + "Folder: \(short(l.cwd))\nRunning since \(fmtWhen(l.startedAt))" + (l.ports.isEmpty ? "" : ", holding \(l.ports.count == 1 ? "port" : "ports") " + ports)
                         + ".\n\nOnly stops processes, never touches files. Run the same command again when you need it.\(l.projectLive ? "\n\nNote: an agent session is still open in this project and may be using this server." : "")",
                     "Gửi SIGTERM cho \(l.tree.count) process (\(tree)), sau 3 giây SIGKILL nếu còn.\n\n"
                         + "Thư mục: \(short(l.cwd))\nChạy từ \(fmtWhen(l.startedAt))" + (l.ports.isEmpty ? "" : ", đang giữ cổng " + ports)
                         + ".\n\nChỉ tắt process, không động vào file. Chạy lại khi cần bằng chính lệnh đó.\(l.projectLive ? "\n\nLưu ý: vẫn có session agent mở trong project này, có thể nó đang dùng server này." : "")")
        if confirm(L("Stop \(l.command)?", "Dọn \(l.command)?"), info, button: L("Stop", "Dọn")) { model.clean(l) }
    }
    func confirmAll(_ c: (sessions: [AgentSession], leftovers: [Leftover], mb: Double)) {
        var lines: [String] = []
        for s in c.sessions { lines.append(L("• session \(s.name) · asleep \(fmtAge(s.idleFor)) · \(fmtMB(s.footprintMB))", "• session \(s.name) · ngủ \(fmtAge(s.idleFor)) · \(fmtMB(s.footprintMB))")) }
        for l in c.leftovers { lines.append("• \(l.command) · \(fmtAge(l.age)) · \(fmtMB(l.footprintMB))") }
        let info = lines.joined(separator: "\n") + L("\n\nRunning sessions, sessions asleep for less than \(Int(prefs.idleHours))h and processes whose project still has an open session are NOT touched. Reopen a closed session with claude --resume.",
                                                   "\n\nSession đang chạy, session chưa ngủ đủ \(Int(prefs.idleHours))h và process của project còn session mở KHÔNG bị đụng tới. Session đóng mở lại bằng claude --resume.")
        if confirm(L("Close \(enCount(c.sessions.count, "asleep session")) and \(enCount(c.leftovers.count, "leftover process")) to get back \(fmtMB(c.mb))?", "Dọn \(c.sessions.count) session ngủ và \(c.leftovers.count) process bỏ quên, lấy lại \(fmtMB(c.mb))?"),
                   info, button: L("Close all", "Dọn tất cả")) { model.cleanAll() }
    }
}
