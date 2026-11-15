// Settings: one page, few decisions. Where to show, the pet, how loud, data. Details fold away.
// Plain NSWindow + NSHostingController (manual NSApplication, macOS 13 target); dropped when closed.
import SwiftUI
import AppKit
import ServiceManagement

enum NotchStyle: Int, CaseIterable { case ears, hoverOnly, off
    var label: String { ["Tai + bảng", "Chỉ bảng khi rê chuột", "Tắt"][rawValue] }
}
enum EdgeStyle: Int, CaseIterable { case off, left, right
    var label: String { ["Tắt", "Trái", "Phải"][rawValue] }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    @State private var custom = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var selfMB = footprintMB()
    var unframed = false          // --settings-size: measure the form's own ideal width

    var notchStyle: Binding<NotchStyle> {
        Binding(get: { prefs.notch ? (prefs.notchEarsAlways ? .ears : .hoverOnly) : .off },
                set: { prefs.notch = $0 != .off; if $0 != .off { prefs.notchEarsAlways = $0 == .ears } })
    }
    var edgeStyle: Binding<EdgeStyle> {
        Binding(get: { prefs.edgeDock ? (prefs.edgeRight ? .right : .left) : .off },
                set: { prefs.edgeDock = $0 != .off; if $0 != .off { prefs.edgeRight = $0 == .right } })
    }

    var body: some View {
        Form {
            Section("Công cụ") {
                ForEach(["claude", "codex"], id: \.self) { tool in
                    let on = tool == "claude" ? $prefs.showClaude : $prefs.showCodex
                    let kind = tool == "claude" ? $prefs.petClaude : $prefs.petCodex
                    Toggle(tool == "claude" ? "Claude Code" : "Codex", isOn: on)
                    Picker(selection: kind) {
                        ForEach(PetKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        HStack(spacing: 6) {
                            PetView(color: tool == "claude" ? claudeColor : codexColor, mood: .calm, kind: kind.wrappedValue, fullness: 0.8, animate: false, size: 22)
                            Text("Mascot")
                        }
                    }
                    .pickerStyle(.segmented).disabled(!on.wrappedValue)
                }
                if prefs.tools.isEmpty { hint("Tắt cả hai thì không còn gì để hiện.") }
            }
            Section("Hiện ở đâu") {
                Picker("Notch (màn MacBook)", selection: notchStyle) {
                    ForEach(NotchStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Thẻ ở mép màn hình ngoài", selection: edgeStyle) {
                    ForEach(EdgeStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                hint(edgeStatus)
                Toggle("Menu bar  ·  C 60% · X 90%", isOn: $prefs.menuBar)
                Toggle("Bảng nổi chi tiết (biểu đồ, $)", isOn: $prefs.floating)
                hint("Rê chuột vào notch hoặc thẻ ở mép để mở bảng. Mục menu bar: click trái mở bảng, click phải ra menu.")
            }
            Section("Pet") {
                Toggle("Hiện pet (tắt = chỉ số)", isOn: $prefs.pet)
                Picker("Chuyển động", selection: $prefs.motion) {
                    Text("Có").tag(Motion.full); Text("Chỉ mở/đóng").tag(Motion.light); Text("Không").tag(Motion.off)
                }.pickerStyle(.segmented)
                hint(prefs.reduceMotion ? "macOS đang bật Giảm chuyển động nên không có hiệu ứng."
                                        : "Pet chỉ cử động khi bảng đang mở; thu gọn thì luôn đứng yên.")
            }
            Section("Cảnh báo") {
                Picker("Mức", selection: Binding(get: { prefs.preset }, set: { prefs.apply($0) })) {
                    ForEach(AlertPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                hint(presetSummary)
                DisclosureGroup("Tùy chỉnh", isExpanded: $custom) {
                    HStack {
                        Text("Báo khi vượt"); Spacer()
                        ForEach(Notifier.allThresholds, id: \.self) { t in
                            Toggle("\(t)%", isOn: Binding(
                                get: { prefs.thresholds.contains(t) },
                                set: { on in var th = prefs.thresholds; th.removeAll { $0 == t }; if on { th.append(t) }; prefs.thresholds = th.sorted() }))
                                .toggleStyle(.button).controlSize(.small)
                        }
                    }
                    Toggle("Sắp hết trước reset", isOn: $prefs.warnBeforeEmpty)
                    Stepper("Báo trước \(prefs.emptyMinutes) phút", value: $prefs.emptyMinutes, in: 15...120, step: 15).disabled(!prefs.warnBeforeEmpty)
                    toggle("Quota tuần sẽ không đủ tới reset", $prefs.warnWeek)
                    Toggle("Quota đã reset", isOn: $prefs.notifyReset)
                    Toggle("Tiêu nhanh bất thường", isOn: $prefs.warnAnomaly)
                    toggle("Session chạy lâu vừa xong", $prefs.taskDone)
                    toggle("Máy sắp hết RAM và có thứ để dọn, hoặc AI giữ ≥ \(Int(prefs.agentRAMGB)) GB: hiện thẻ gợi ý kèm pet (tối đa 1 lần/giờ)", $prefs.agentRAM)
                    Slider(value: $prefs.agentRAMGB, in: 2...32, step: 1).disabled(!prefs.agentRAM)
                    Toggle("Âm thanh", isOn: $prefs.sound)
                }
                HStack {
                    Button("Gửi thử thông báo") { model.notifier.post("TokenPet", "Thông báo hoạt động.", level: 2) }
                    Button("Nháy thử ở notch") { model.showPeek("Claude · 5 giờ đã dùng 80%", 1) }
                }
            }
            Section("Máy") {
                Stepper("Coi session là ngủ sau \(Int(prefs.idleHours)) giờ không dùng", value: $prefs.idleHours, in: 1...12, step: 1)
                toggle("Tự đóng session ngủ quá \(Int(prefs.autoCloseHours)) giờ (báo trước 5 phút, có nút Giữ)", $prefs.autoClose)
                Stepper("Sau \(Int(prefs.autoCloseHours)) giờ", value: $prefs.autoCloseHours, in: 2...24, step: 1).disabled(!prefs.autoClose)
                hint("Mỗi session claude/codex là một process 40–300 MB cộng MCP server và LSP riêng của nó. Đóng = thoát process trong tab đó, mở lại bằng claude --resume. \"Process bỏ quên\" là dev server agent chạy nền rồi quên: shell cha đã thoát nên đóng tab không tắt được, TokenPet dọn theo cả cây. Không có gì tự đóng trừ khi bật ở trên. Phím tắt ⌃⌥M mở bảng Máy từ bất kỳ đâu; bấm dòng \"AI giữ…\" trong bảng quota hoặc chuột phải menu bar cũng được.")
                let m = model.machine
                Button("Mở bảng Máy…  ⌃⌥M") { AppDelegate.shared?.openMachine() }
                if !m.sessions.isEmpty || !m.leftovers.isEmpty {
                    hint("Hiện tại: AI giữ \(fmtMB(m.aiMB)) · \(m.sessions.count) session (\(m.idle(prefs.idleHours).count) ngủ) · \(m.leftovers.count) bỏ quên · RAM còn \(m.freePct)%")
                }
            }
            Section("Dữ liệu") {
                toggle("Lấy quota từ server (Claude + Codex)", Binding(get: { model.serverQuota }, set: { _ in model.toggleServer() }))
                hint("Chỉ đọc, dùng đăng nhập sẵn có của Claude Code / Codex. Không bật thì Codex đọc từ log, Claude cần statusline (\(model.statuslineEnabled ? "đang bật" : "chưa bật: chạy enable-claude-quota.sh")).")
                if let e = model.claudeSrv.error, model.serverQuota { Text("Claude: \(e)").font(.caption).foregroundStyle(.orange) }
                if let e = model.codexSrv.error, model.serverQuota { Text("Codex: \(e)").font(.caption).foregroundStyle(.orange) }
                Toggle("Mở TokenPet khi đăng nhập", isOn: $login)
                    .onChange(of: login) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = "" }
                        catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                    }
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Thư mục dữ liệu") { NSWorkspace.shared.open(supportDir) }
                    Button("Bảng giá API") { NSWorkspace.shared.open(model.pricing.url) }
                    Spacer()
                }
                hint("TokenPet đang dùng \(fmtMB(selfMB)) RAM" + (model.machine.aiMB > 0 ? " · AI \(fmtMB(model.machine.aiMB))" : "") + ".")
            }
        }
        .formStyle(.grouped)
        .frame(width: unframed ? nil : 500, height: unframed ? nil : 620)      // grouped Form wants ≥ 490; the form scrolls
        .onAppear { selfMB = footprintMB() }
    }

    /// Says where the edge tab actually is right now, so turning it on never looks like nothing happened.
    var edgeStatus: String {
        if !prefs.edgeDock {
            return "Một thẻ nhỏ có hai mascot dính ở mép màn hình, rê chuột vào là bảng trượt ra. Hiện trên mọi màn hình, kể cả màn có notch."
        }
        let n = NSScreen.screens.count
        return "Đang hiện ở mép \(prefs.edgeRight ? "phải" : "trái")\(n > 1 ? " của \(n) màn hình" : ""), cách mép trên 120 pt. Rê chuột vào thẻ để mở bảng."
    }
    /// A Toggle whose label may wrap: a long one-line label would otherwise widen the whole form past the window.
    func toggle(_ t: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { Text(t).fixedSize(horizontal: false, vertical: true) }
    }
    func hint(_ t: String) -> some View { Text(t).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    /// One sentence that says what the chosen level actually does.
    var presetSummary: String {
        var parts: [String] = []
        if !prefs.thresholds.isEmpty { parts.append("vượt " + prefs.thresholds.map { "\($0)%" }.joined(separator: "/")) }
        if prefs.warnBeforeEmpty { parts.append("sắp hết < \(prefs.emptyMinutes) phút") }
        if prefs.warnWeek { parts.append("tuần không đủ") }
        if prefs.notifyReset { parts.append("reset") }
        if prefs.warnAnomaly { parts.append("tiêu bất thường") }
        if prefs.taskDone { parts.append("session xong") }
        if prefs.agentRAM { parts.append("máy nặng vì AI") }
        let what = parts.isEmpty ? "Không báo gì." : "Báo khi: " + parts.joined(separator: ", ") + "."
        return what + (prefs.preset == .all ? " Tất cả lên thông báo macOS." : " Chỉ việc cần làm ngay lên thông báo macOS, còn lại nháy ở notch.")
    }
}
