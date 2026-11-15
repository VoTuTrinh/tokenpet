# TokenPet — quota widget for Claude Code + Codex

A tiny macOS app that lives in the notch (or at a screen edge, or in the menu bar) and answers the questions developers ask about AI-coding quotas. It is cheap on purpose: ~33 MB and 0.05% CPU when idle, because it listens to log changes (FSEvents) instead of polling.

**Closed**, the notch gets a mascot on each side, Claude left and Codex right, each inside a ring whose arc is % used and whose colour is the level (no numbers, nothing moves). **Open**, it is one card per tool: the mascot, then two stat tiles, **5 giờ** and **Tuần**, each with % used, a thin bar, and the exact reset moment (day and time, plus how long until then); a window the tool has not touched yet shows "0% · chưa dùng". Running sessions appear underneath while they run. "Chi tiết" folds out per-model weeks (Fable, Sonnet, Opus), Codex's extra limits, what the servers add (where the week was spent, extra usage, credits, banked resets) and the last 24 hours of tokens with an API-equivalent $. The mascot's face is the state (calm, running, watch out, almost out, empty, asleep) and its body deflates as the quota goes; pick a species per tool (Blob, Mèo, Ma, Robot) and turn either tool off in Settings. Forecasts only drive notifications; the glance shows facts.

Surfaces (pick in Settings):
- **Notch** on the built-in screen: closed = small ears beside the notch (pet left, % right); an alert peeks as one line under the notch for a few seconds; hover opens the glance.
- **Edge dock** on screens without a notch: a thin tab with the pet face; hover slides the glance out.
- **Menu bar** item (`C 60% · X 90%`): click for the glance, right-click for refresh / settings / quit.
- **Floating panel** (off by default): the detailed view with charts and API-equivalent $.

The questions it is built around:

1. **Can I finish this task before I get cut off?** Shows % used and projects when you'll run out, both from the last hour's burn and from the weekly average. You get a notification before you run dry (< 45 min).
2. **Will the weekly quota last the week?** Shows % per remaining day, plus a tick on the bar marking where an even pace would be ("nhanh hơn nhịp đều X%").
3. **When does it come back?** Shows a reset countdown and notifies you when a heavily used window resets.
4. **Which limit stops me first?** The "Sát nhất" banner shows it. The panel lists every window: 5h, weekly all-models, per-model weekly (Fable, Sonnet, Opus), plus Codex's extra limits.
5. **Is the burn abnormal?** Compares the current %/h with your own median %/h over 14 days and flags anything ≥ 2×.
6. **Is something else eating my quota?** Shows server-side numbers, including where the weekly Claude quota was spent (Claude Code / chat / Cowork).
7. **Why is my Mac slow?** A third card in the glance, "Máy": a ring with AI's share of RAM, "AI đang giữ 6.9 GB", a bar split into running / open / asleep / leftover, one line of counts, and "Xem & dọn · lấy lại 2.0 GB". The whole card opens the "Máy" window (also ⌃⌥M or right-click the menu bar item): the pet whose face is the machine state, the number, one sentence of advice and a "Dọn hết · lấy lại X" button, then two groups by what to do, "Nên dọn" (sessions asleep ≥ 2 h, leftover processes nobody uses) and "Đang dùng, để yên", with the evidence on every row (terminal app and tty, path, pid, opened at, asleep since, process tree with sizes, what a leftover is: Next.js dev server, Expo, Python API…). Every `claude`/`codex` process with its whole tree (MCP servers, LSPs, shells, test runners), busy or asleep and for how long; "process bỏ quên": dev servers an agent started in the background and forgot (the shell exited, launchd adopted them, closing the tab no longer kills them) with their ports and age; RAM left and swap. Each row carries what a developer would check by hand: project path, terminal (ttys005), pid, opened at, asleep since, the process tree with sizes, ports, "shell cha đã thoát", "do agent chạy" when it came from a Claude scratchpad. "Đóng" / "Dọn" / "Dọn tất cả" open a confirm that names the pids and what happens (SIGTERM, then SIGKILL after 3 s; the terminal tab stays; `claude --resume` brings a session back); "Sao chép lệnh" copies the equivalent `kill` for people who prefer their own terminal. Nothing is ever killed without a click unless "Tự đóng session ngủ" is switched on in Settings (then a 5-minute warning with a "Giữ" button comes first). When the kernel reports memory pressure and there is something to clean (at most once an hour), a small card with the pet (worried, alarmed at critical) appears under the menu bar: "Máy sắp hết RAM", the three biggest things to close with what each gives back, "Xem & dọn" opens the window, "Để sau" dismisses. The menu bar title is untouched.

"Xem thêm" (secondary) holds API-equivalent tokens and $, top projects today, and 24h and 7-day charts.

## Data sources (freshest wins per window)
| Source | What | Notes |
|---|---|---|
| `~/.codex/sessions` logs | Codex 5h + weekly | local, no network |
| Claude statusLine payload | Claude 5h + weekly (all models) | opt-in via `enable-claude-quota.sh`; undo with `disable-claude-quota.sh` |
| Server (opt-in, right-click → "Lấy quota từ server") | Claude: 5h, weekly, per-model, extra usage, usage breakdown. Codex: 5h, weekly, extra limits, credits, banked resets | Read-only. Reuses the logins Claude Code/Codex already saved (Keychain item `Claude Code-credentials`, `~/.codex/auth.json`). Each token is sent only to its own vendor (`api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`). Never refreshes or writes credentials. Polls every 5 min and backs off on 429. These endpoints are undocumented, so field mapping follows [ai-usage-menubar's provider contracts](https://github.com/burakgon/ai-usage-menubar/blob/main/docs/provider-contracts.md). |

The quota history used for forecasts lives in `~/Library/Application Support/TokenPet/quota-history.jsonl` (21 days).

## Build / run
    ./build.sh                 # -> build/TokenPet.app (add --install to copy into /Applications)
    open build/TokenPet.app
    build/TokenPet.app/Contents/MacOS/TokenPet --dump [--server]   # print insights
    build/TokenPet.app/Contents/MacOS/TokenPet --probe             # print scrubbed server responses

    build/TokenPet.app/Contents/MacOS/TokenPet --snapshot <dir> --fake   # PNGs of every surface with demo data
    build/TokenPet.app/Contents/MacOS/TokenPet --bench                   # scan times, footprint, sessions, agent RAM
    build/TokenPet.app/Contents/MacOS/TokenPet --procs                   # the "Máy" census as text, to compare with ps/lsof
    build/TokenPet.app/Contents/MacOS/TokenPet --selftest                # forecast + notifier checks, and every Settings switch → its behaviour
    build/TokenPet.app/Contents/MacOS/TokenPet --settings-size           # the Settings form's ideal width (must fit the 500 pt window)

## Alerts
Low noise by default. Presets: **Im lặng** / **Cân bằng** (default) / **Báo hết**. "Cân bằng" means: crossing 80% and 95%, about to run out before reset (< 45 min), weekly won't last (at most once a day), hit the limit, and reset (only if it was ≥ 70%). Only "act now" alerts become macOS notifications; the rest just peek in the notch. "Máy nặng vì AI" (memory pressure plus idle sessions or leftover processes, or AI holding ≥ N GB) is on in "Cân bằng", at most once an hour. Abnormal burn and task-done are under "Tùy chỉnh" and off by default.

## Settings
Gear icon in the glance, or right-click the menu bar item. One page: tools (Claude / Codex on or off, mascot per tool), where to show (notch: ears + panel / panel on hover / off; screen edge: off / left / right; menu bar; floating panel), pet and motion, alert level with a one-line summary of what it does ("Tùy chỉnh" folds out the details), server quota, launch at login, data folder, pricing, and TokenPet's own RAM next to the agents'.

QA hooks: `kill -USR1 <pid>` opens Settings, `kill -USR2 <pid>` shows a test peek in the notch.

## Resource budget
Measured on an M-series MacBook Pro with ~26k log events: 33 MB footprint and 0.05% CPU after a minute idle. A log change costs a 0.2 ms rescan of only the changed files; the full walk runs at launch and every 10 minutes; the process census (every process's parent, footprint and CPU; cwd, arguments and listening ports only for sessions and leftover candidates) runs once a minute and when the "Máy" section opens (~10 ms). Memory numbers are physical footprint (Activity Monitor's "Memory" column), so a swapped-out session still shows what it will take back. Collapsed surfaces never animate; the pet moves only while a surface is open (12 fps) and never when macOS Reduce Motion is on. The floating panel's charts and $ are only computed while that panel is enabled.

Rebuilding changes the ad-hoc code signature, so macOS will ask again for Keychain access the first time the new build reads it.
