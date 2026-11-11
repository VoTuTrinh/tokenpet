# TokenPet: handoff (2026-11-11, session 2)

Hand-off note, not a spec. The "Remaining work" of session 1 is done; what follows is the current state.

## What the user wants (unchanged)
- **Resource use is the top priority** and the selling point. Measured now (final build): 33 MB footprint, 0.1% CPU idle (see README "Resource budget").
- **Clean, balanced UI.** The user reacted to screenshots with "chưa đẹp", "cần cân đối hơn", "bị dính padding", "dài không cần thiết": content must not touch edges, columns must be symmetric, the closed notch ears must be no wider than their content. Look at `--snapshot` PNGs before claiming anything looks right.
- Mac-native surfaces (notch / edge dock / menu bar / optional floating panel), state-driven pet, low-noise alerts, Settings window. All exist now.
- The user writes Vietnamese; UI strings are Vietnamese.

## State of the code
- `main.swift`: `Model` (FSEvents-driven `refresh(changed:)`, 60 s `tick()` for countdowns/processes/server, 10-min full walk, separate `net` queue so a slow server never delays a log event, `statsWanted` so charts/$ are only built when the floating panel is on, `showPeek`). `AppDelegate` (`shared`, `openSettings()`, menu bar popover + right-click menu, floating panel on demand, `applyPrefs()` live). `--snapshot <dir> [--fake]` renders panel, glance, notch closed/peek/open, edge tab/open, pets.
- `Surfaces.swift`: `NotchShape` (flares drawn *outside* the rect, so the rect is the body), `NotchGeo` (ears 40/52, open 380×480), `NotchController` (hover → open, `model.$peek` → peek, grow-before/shrink-after frame strategy), `EdgeController`, `SurfaceManager` (one panel per screen, rebuilt on screen changes and surface prefs).
- `Settings.swift`: one page (the four-tab version was "khó hiểu quá"). Sections: Công cụ (per-tool on/off + `PetKind` picker with a live preview), Hiện ở đâu (notch: tai+bảng / chỉ bảng / tắt; cạnh: tắt / trái / phải; menu bar; floating), Pet, Cảnh báo (preset + generated one-line summary, details under "Tùy chỉnh"), Dữ liệu. Fixed 460×600, dropped when closed. AppKit `Form` does not render in `ImageRenderer`, so check it live: `kill -USR1 <pid>`.
- `Glance.swift`: after many rounds with the user ("tôi chỉ cần biết 5h còn bao nhiêu, weekly bao nhiêu, khi nào reset", "k cần dự báo", "fable này kia chỉ là detail", "bỏ 2 con số % bên ngoài", "giữ 2 con mascot bên ngoài"): `ToolCardView` = mascot column + `StatTile` for `tool.5h` and `tool.week` only (label, % used, bar, "↻ CN 00:05 · 3d 0h"). `Model.mainRows` synthesises a 0% "chưa dùng" tile when a source omits a window (Claude Code's statusline and both servers leave out an untouched window; the user read the missing tile as "không đồng bộ"). "Chi tiết" (persisted in `glanceDetails`, turns on `statsWanted`) folds out `DetailRow`s for per-model/extra limits, the servers' `extra` strings, and the last 24 h of tokens/$ (not "today": at 00:10 that read 0 and confused the user). No forecast text in the glance; `Insight.headline` only feeds notifications, worded "sẽ hết ~…" (the user asked what "cạn" meant).
- `Prefs.tools` (enabled tools, Claude first) drives the cards, the notch ears, the edge tab, the menu bar title and `Model.worst`. `Prefs.kind(tool)` picks the `PetKind` (blob / cat / ghost / robot: same face, different silhouette in `PetView.bodyPath`).
- Closed notch: `PetRing` (mascot inside, arc = %) either side, 38 pt ears, no numbers. Edge tab: the same rings stacked. Pet animates only in the open glance, 8 fps. Menu bar popover is 420 wide with an opaque black background (vibrancy washed it out: "sao tắt").
- `SurfaceManager.rebuild()` must call `close()` on each controller: the hosting view's root holds the controller, so `deinit` never runs. Before this fix every settings change leaked a window (the user saw tabs on both edges). `apply()` compares a signature of prefs + tools + screen frames so fullscreen toggles do not rebuild.
- `Limits.swift`: `LimitStore` JSON work wrapped in `autoreleasepool`. This was a 57 MB leak: `rewrite()` ran at init, before `app.run()`, where top-level code has no pool. `AppDelegate()` is created inside `autoreleasepool` for the same reason.
- `Pet.swift`: `fps` parameter (12). `Prefs.swift`: `animates` (pet moves, only on "Đầy đủ") vs `transitions` (surfaces slide, off on "Tắt" or Reduce Motion).

## Decisions made this session
- Collapsed surfaces **never** animate, not even at level 2: two 10-fps pets measured 12% CPU. The alarmed face is static; the peek line carries the urgency.
- Ears show one tool only (the one closest to its limit); the glance shows both.
- Edge dock is used on any screen that does not get a notch surface (no notch, or notch disabled).
- Menu bar item is forced visible if every other surface is off, so Settings stays reachable.

## Not verified (needs a human)
- Hover timing/feel and the collapse delay (0.35 s); the edge dock card position (120 pt below the menu bar, right edge); fullscreen apps; what happens when the LG is unplugged (there is a 0.5 s debounced rebuild).
- Launch at login via `SMAppService` was not exercised.
- The user has server quota ON. Every rebuild changes the ad-hoc signature and macOS asks for the Keychain again; the user must click "Always Allow" once per build. `--snapshot`/`--bench` never touch the Keychain.
- Simulated mouse moves (CGEvent without Accessibility trust) do not trigger `.onHover`; the user confirmed hover with a real mouse. Peek was verified with `kill -USR2`.

## Hazards
- Not a git repo. Original backup: `/private/tmp/claude-501/-Users-kitemetric-Projects-Personal/174a19e8-4c1f-45a6-899f-f129bd152a97/scratchpad/tokenpet-baseline/`.
- `build.sh` deletes `build/TokenPet.app`; quit the running instance first. Only one GUI instance at a time (both would write `quota-history.jsonl`).
- Iterate with `swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift -o <scratch>`; `--selftest` must stay ALL PASS.
- Do not install hooks in `~/.claude/settings.json`.
