# TokenPet — the notch monitor for Claude Code and Codex

A small native Mac app for people who code with agents all day. It answers two questions:

1. **What are my agents holding on this Mac, and can I get it back?** Every Claude Code / Codex session with its whole process tree (MCP servers, language servers, test runners) and the dev servers an agent started and left behind, sorted by what to do about them, with one click to close.
2. **How much quota is left before I am cut off?** The 5-hour and weekly limits of both tools, the exact reset time, and a one-line heads-up before a limit is reached.

English and Vietnamese (follows the Mac's language; pin one in Settings › Advanced). About 40 MB of RAM and near 0% CPU at idle, because it listens to log changes (FSEvents) instead of polling.

## Install
- **Download:** `TokenPet.dmg` from the [latest release](https://github.com/VoTuTrinh/tokenpet/releases/latest), drag TokenPet into Applications.
- **Or one command** (downloads, installs, opens; no Gatekeeper prompt):

      curl -fsSL https://raw.githubusercontent.com/VoTuTrinh/tokenpet/main/install.sh | sh

Needs macOS 13 or later; Apple Silicon and Intel. Releases are not notarized unless built with a Developer ID (see "Release"). If macOS blocks the first launch of a downloaded copy: System Settings › Privacy & Security › "Open Anyway".

**First run** shows a three-page tour: what it is, try opening the panel, pick where Claude's quota comes from. Every page can be skipped; reopen it from Settings › About.

**Uninstall:** Settings › About › "Uninstall…", or `./uninstall.sh`. Both restore the Claude Code status line, delete TokenPet's data and remove the app.

**Privacy:** no account, no telemetry, no TokenPet server. The network is used only when "Ask Anthropic and OpenAI for your quota" is on (each vendor's token goes only to that vendor) or when you press "Check for updates" (GitHub).

## Where it lives
A fresh install adds exactly one thing to the screen:
- **Notch** on a MacBook with one: a pet in a ring on each side (Claude left, Codex right); the % beside it is an option, off by default because it can cover menu bar items. Nothing moves while it is collapsed.
- **Tab on the screen edge** when no connected screen has a notch: the same rings stacked, each with its number. Drag it up or down; it opens on a click, never on hover.
- **Menu bar item** only if you choose it in Settings, or when nothing else can show.

The panel opens when the pointer **rests** on the notch or tab for a moment (0.16 s; never while a mouse button is down, so not mid-drag), closes 0.38 s after it leaves, and toggles at once on a click. Off the notch, panels use the system's Liquid Glass on macOS 26 and later; the notch panel stays black to match the hardware.

## The panel
One card per tool: the pet, then **5 hours** and **Week**, each with "N% used", a bar, "resets Tue 01:39 · in 2h00", and a verdict: "runs out in ~8m", "on pace", "12% ahead of an even pace" or "lasts until the reset". Click a tool's card to open its detail in place: per-model weeks and extra limits, the current pace, what is left per day, what is running, what the vendor adds, the last 24 hours of tokens, and where the numbers come from. The footer says how fresh the numbers are and has a refresh button.

A third card, **Mac**: agents' share of RAM, "Agents hold 4.8 GB", memory pressure in a word, and "Review & free · get back 2.3 GB". It opens the Mac window (also ⌃⌥M).

## The Mac window
Summary (the number, memory pressure, swap, one sentence of advice, "Close all · get back X"), a bar split into running / open / asleep / leftover, then groups by what to do: **Worth closing**, **Your call**, **Running, leave alone**, and **Not agents** for comparison. A row is two lines (name and size; state · what · project); the chevron opens the evidence: folder, terminal, times, pid, ports and the process tree. Leftover servers show their port, an "all interfaces" flag when they listen beyond localhost, and a button to open localhost in the browser. Nothing is closed without a click unless auto-close is switched on in Settings; every action names the pids first, and a closed session comes back with `claude --resume`.

When the kernel reports memory pressure and there is something to close (at most once an hour), a small card names the three biggest items.

## Settings
Seven decisions on the first page: which tools, where to show (notch / menu bar / both), mascot on or off, alert level, server quota, launch at login. Everything else is under "Advanced": pets beside the notch, the edge tab, floating panel, mascot per tool (four pets, or a plain spark / hexagon mark), motion, language, alert details, cleanup thresholds and auto-close, the status line source.

Alerts are quiet by default: "Balanced" warns at 80% and 95%, before running out (< 45 min), when the week will not last, on reset, and when the Mac is short on RAM with something to close. No sound unless you turn it on. Only what needs you now becomes a macOS notification; the rest is one line under the notch.

## Data sources (freshest wins per window)
| Source | What | Notes |
|---|---|---|
| `~/.codex/sessions` logs | Codex 5h + weekly | local, no network |
| Claude statusLine payload | Claude 5h + weekly (all models) | opt-in: Settings › Dữ liệu, or the first-run guide (the two `*-claude-quota.sh` scripts do the same from a terminal) |
| Server (opt-in, right-click → "Lấy quota từ server") | Claude: 5h, weekly, per-model, extra usage, usage breakdown. Codex: 5h, weekly, extra limits, credits, banked resets | Read-only. Reuses the logins Claude Code/Codex already saved (Keychain item `Claude Code-credentials`, `~/.codex/auth.json`). Each token is sent only to its own vendor (`api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`). Never refreshes or writes credentials. Polls every 5 min and backs off on 429. These endpoints are undocumented, so field mapping follows [ai-usage-menubar's provider contracts](https://github.com/burakgon/ai-usage-menubar/blob/main/docs/provider-contracts.md). |

The quota history used for forecasts lives in `~/Library/Application Support/TokenPet/quota-history.jsonl` (21 days).

## Build / run
    ./build.sh                 # -> build/TokenPet.app, universal, with icon (add --install to copy into /Applications)
    ./scripts/package.sh       # -> dist/TokenPet-<version>.dmg + .zip + SHA256SUMS
    open build/TokenPet.app

    TokenPet --snapshot <dir> --fake [--clear] [--lang en|vi]   # PNGs of every surface with demo data (site/assets/<lang>)
    TokenPet --selftest          # forecasts, notifier, every Settings switch, fresh-install defaults, hover timing
    TokenPet --settings-size     # the Settings form must fit the 500 pt window
    TokenPet --procs             # the Mac census as text, to compare with ps/lsof
    TokenPet --dump [--server]   # print insights
    TokenPet --bench             # scan times, footprint

QA hooks on a running app: `kill -USR1 <pid>` opens Settings, `kill -USR2 <pid>` shows a test line under the notch, `kill -INFO <pid>` opens the panel (menu bar panel, edge card or notch, whichever is showing). `TokenPet --ports <pid>` prints the listening ports of a process and their bind scope.

## Resource budget
Measured on an M-series MacBook Pro with ~26k log events: 33 MB footprint and 0.05% CPU after a minute idle. A log change costs a 0.2 ms rescan of only the changed files; the full walk runs at launch and every 10 minutes; the process census (every process's parent, footprint and CPU; cwd, arguments and listening ports only for sessions and leftover candidates) runs once a minute and when the "Máy" section opens (~10 ms). Memory numbers are physical footprint (Activity Monitor's "Memory" column), so a swapped-out session still shows what it will take back. Collapsed surfaces never animate; the pet moves only while a surface is open (12 fps) and never when macOS Reduce Motion is on. The floating panel's charts and $ are only computed while that panel is enabled.

Rebuilding changes the ad-hoc code signature, so macOS will ask again for Keychain access the first time the new build reads it.

## Release
1. Bump `VERSION`, add a section to `CHANGELOG.md`.
2. `git tag v<version> && git push --tags`. `.github/workflows/release.yml` builds, packages and publishes the GitHub release; the landing page's download button and `install.sh` point at `releases/latest/download/TokenPet.dmg` / `.zip`.
3. `site/` deploys to GitHub Pages through `.github/workflows/pages.yml` (enable Pages with source "GitHub Actions" once).

The repository name `VoTuTrinh/tokenpet` appears in `install.sh`, `site/index.html` and this README; `build.sh` reads it from the `origin` remote (or `REPO=`) for the in-app update check.

For builds that open without a Gatekeeper warning, set `SIGN_ID` (a Developer ID Application certificate) and `NOTARY_PROFILE` for `scripts/package.sh`, or the matching secrets listed at the top of the release workflow. Without them the app is ad-hoc signed, and every rebuild makes macOS ask for Keychain access again.
