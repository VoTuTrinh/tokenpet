// Settings: seven decisions on one page, each with a default that suits most people. Everything else
// (extra surfaces, alert details, cleanup thresholds, data sources) is under "Advanced", closed until asked for.
// Plain NSWindow + NSHostingController (manual NSApplication, macOS 13 target); dropped when closed.
import SwiftUI
import AppKit
import ServiceManagement

/// Where the glance lives. One choice instead of a switch per surface; the edge tab and the floating panel
/// are extras under Advanced.
enum Place: Int, CaseIterable { case notch, menuBar, both
    var label: String { [L("Notch", "Notch"), L("Menu bar", "Menu bar"), L("Both", "Cả hai")][rawValue] }
}
enum EdgeStyle: Int, CaseIterable { case off, left, right
    var label: String { [L("Off", "Tắt"), L("Left", "Trái"), L("Right", "Phải")][rawValue] }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    @State private var advanced = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var selfMB = footprintMB()
    @State private var statusline = StatuslineHook.enabled
    @State private var statuslineError = ""
    @State private var updateText = ""
    @State private var updatePage: URL?
    @State private var checking = false
    var unframed = false          // --settings-size: measure the form's own ideal width
    var showAdvanced = false      // --snapshot: render the long form

    var place: Binding<Place> {
        Binding(get: { prefs.notch ? (prefs.menuBar ? .both : .notch) : .menuBar },
                set: { prefs.notch = $0 != .menuBar; prefs.menuBar = $0 != .notch })
    }
    var edgeStyle: Binding<EdgeStyle> {
        Binding(get: { prefs.edgeDock ? (prefs.edgeRight ? .right : .left) : .off },
                set: { prefs.edgeDock = $0 != .off; if $0 != .off { prefs.edgeRight = $0 == .right } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Claude Code", isOn: $prefs.showClaude)
                Toggle("Codex", isOn: $prefs.showCodex)
                if prefs.tools.isEmpty { hint(L("With both off there is nothing to show.", "Tắt cả hai thì không còn gì để hiện.")) }
            } header: { Text(L("Track", "Theo dõi")) }
            Section {
                Picker(L("Show in", "Hiện ở"), selection: place) {
                    ForEach(Place.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                hint(placeStatus)
                toggle(L("Mascot", "Mascot"), $prefs.pet)
                hint(L("Its face is the state and the ring around it is the quota used. Off shows the number inside the ring instead.",
                       "Mặt nó là trạng thái, vòng quanh nó là quota đã dùng. Tắt thì hiện con số trong vòng tròn."))
            } header: { Text(L("Appearance", "Hiển thị")) }
            Section {
                Picker(L("Level", "Mức"), selection: Binding(get: { prefs.preset }, set: { prefs.apply($0) })) {
                    ForEach(AlertPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                hint(presetSummary)
            } header: { Text(L("Alerts", "Cảnh báo")) }
            Section {
                toggle(L("Ask Anthropic and OpenAI for your quota", "Hỏi Anthropic và OpenAI về quota của bạn"),
                       Binding(get: { model.serverQuota }, set: { _ in model.toggleServer() }))
                hint(L("Read-only, every 5 minutes, with the logins Claude Code and Codex already saved on this Mac. macOS asks for Keychain access once: choose Always Allow.",
                       "Chỉ đọc, 5 phút một lần, bằng đăng nhập mà Claude Code và Codex đã lưu trên máy. macOS hỏi quyền Keychain một lần: chọn Luôn cho phép."))
                if let e = model.claudeSrv.error, model.serverQuota { Text("Claude: \(e)").font(.caption).foregroundStyle(.orange) }
                if let e = model.codexSrv.error, model.serverQuota { Text("Codex: \(e)").font(.caption).foregroundStyle(.orange) }
                Toggle(L("Open TokenPet at login", "Mở TokenPet khi đăng nhập"), isOn: $login)
                    .onChange(of: login) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = "" }
                        catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                    }
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
            } header: { Text(L("Data", "Dữ liệu")) }

            Section {
                DisclosureGroup(L("Advanced", "Nâng cao"), isExpanded: $advanced) {}
            }
            if advanced || showAdvanced { advancedSections }

            Section {
                HStack {
                    Text("TokenPet \(AppInfo.version)")
                    Spacer()
                    if let page = updatePage { Button(L("Get the new version", "Tải bản mới")) { NSWorkspace.shared.open(page) } }
                    else if !AppInfo.repository.isEmpty { Button(checking ? L("Checking…", "Đang kiểm tra…") : L("Check for updates", "Kiểm tra bản mới")) { checkUpdate() }.disabled(checking) }
                }
                if !updateText.isEmpty { hint(updateText) }
                HStack {
                    Button(L("Quick tour", "Hướng dẫn nhanh")) { AppDelegate.shared?.openOnboarding() }
                    if let home = AppInfo.homepage { Button(L("Website", "Trang chủ")) { NSWorkspace.shared.open(home) } }
                    Spacer()
                    Button(L("Uninstall…", "Gỡ TokenPet…"), role: .destructive) { Uninstaller.confirmAndRun() }
                    Button(L("Quit TokenPet", "Thoát TokenPet")) { NSApp.terminate(nil) }
                }
                hint(L("Using \(fmtMB(selfMB)) of RAM. Goes online only for the quota switch above and when you press Check for updates.",
                       "Đang dùng \(fmtMB(selfMB)) RAM. Chỉ ra mạng khi bật công tắc quota ở trên và khi bạn bấm Kiểm tra bản mới."))
            } header: { Text(L("About", "Giới thiệu")) }
        }
        .formStyle(.grouped)
        .frame(width: unframed ? nil : 500, height: unframed ? nil : 600)      // grouped Form wants ≥ 490; the form scrolls
        .onAppear { selfMB = footprintMB() }
    }

    // MARK: advanced

    @ViewBuilder var advancedSections: some View {
        Section {
            toggle(L("Keep the pets beside the notch (off: nothing shows until you point at the notch)",
                     "Luôn hiện pet cạnh notch (tắt: không hiện gì cho tới khi rê chuột lên notch)"), $prefs.notchEarsAlways)
                .disabled(!prefs.notch)
            toggle(L("Show the % beside the pets at the notch (wider: may cover menu bar items)", "Hiện % cạnh pet ở notch (rộng hơn: có thể che mục trên menu bar)"), $prefs.notchNumbers)
                .disabled(!prefs.notch || !prefs.notchEarsAlways || !prefs.pet)
            Picker(L("Tab on the screen edge", "Thẻ ở mép màn hình"), selection: edgeStyle) {
                ForEach(EdgeStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            hint(edgeStatus)
            toggle(L("Floating panel with charts and API-equivalent cost", "Bảng nổi có biểu đồ và chi phí quy đổi API"), $prefs.floating)
            toggle(L("Pet moves while the panel is open", "Pet cử động khi bảng đang mở"),
                   Binding(get: { prefs.motion == .full }, set: { prefs.motion = $0 ? .full : .light }))
            hint(prefs.reduceMotion ? L("macOS Reduce Motion is on, so nothing moves.", "macOS đang bật Giảm chuyển động nên không có gì cử động.")
                                    : L("Collapsed, nothing ever moves.", "Lúc thu gọn thì không có gì cử động."))
            ForEach(["claude", "codex"], id: \.self) { tool in
                Picker(selection: tool == "claude" ? $prefs.petClaude : $prefs.petCodex) {
                    ForEach(PetKind.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    HStack(spacing: 6) {
                        PetView(color: tool == "claude" ? claudeColor : codexColor, mood: .calm, kind: prefs.kind(tool), fullness: 0.8, animate: false, size: 22)
                        Text(tool == "claude" ? "Claude" : "Codex")
                    }
                }
                .pickerStyle(.segmented).disabled(!prefs.pet)
            }
            Picker(L("Language", "Ngôn ngữ"), selection: $prefs.lang) {
                Text(L("System", "Theo máy")).tag(""); Text("English").tag("en"); Text("Tiếng Việt").tag("vi")
            }
        } header: { Text(L("More places and motion", "Chỗ hiện khác và chuyển động")) }
        Section {
            HStack {
                Text(L("Warn at", "Báo khi vượt")); Spacer()
                ForEach(Notifier.allThresholds, id: \.self) { t in
                    Toggle("\(t)%", isOn: Binding(
                        get: { prefs.thresholds.contains(t) },
                        set: { on in var th = prefs.thresholds; th.removeAll { $0 == t }; if on { th.append(t) }; prefs.thresholds = th.sorted() }))
                        .toggleStyle(.button).controlSize(.small)
                }
            }
            Toggle(L("About to run out before reset", "Sắp hết trước reset"), isOn: $prefs.warnBeforeEmpty)
            Stepper(L("\(prefs.emptyMinutes) minutes ahead", "Báo trước \(prefs.emptyMinutes) phút"), value: $prefs.emptyMinutes, in: 15...120, step: 15).disabled(!prefs.warnBeforeEmpty)
            toggle(L("The week will not last until reset", "Quota tuần sẽ không đủ tới reset"), $prefs.warnWeek)
            Toggle(L("Quota has reset", "Quota đã reset"), isOn: $prefs.notifyReset)
            Toggle(L("Unusually fast burn", "Tiêu nhanh bất thường"), isOn: $prefs.warnAnomaly)
            toggle(L("A long session just finished", "Session chạy lâu vừa xong"), $prefs.taskDone)
            toggle(L("The Mac is short on RAM and there is something to close, or agents hold ≥ \(Int(prefs.agentRAMGB)) GB (at most once an hour)",
                     "Máy sắp hết RAM và có thứ để dọn, hoặc AI giữ ≥ \(Int(prefs.agentRAMGB)) GB (tối đa 1 lần/giờ)"), $prefs.agentRAM)
            Slider(value: $prefs.agentRAMGB, in: 2...32, step: 1).disabled(!prefs.agentRAM)
            Toggle(L("Sound", "Âm thanh"), isOn: $prefs.sound)
            HStack {
                Button(L("Send a test notification", "Gửi thử thông báo")) { model.notifier.post("TokenPet", L("Notifications work.", "Thông báo hoạt động."), level: 2) }
                Button(L("Test the notch line", "Nháy thử ở notch")) { model.showPeek(L("Claude · 5-hour limit 80% used", "Claude · 5 giờ đã dùng 80%"), 1) }
            }
        } header: { Text(L("Alert details", "Chi tiết cảnh báo")) }
        Section {
            Stepper(L("A session is asleep after \(Int(prefs.idleHours)) h unused", "Coi session là ngủ sau \(Int(prefs.idleHours)) giờ không dùng"), value: $prefs.idleHours, in: 1...12, step: 1)
            toggle(L("Close sessions asleep for more than \(Int(prefs.autoCloseHours)) h by itself (5-minute warning with a Keep button)",
                     "Tự đóng session ngủ quá \(Int(prefs.autoCloseHours)) giờ (báo trước 5 phút, có nút Giữ)"), $prefs.autoClose)
            Stepper(L("After \(Int(prefs.autoCloseHours)) h", "Sau \(Int(prefs.autoCloseHours)) giờ"), value: $prefs.autoCloseHours, in: 2...24, step: 1).disabled(!prefs.autoClose)
            hint(L("Nothing is ever closed without a click unless the switch above is on. A closed session comes back with claude --resume.",
                   "Không có gì bị đóng nếu bạn không bấm, trừ khi bật công tắc trên. Session đã đóng mở lại bằng claude --resume."))
            Button(L("Open the Mac window…  ⌃⌥M", "Mở bảng Máy…  ⌃⌥M")) { AppDelegate.shared?.openMachine() }
        } header: { Text(L("Cleanup", "Dọn máy")) }
        Section {
            toggle(L("Read Claude's quota from the Claude Code status line (no network)", "Đọc quota Claude từ statusline của Claude Code (không gọi mạng)"), $statusline)
                .onChange(of: statusline) { on in
                    do { if on { try StatuslineHook.enable() } else { try StatuslineHook.disable() }; statuslineError = "" }
                    catch let e as StatuslineHook.Failure { statuslineError = e.message; statusline = StatuslineHook.enabled }
                    catch { statusline = StatuslineHook.enabled }
                }
            hint(L("Wraps the statusLine command in ~/.claude/settings.json; your status line looks the same and the original is restored when you turn this off.",
                   "Bọc lệnh statusLine trong ~/.claude/settings.json; statusline vẫn hiện như cũ, tắt là trả lại bản gốc."))
            if !statuslineError.isEmpty { Text(statuslineError).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L("Data folder", "Thư mục dữ liệu")) { NSWorkspace.shared.open(supportDir) }
                Button(L("API price table", "Bảng giá API")) { NSWorkspace.shared.open(model.pricing.url) }
                Spacer()
            }
        } header: { Text(L("Other data sources", "Nguồn dữ liệu khác")) }
    }

    func checkUpdate() {
        checking = true; updateText = ""
        UpdateCheck.run { r in
            checking = false
            switch r {
            case .upToDate: updateText = L("You have the latest version.", "Bạn đang dùng bản mới nhất.")
            case .newer(let v, let page): updateText = L("Version \(v) is available.", "Có bản \(v)."); updatePage = page
            case .failed(let why): updateText = L("Could not check: \(why)", "Chưa kiểm tra được: \(why)")
            }
        }
    }

    /// Says where TokenPet actually is right now, so a choice never looks like nothing happened.
    var placeStatus: String {
        if prefs.notch && !prefs.hasNotchScreen {
            return L("No notch on the screens connected now: TokenPet shows as a tab on the screen edge, or in the menu bar if that tab is off.",
                     "Các màn hình đang nối không có notch: TokenPet hiện ở thẻ mép màn hình, hoặc ở menu bar nếu thẻ đó tắt.")
        }
        switch place.wrappedValue {
        case .notch: return L("Rest the pointer on the notch, or click it, to open the panel.", "Dừng chuột trên notch, hoặc bấm vào, để mở bảng.")
        case .menuBar: return L("Click the item for the panel, right-click for the menu.", "Bấm vào mục để mở bảng, bấm phải ra menu.")
        case .both: return L("Notch on the MacBook screen, plus a menu bar item on every screen.", "Notch trên màn MacBook, thêm một mục menu bar trên mọi màn hình.")
        }
    }
    var edgeStatus: String {
        if !prefs.edgeDock {
            return L("A small tab on the side of every screen; click it and the panel slides out, drag it to move it up or down.",
                     "Một thẻ nhỏ ở cạnh mọi màn hình; bấm vào là bảng trượt ra, kéo để dời lên xuống.")
        }
        let n = NSScreen.screens.count
        return L("Showing on the \(prefs.edgeRight ? "right" : "left") edge\(n > 1 ? " of \(n) screens" : ""). Click it to open; drag it up or down.",
                 "Đang hiện ở mép \(prefs.edgeRight ? "phải" : "trái")\(n > 1 ? " của \(n) màn hình" : ""). Bấm để mở; kéo để dời lên xuống.")
    }
    /// A Toggle whose label may wrap: a long one-line label would otherwise widen the whole form past the window.
    func toggle(_ t: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { Text(t).fixedSize(horizontal: false, vertical: true) }
    }
    func hint(_ t: String) -> some View { Text(t).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    /// One sentence that says what the chosen level actually does.
    var presetSummary: String {
        var parts: [String] = []
        if !prefs.thresholds.isEmpty { parts.append(L("passing ", "vượt ") + prefs.thresholds.map { "\($0)%" }.joined(separator: "/")) }
        if prefs.warnBeforeEmpty { parts.append(L("out in < \(prefs.emptyMinutes) min", "sắp hết < \(prefs.emptyMinutes) phút")) }
        if prefs.warnWeek { parts.append(L("week won't last", "tuần không đủ")) }
        if prefs.notifyReset { parts.append("reset") }
        if prefs.warnAnomaly { parts.append(L("unusual burn", "tiêu bất thường")) }
        if prefs.taskDone { parts.append(L("session done", "session xong")) }
        if prefs.agentRAM { parts.append(L("Mac short on RAM", "máy nặng vì AI")) }
        let what = parts.isEmpty ? L("No alerts.", "Không báo gì.") : L("Tells you about: ", "Báo khi: ") + parts.joined(separator: ", ") + "."
        return what + " " + (prefs.preset == .all ? L("All of them become macOS notifications.", "Tất cả lên thông báo macOS.")
                                                   : L("Only what needs you now becomes a macOS notification; the rest is one line under the notch.", "Chỉ việc cần làm ngay lên thông báo macOS, còn lại nháy ở notch."))
            + (prefs.sound ? "" : L(" No sound.", " Không âm thanh."))
    }
}
