# Changelog

## 0.3.1
- Details per tool: click a tool's card in the panel to open that tool's detail in place (other limits, current pace, what is left per day, what is running, what the vendor adds, the last 24 hours, where the numbers come from). The single "Quota details" switch is gone.
- Edge tab: drag it up or down to move it; it opens on a click only, never on hover.
- Fixed: on macOS 26 and later, clicking inside the menu bar panel (or the low-memory card) drew a dark outline around it. Glass panels no longer ask for a second, rectangular window shadow.

## 0.3.0
Repositioned around what agents hold on the Mac, with quota second; brought the information in line with comparable tools.
- English and Vietnamese. Follows the Mac's language; pin one in Settings › Advanced.
- Defaults: one surface on a fresh install (the notch, or a tab on the screen edge when there is no notch), no sound, menu bar item only when chosen.
- The panel opens when the pointer rests for a moment (0.16 s), never mid-drag; closes 0.38 s after it leaves; a click toggles at once.
- Quota tiles say "N% used", when it resets in words, and a verdict ("runs out in ~8m", "on pace", "lasts until the reset"). The edge tab shows the number; at the notch it is an option (Settings › Advanced). The panel footer shows how fresh the numbers are, with a refresh button.
- Mac window: two-line rows with the evidence behind a chevron, one meaning per colour, memory pressure in a word instead of "% free", an "all interfaces" flag for servers listening beyond localhost, open-in-browser, and a "got back X" line after a cleanup.
- Settings: seven decisions on the first page, the rest under Advanced. Two plain marks (spark, hexagon) can replace the pets.
- Look: softer notch and edge-tab shapes, cards lit by their own colour, system Liquid Glass for panels off the notch on macOS 26 and later, new app icon.
- New landing page (`site/`), English and Vietnamese.
- Fixed: the Mac card no longer opens on "no agents, 100% free" before the first process scan.

## 0.2.0
First release meant for other people's Macs.
- First-run guide: three skippable pages (what it is, try opening the glance, pick a quota source). Reopen from Settings › Giới thiệu or the right-click menu.
- Claude quota from the statusline can be switched on and off in Settings › Dữ liệu; no shell script needed.
- Notification permission is asked when you turn alerts on or when the first urgent alert fires, not at launch.
- Settings › Giới thiệu: version, "Kiểm tra bản mới" (manual, asks GitHub), "Gỡ TokenPet…" (restores the statusline, deletes TokenPet's data, moves the app to the Trash).
- An empty Claude card now says what to do and links to Settings.
- App icon, universal binary (Apple Silicon + Intel), DMG and zip packaging, `install.sh`, `uninstall.sh`, landing page in `site/`.

## 0.1
Notch / edge / menu bar surfaces, per-tool pets, alerts, the "Máy" window.
