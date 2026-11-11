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
                    HStack(spacing: 10) {
                        Toggle(tool == "claude" ? "Claude Code" : "Codex", isOn: on).frame(width: 150, alignment: .leading)
                        Spacer()
                        PetView(color: tool == "claude" ? claudeColor : codexColor, mood: .calm, kind: kind.wrappedValue, fullness: 0.8, animate: false, size: 26)
                        Picker("", selection: kind) { ForEach(PetKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 200).disabled(!on.wrappedValue)
                    }
                }
                if prefs.tools.isEmpty { hint("Tắt cả hai thì không còn gì để hiện.") }
            }
            Section("Hiện ở đâu") {
                Picker("Notch (màn MacBook)", selection: notchStyle) {
                    ForEach(NotchStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Cạnh màn hình (màn không có notch)", selection: edgeStyle) {
                    ForEach(EdgeStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Menu bar  ·  C 60% · X 90%", isOn: $prefs.menuBar)
                Toggle("Bảng nổi chi tiết (biểu đồ, $)", isOn: $prefs.floating)
                hint("Rê chuột vào notch hoặc thẻ ở cạnh để mở bảng. Mục menu bar: click trái mở bảng, click phải ra menu.")
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
                    Toggle("Quota tuần sẽ không đủ tới reset", isOn: $prefs.warnWeek)
                    Toggle("Quota đã reset", isOn: $prefs.notifyReset)
                    Toggle("Tiêu nhanh bất thường", isOn: $prefs.warnAnomaly)
                    Toggle("Session chạy lâu vừa xong", isOn: $prefs.taskDone)
                    Toggle("Agent giữ ≥ \(Int(prefs.agentRAMGB)) GB RAM", isOn: $prefs.agentRAM)
                    Slider(value: $prefs.agentRAMGB, in: 2...32, step: 1).disabled(!prefs.agentRAM)
                    Toggle("Âm thanh", isOn: $prefs.sound)
                }
                HStack {
                    Button("Gửi thử thông báo") { model.notifier.post("TokenPet", "Thông báo hoạt động.", level: 2) }
                    Button("Nháy thử ở notch") { model.showPeek("Claude · 5 giờ đã dùng 80%", 1) }
                }
            }
            Section("Dữ liệu") {
                Toggle("Lấy quota từ server (Claude + Codex)", isOn: Binding(get: { model.serverQuota }, set: { _ in model.toggleServer() }))
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
                    Text("TokenPet \(fmtMB(selfMB))" + (model.procs.count > 0 ? "  ·  agent \(fmtMB(model.procs.footprintMB))" : ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)      // fits a MacBook screen; the form scrolls
        .onAppear { selfMB = footprintMB() }
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
        if prefs.agentRAM { parts.append("agent tốn RAM") }
        let what = parts.isEmpty ? "Không báo gì." : "Báo khi: " + parts.joined(separator: ", ") + "."
        return what + (prefs.preset == .all ? " Tất cả lên thông báo macOS." : " Chỉ việc cần làm ngay lên thông báo macOS, còn lại nháy ở notch.")
    }
}
