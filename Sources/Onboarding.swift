// First run: three short pages, every one skippable, nothing asked before it is explained.
// HIG onboarding.md: "fast, fun, and optional", "teach through interactivity" (page 2 waits for the real
// glance to open), "postpone nonessential setup" (surfaces, pets and alert levels stay in Settings),
// permissions "in context" (Keychain and notifications are asked by the switch that needs them).
import SwiftUI
import AppKit
import ServiceManagement

enum ClaudeSource: Int { case server, statusline, later }

struct OnboardingView: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    @State var page = 0
    @State var opened = false                 // the user opened the real glance while on page 2
    @State private var source: ClaudeSource = .later
    @State private var notify = false
    @State private var notifyDenied = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var error = ""
    var snapshot = false
    var onDone: (_ finished: Bool) -> Void = { _ in }

    static let size = CGSize(width: 520, height: 600)
    private let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            stage.padding(.horizontal, 24).padding(.top, 24)
            VStack(alignment: .leading, spacing: 0) {
                switch page {
                case 0: welcome
                case 1: tryIt
                default: setup
                }
            }
            .padding(.horizontal, 32).padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            source = model.serverQuota ? .server : (StatuslineHook.enabled ? .statusline : (AppInfo.hasClaude || AppInfo.hasCodex ? .server : .later))
            notify = model.notifier.granted
        }
        .onReceive(NotificationCenter.default.publisher(for: .glanceOpened)) { _ in
            if page == 1 { withAnimation(prefs.transitions ? .easeOut(duration: 0.25) : nil) { opened = true } }
        }
    }

    // MARK: stage: a small screen top with the notch, the thing the app is about

    private var stage: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.11))
            HStack(spacing: 0) {
                PetRing(color: claudeColor, used: 62, level: 0, mood: .calm, animate: false, size: 20, showPet: prefs.pet, kind: prefs.petClaude).frame(width: 38)
                Spacer().frame(width: 96)
                PetRing(color: codexColor, used: 35, level: 0, mood: .busy, animate: false, size: 20, showPet: prefs.pet, kind: prefs.petCodex).frame(width: 38)
            }
            .frame(height: 28)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous).fill(Color.black))
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
            // Static on purpose: two animated pets cost 12–24% CPU for as long as this window stays open.
            Group {
                if page == 1 {
                    Image(systemName: opened ? "checkmark.circle.fill" : "cursorarrow.rays")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityHidden(true)
                } else {
                    HStack(spacing: 22) {
                        PetView(color: claudeColor, mood: page == 0 ? .calm : .busy, kind: prefs.petClaude, fullness: 0.9, animate: false, size: 58)
                        PetView(color: codexColor, mood: .calm, kind: prefs.petCodex, fullness: 0.9, animate: false, size: 58)
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 28)
        }
        .frame(height: 150)
    }

    // MARK: pages

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 22, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
    private func lead(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
    }
    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func card<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) { v() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L("Meet TokenPet", "Chào, đây là TokenPet"))
            lead(L("Two pets beside the notch show how much memory your coding agents hold on this Mac, and how much Claude Code and Codex quota is left before the next reset.", "Hai con pet cạnh notch cho biết agent đang giữ bao nhiêu RAM của máy, và quota Claude Code, Codex còn bao nhiêu trước lần reset tới."))
            card {
                found("Claude Code", AppInfo.hasClaude, claudeColor)
                Divider().padding(.leading, 40)
                found("Codex", AppInfo.hasCodex, codexColor)
            }
            .padding(.top, 20)
            note(AppInfo.hasClaude || AppInfo.hasCodex
                 ? L("TokenPet only reads the logs and state these two tools already keep on your Mac. No account, nothing sent anywhere.", "TokenPet chỉ đọc log và trạng thái mà hai công cụ này đã lưu trên máy bạn. Không có tài khoản, không gửi gì đi đâu.")
                 : L("Neither tool found yet. Carry on: numbers appear once you use Claude Code or Codex.", "Chưa thấy công cụ nào. Cứ cài tiếp: khi bạn dùng Claude Code hoặc Codex, số liệu sẽ tự hiện."))
                .padding(.top, 10)
        }
    }
    private func found(_ name: String, _ ok: Bool, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10).frame(width: 18)
            Text(name).font(.system(size: 13, weight: .medium))
            Spacer()
            Label(ok ? L("Found on this Mac", "Đã thấy trên máy này") : L("Not found", "Chưa thấy"), systemImage: ok ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 12)).foregroundStyle(ok ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    /// Where the glance lives right now, in the words of the thing the user has to do.
    var whereText: (title: String, how: String) {
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        if prefs.notch && hasNotch { return (L("Rest the pointer on the notch, or click it", "Dừng chuột trên notch, hoặc bấm vào nó"), L("Hold the pointer still for a moment on the notch at the top of your MacBook's screen, or click it. The quota panel opens, and closes by itself when the pointer leaves.", "Dừng chuột một chút trên notch ở mép trên màn hình MacBook, hoặc bấm vào nó. Bảng quota mở ra, rời chuột là nó tự thu lại.")) }
        if prefs.edgeDock { return (L("Click the tab at the \(prefs.edgeRight ? "right" : "left") edge", "Bấm vào thẻ ở mép \(prefs.edgeRight ? "phải" : "trái")"),
                                    L("There is no notch on this screen, so TokenPet sits in a small tab at the \(prefs.edgeRight ? "right" : "left") edge. Click it and the panel slides out; drag it up or down if it is in the way.",
                                      "Màn hình này không có notch nên TokenPet nằm ở một thẻ nhỏ sát mép \(prefs.edgeRight ? "phải" : "trái"). Bấm vào là bảng trượt ra; kéo lên xuống nếu nó vướng.")) }
        return (L("Click TokenPet in the menu bar", "Bấm vào mục TokenPet trên menu bar"), L("Look for “C … · X …” on the right side of the menu bar and click it. Right-click for the menu.", "Tìm dòng “C … · X …” ở góc phải menu bar và bấm vào. Bấm chuột phải để ra menu."))
    }
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(opened ? L("That's it, the panel lives there", "Đúng rồi, bảng nằm ở đó") : L("Try it: ", "Thử ngay: ") + whereText.title.prefix(1).lowercased() + whereText.title.dropFirst())
            lead(opened ? L("One card per tool: how much of the 5-hour and weekly quota is used, and when each resets. The ring around the pet is the % used; its face changes when you are almost out.", "Mỗi công cụ một thẻ: đã dùng bao nhiêu % của 5 giờ và của tuần, kèm giờ reset. Vòng quanh con pet là % đã dùng; mặt nó đổi khi sắp hết.")
                        : whereText.how)
            card {
                legend("circle.dotted", L("Ring around the pet", "Vòng quanh pet"), L("% of quota used, turning orange then red as it runs out", "% quota đã dùng, đổi cam rồi đỏ khi sắp hết"))
                Divider().padding(.leading, 40)
                legend("memorychip", L("Mac card in the panel", "Thẻ Máy trong bảng"), L("How much RAM agents hold; click to see it and clean up (⌃⌥M)", "AI đang giữ bao nhiêu RAM, bấm vào để xem và dọn (⌃⌥M)"))
                Divider().padding(.leading, 40)
                legend("gearshape", L("Settings at the bottom of the panel", "Cài đặt ở cuối bảng"), L("Where it shows (notch, screen edge, menu bar), pets, alert level", "Đổi chỗ hiện (notch, mép màn hình, menu bar), pet, mức cảnh báo"))
            }
            .padding(.top, 20)
        }
    }
    private func legend(_ icon: String, _ t: String, _ sub: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(t).font(.system(size: 13, weight: .medium))
                note(sub)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var sourceNote: String {
        switch source {
        case .server: return L("Most accurate: TokenPet uses the Claude Code and Codex logins already on this Mac to ask Anthropic and OpenAI directly, every 5 minutes, read-only. When you click Done, macOS asks for access to the “Claude Code-credentials” item in Keychain: choose Always Allow.", "Chính xác nhất: TokenPet dùng đăng nhập Claude Code và Codex có sẵn trên máy để hỏi thẳng Anthropic và OpenAI, 5 phút một lần, chỉ đọc. Khi bấm Xong, macOS sẽ hỏi quyền đọc mục “Claude Code-credentials” trong Keychain: chọn Luôn cho phép.")
        case .statusline: return L("No network calls: TokenPet wraps the statusLine command in ~/.claude/settings.json to receive the quota numbers Claude Code sends with it. Your status line looks the same; the original is backed up and restored when you turn this off.", "Không gọi mạng: TokenPet bọc lệnh statusline trong ~/.claude/settings.json để nhận số quota mà Claude Code gửi kèm. Statusline của bạn vẫn hiện như cũ, bản gốc được sao lưu và trả lại khi tắt.")
        case .later: return L("Codex still gets its numbers from logs on this Mac. The Claude card stays empty until you pick a source in Settings › Data.", "Codex vẫn có số từ log trên máy. Thẻ Claude sẽ trống cho tới khi bạn chọn một nguồn trong Cài đặt › Dữ liệu.")
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L("Where should quota numbers come from?", "Lấy số quota từ đâu?"))
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("Quota source", "Nguồn quota"), selection: $source) {
                        Text(L("Ask the servers (recommended)", "Hỏi server (khuyên dùng)")).tag(ClaudeSource.server)
                        Text(L("Read from the Claude Code status line", "Đọc từ statusline của Claude Code")).tag(ClaudeSource.statusline)
                        Text(L("Later", "Để sau")).tag(ClaudeSource.later)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    note(sourceNote)
                    if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(12)
            }
            .padding(.top, 14)
            card {
                switchRow(L("Notify when quota is almost out", "Báo khi sắp hết quota"), notifyDenied ? L("macOS is blocking TokenPet's notifications: turn them back on in System Settings › Notifications.", "macOS đang chặn thông báo của TokenPet: bật lại trong Cài đặt hệ thống › Thông báo.") : L("Only what needs action now becomes a notification; the rest blinks at the notch.", "Chỉ việc cần làm ngay mới thành thông báo, còn lại nháy ở notch."), $notify)
                    .onChange(of: notify) { on in
                        guard on, !model.notifier.granted else { return }
                        model.notifier.requestPermission { ok in notify = ok; notifyDenied = !ok }
                    }
                Divider().padding(.leading, 12)
                switchRow(L("Open TokenPet at login", "Mở TokenPet khi đăng nhập"), L("About 40 MB of RAM, near 0% CPU when nobody is looking.", "Khoảng 40 MB RAM, gần 0% CPU khi không ai nhìn."), $login)
                    .onChange(of: login) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { login = SMAppService.mainApp.status == .enabled }
                    }
            }
            .padding(.top, 10)
        }
    }
    private func switchRow(_ t: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t).font(.system(size: 13, weight: .medium))
                note(sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: footer

    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { k in
                    Circle().fill(k == page ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement().accessibilityLabel(L("Page \(page + 1) of \(pages)", "Trang \(page + 1) trên \(pages)"))
            HStack(spacing: 8) {
                if page < pages - 1 { Button(L("Skip", "Bỏ qua")) { onDone(false) }.keyboardShortcut(.cancelAction) }
                Spacer()
                if page > 0 { Button(L("Back", "Quay lại")) { go(page - 1) } }
                Button(page == pages - 1 ? L("Done", "Xong") : L("Continue", "Tiếp tục")) { page == pages - 1 ? finish() : go(page + 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
    private func go(_ p: Int) {
        error = ""
        withAnimation(prefs.transitions ? .easeInOut(duration: 0.2) : nil) { page = p }
    }
    private func finish() {
        switch source {
        case .server: if !model.serverQuota { model.toggleServer() }
        case .statusline:
            do { try StatuslineHook.enable(); model.objectWillChange.send() }
            catch let e as StatuslineHook.Failure { error = e.message; return }
            catch let e { error = e.localizedDescription; return }
        case .later: break
        }
        onDone(true)
    }
}
