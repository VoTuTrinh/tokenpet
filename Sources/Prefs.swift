// User settings, one place. Everything defaults to quiet and cheap.
import Foundation
import SwiftUI
import AppKit

enum Motion: Int, CaseIterable { case full = 0, light = 1, off = 2
    var label: String { ["Đầy đủ", "Nhẹ", "Tắt"][rawValue] }
}
enum PetKind: Int, CaseIterable { case blob = 0, cat = 1, ghost = 2, robot = 3
    var label: String { ["Blob", "Mèo", "Ma", "Robot"][rawValue] }
}
enum AlertPreset: String, CaseIterable { case quiet, balanced, all
    var label: String { ["quiet": "Im lặng", "balanced": "Cân bằng", "all": "Báo hết"][rawValue]! }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    private func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    // Surfaces
    @Published var notch: Bool { didSet { d.set(notch, forKey: "s.notch") } }
    @Published var notchEarsAlways: Bool { didSet { d.set(notchEarsAlways, forKey: "s.notchEars") } }
    @Published var edgeDock: Bool { didSet { d.set(edgeDock, forKey: "s.edge") } }
    @Published var edgeRight: Bool { didSet { d.set(edgeRight, forKey: "s.edgeRight") } }
    @Published var floating: Bool { didSet { d.set(floating, forKey: "s.floating") } }
    @Published var menuBar: Bool { didSet { d.set(menuBar, forKey: "s.menubar") } }
    // Tools
    @Published var showClaude: Bool { didSet { d.set(showClaude, forKey: "t.claude") } }
    @Published var showCodex: Bool { didSet { d.set(showCodex, forKey: "t.codex") } }
    @Published var petClaude: PetKind { didSet { d.set(petClaude.rawValue, forKey: "p.kind.claude") } }
    @Published var petCodex: PetKind { didSet { d.set(petCodex.rawValue, forKey: "p.kind.codex") } }
    /// Tools the user wants to see, in display order (Claude left, Codex right).
    var tools: [String] { (showClaude ? ["claude"] : []) + (showCodex ? ["codex"] : []) }
    func kind(_ tool: String) -> PetKind { tool == "claude" ? petClaude : petCodex }
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

    init() {
        notch = d.object(forKey: "s.notch") as? Bool ?? true
        notchEarsAlways = d.object(forKey: "s.notchEars") as? Bool ?? true
        edgeDock = d.object(forKey: "s.edge") as? Bool ?? true
        edgeRight = d.object(forKey: "s.edgeRight") as? Bool ?? true
        floating = d.object(forKey: "s.floating") as? Bool ?? false
        menuBar = d.object(forKey: "s.menubar") as? Bool ?? true
        showClaude = d.object(forKey: "t.claude") as? Bool ?? true
        showCodex = d.object(forKey: "t.codex") as? Bool ?? true
        petClaude = PetKind(rawValue: d.integer(forKey: "p.kind.claude")) ?? .blob
        petCodex = PetKind(rawValue: d.object(forKey: "p.kind.codex") as? Int ?? 1) ?? .cat
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
        agentRAM = d.object(forKey: "a.agentRAM") as? Bool ?? false
        agentRAMGB = d.object(forKey: "a.agentRAMGB") as? Double ?? 6
        sound = d.object(forKey: "a.sound") as? Bool ?? true
    }

    func apply(_ p: AlertPreset) {
        preset = p
        switch p {
        case .quiet:    thresholds = [95]; warnBeforeEmpty = true; emptyMinutes = 30; warnWeek = false
                        notifyReset = false; warnAnomaly = false; taskDone = false; agentRAM = false; sound = false
        case .balanced: thresholds = [80, 95]; warnBeforeEmpty = true; emptyMinutes = 45; warnWeek = true
                        notifyReset = true; warnAnomaly = false; taskDone = false; agentRAM = false; sound = true
        case .all:      thresholds = [50, 70, 80, 90, 95]; warnBeforeEmpty = true; emptyMinutes = 60; warnWeek = true
                        notifyReset = true; warnAnomaly = true; taskDone = true; agentRAM = true; sound = true
        }
    }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Pet moves (breathing, blinking): only on "Đầy đủ" and when macOS Reduce Motion is off.
    var animates: Bool { pet && motion == .full && !reduceMotion }
    /// Surfaces slide/expand with animation; "Nhẹ" keeps these but freezes the pet.
    var transitions: Bool { motion != .off && !reduceMotion }
}
