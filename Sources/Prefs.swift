// User settings, one place. Everything defaults to quiet and cheap.
import Foundation
import SwiftUI
import AppKit

enum Motion: Int, CaseIterable { case full = 0, light = 1, off = 2
    var label: String { [L("Full", "Đầy đủ"), L("Light", "Nhẹ"), L("Off", "Tắt")][rawValue] }
}
enum PetKind: Int, CaseIterable { case blob = 0, cat = 1, ghost = 2, robot = 3, spark = 4, knot = 5
    var label: String { ["Blob", L("Cat", "Mèo"), L("Ghost", "Ma"), "Robot", "✳︎", "⬡"][rawValue] }
    /// The last two are plain marks, not pets: no face, the ring and its colour carry the state.
    var isGlyph: Bool { self == .spark || self == .knot }
}
enum AlertPreset: String, CaseIterable { case quiet, balanced, all
    var label: String { ["quiet": L("Quiet", "Im lặng"), "balanced": L("Balanced", "Cân bằng"), "all": L("Everything", "Báo hết")][rawValue]! }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    private func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    // Surfaces
    @Published var notch: Bool { didSet { d.set(notch, forKey: "s.notch") } }
    @Published var notchEarsAlways: Bool { didSet { d.set(notchEarsAlways, forKey: "s.notchEars") } }
    /// The % beside each pet at the notch. Off by default: it widens each ear by 24 pt, and on a full menu bar
    /// that covers the app's menus on the left and status items on the right.
    @Published var notchNumbers: Bool { didSet { d.set(notchNumbers, forKey: "s.notchNum") } }
    @Published var edgeDock: Bool { didSet { d.set(edgeDock, forKey: "s.edge") } }
    @Published var edgeRight: Bool { didSet { d.set(edgeRight, forKey: "s.edgeRight") } }
    @Published var floating: Bool { didSet { d.set(floating, forKey: "s.floating") } }
    @Published var menuBar: Bool { didSet { d.set(menuBar, forKey: "s.menubar") } }
    // Tools
    @Published var showClaude: Bool { didSet { d.set(showClaude, forKey: "t.claude") } }
    @Published var showCodex: Bool { didSet { d.set(showCodex, forKey: "t.codex") } }
    @Published var petClaude: PetKind { didSet { d.set(petClaude.rawValue, forKey: "p.kind.claude") } }
    @Published var petCodex: PetKind { didSet { d.set(petCodex.rawValue, forKey: "p.kind.codex") } }
    func kind(_ tool: String) -> PetKind { tool == "claude" ? petClaude : petCodex }
    /// Tools the user wants to see, in display order (Claude left, Codex right).
    var tools: [String] { (showClaude ? ["claude"] : []) + (showCodex ? ["codex"] : []) }
    /// "" follows the Mac's language; "en" / "vi" pin it. Views that observe Prefs redraw at once.
    @Published var lang: String { didSet { d.set(lang, forKey: "lang"); Lang.override = lang } }
    // Pet
    @Published var pet: Bool { didSet { d.set(pet, forKey: "p.pet") } }
    @Published var motion: Motion { didSet { d.set(motion.rawValue, forKey: "p.motion") } }
    // Alerts
    @Published var preset: AlertPreset { didSet { d.set(preset.rawValue, forKey: "a.preset") } }
    @Published var thresholds: [Int] { didSet { d.set(thresholds.sorted(), forKey: "thresholds") } }
    @Published var warnBeforeEmpty: Bool { didSet { d.set(warnBeforeEmpty, forKey: "warnBeforeEmpty") } }
    @Published var emptyMinutes: Int { didSet { d.set(emptyMinutes, forKey: "a.emptyMin") } }
    @Published var warnWeek: Bool { didSet { d.set(warnWeek, forKey: "a.week") } }
    @Published var notifyReset: Bool { didSet { d.set(notifyReset, forKey: "notifyReset") } }
    @Published var warnAnomaly: Bool { didSet { d.set(warnAnomaly, forKey: "warnAnomaly") } }
    @Published var taskDone: Bool { didSet { d.set(taskDone, forKey: "a.taskDone") } }
    @Published var agentRAM: Bool { didSet { d.set(agentRAM, forKey: "a.agentRAM") } }
    @Published var agentRAMGB: Double { didSet { d.set(agentRAMGB, forKey: "a.agentRAMGB") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "a.sound") } }
    // Machine (sessions and leftover processes)
    @Published var idleHours: Double { didSet { d.set(idleHours, forKey: "m.idleH") } }
    @Published var autoClose: Bool { didSet { d.set(autoClose, forKey: "m.auto") } }
    @Published var autoCloseHours: Double { didSet { d.set(autoCloseHours, forKey: "m.autoH") } }

    init() {
        notch = d.object(forKey: "s.notch") as? Bool ?? true
        notchEarsAlways = d.object(forKey: "s.notchEars") as? Bool ?? true
        // One surface on a fresh install: the notch where there is one, otherwise the tab on the screen edge.
        edgeDock = d.object(forKey: "s.edge") as? Bool ?? !NSScreen.screens.contains { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
        edgeRight = d.object(forKey: "s.edgeRight") as? Bool ?? true
        notchNumbers = d.object(forKey: "s.notchNum") as? Bool ?? false
        floating = d.object(forKey: "s.floating") as? Bool ?? false
        menuBar = d.object(forKey: "s.menubar") as? Bool ?? false    // shown anyway when no other surface can be (menuBarVisible)
        showClaude = d.object(forKey: "t.claude") as? Bool ?? true
        showCodex = d.object(forKey: "t.codex") as? Bool ?? true
        petClaude = PetKind(rawValue: d.integer(forKey: "p.kind.claude")) ?? .blob
        petCodex = PetKind(rawValue: d.object(forKey: "p.kind.codex") as? Int ?? 1) ?? .cat
        lang = d.string(forKey: "lang") ?? ""
        pet = d.object(forKey: "p.pet") as? Bool ?? true
        motion = Motion(rawValue: d.integer(forKey: "p.motion")) ?? .full
        preset = AlertPreset(rawValue: d.string(forKey: "a.preset") ?? "") ?? .balanced
        thresholds = (d.array(forKey: "thresholds") as? [Int]) ?? [80, 95]
        warnBeforeEmpty = d.object(forKey: "warnBeforeEmpty") as? Bool ?? true
        emptyMinutes = d.object(forKey: "a.emptyMin") as? Int ?? 45
        warnWeek = d.object(forKey: "a.week") as? Bool ?? true
        notifyReset = d.object(forKey: "notifyReset") as? Bool ?? true
        warnAnomaly = d.object(forKey: "warnAnomaly") as? Bool ?? false
        taskDone = d.object(forKey: "a.taskDone") as? Bool ?? false
        agentRAM = d.object(forKey: "a.agentRAM") as? Bool ?? true
        agentRAMGB = d.object(forKey: "a.agentRAMGB") as? Double ?? 6
        sound = d.object(forKey: "a.sound") as? Bool ?? false        // silent unless the user asks for sound
        idleHours = d.object(forKey: "m.idleH") as? Double ?? 2
        autoClose = d.object(forKey: "m.auto") as? Bool ?? false
        autoCloseHours = d.object(forKey: "m.autoH") as? Double ?? 6
    }

    func apply(_ p: AlertPreset) {
        preset = p
        switch p {
        case .quiet:    thresholds = [95]; warnBeforeEmpty = true; emptyMinutes = 30; warnWeek = false
                        notifyReset = false; warnAnomaly = false; taskDone = false; agentRAM = false; sound = false
        case .balanced: thresholds = [80, 95]; warnBeforeEmpty = true; emptyMinutes = 45; warnWeek = true
                        notifyReset = true; warnAnomaly = false; taskDone = false; agentRAM = true; sound = false
        case .all:      thresholds = [50, 70, 80, 90, 95]; warnBeforeEmpty = true; emptyMinutes = 60; warnWeek = true
                        notifyReset = true; warnAnomaly = true; taskDone = true; agentRAM = true; sound = true
        }
    }
    /// A built-in display with a notch is connected right now (lid open).
    var hasNotchScreen: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } }
    /// The menu bar item shows when asked for, and whenever nothing else can show (no notch on this Mac, lid closed,
    /// every surface off): there is always exactly one way in, never zero.
    var menuBarVisible: Bool { menuBar || !((notch && hasNotchScreen) || edgeDock || floating) }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Pet moves (breathing, blinking): only on "Đầy đủ" and when macOS Reduce Motion is off.
    var animates: Bool { pet && motion == .full && !reduceMotion }
    /// Surfaces slide/expand with animation; "Nhẹ" keeps these but freezes the pet.
    var transitions: Bool { motion != .off && !reduceMotion }
}
