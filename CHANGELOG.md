# Changelog

## Unreleased

- Diagnostics reports retain their generation language; a language change bypasses the age cache. Reports produced in the previous language are discarded and refreshed after any active repair finishes.

- Alert settings show notification authorization separately from the alert switches, including missing permission, denied access and disabled banners. Enabling slowdown alerts requests permission, and returning from System Settings refreshes the status.

- The menu-bar hottest metric and hot alerts use the same full curated temperature scope as the open window. Default background CPU sampling remains essential-only.
- Sensors can include unnamed readings for SMC-key troubleshooting; the wider scope is released when leaving the page.

- Overview memory, process memory and swap use a shared MiB/GiB formatter in the app and CLI; disk cleanup retains decimal MB/GB. Overview details wrap instead of shrinking into a single line.

- Diagnostics retains the latest 20 operation results during the app session, including failed steps and backup locations, even after an item disappears from the inventory.
- Batch repair results list each action and its output in a scrollable sheet with a reachable Done button. A separate execution flag keeps scans and repairs mutually exclusive while views change.
- Failed diagnostic steps are written to the action log with redacted error output.

- Disk-space caches retain the original measurement time and language. Cancelled, future-dated, invalid and mismatched-language caches are rejected.
- Disk-space measurement records unreadable locations and shows a permission notice rather than silently treating them as empty.

- Disk-space measurement has a Stop action, stops when its page or window closes, keeps completed results after cancellation and does not cache partial measurements. Its cancellation token is independent of Disk Cleanup.
- A failed helper connection is labeled as a connection failure rather than claiming the helper has stopped.

- Fan policy changes run one operation at a time, show an applying state, and read back active policies even when a write fails. Pending settings for multiple fans apply in order.
- A helper version response alone no longer makes a stale policy appear active; unavailable policies have no active quick-switch highlight. Preset fan curves explicitly label Celsius.

- Offscreen screenshots do not change saved window placement; windows saved on disconnected displays reopen on screen.

- Disk-space refresh keeps previous locations visible as new readings arrive; disclosure buttons work with the keyboard.
- Label macOS thermal pressure separately from sensor temperature. Retained swap alone no longer explains a slowdown when current load and memory pressure are normal; restart advice reports current memory instead of promising a specific saving.

- Quit/end and restart recheck executable path, process start time and user identity against the captured reading; exited or replaced processes are skipped with an explanation.
- Hot notifications and alert thresholds follow the Fahrenheit setting.

- Browser page closes update memory totals, biggest-page rankings and duplicate counts; new checks cannot race a pending close, and rechecks show progress while keeping the previous result.
- App restart reports a refused quit or failed reopen; saved browser tabs are only reopened after the app launches successfully.
- Release the Mach host port after each memory reading.

- Keep unselected sessions and failed paths visible after partial cleanup; remeasure remaining data and invalidate the old scan cache.
- Completing a disk scan preserves choices made while results were arriving; stopped scans and unreadable locations are labeled as incomplete.
- Helper setup times out without restarting installation or applying queued settings; repeated setup and status checks are coalesced.

- Reject invalid and duplicate fan-curve points, preserve decimal values when editing a saved curve, and validate policies in the privileged helper.
- Disk Cleanup confirmation lists the paths that will be removed. Pending fan settings are labeled as waiting for the helper.
- Keep agent scans and fixes mutually exclusive; category batch fixes now show their commands for confirmation. Search reveals healthy matches too.

- Add the native Edit menu so Select All, Copy, Paste and Undo work in text fields.
- Search sensors by name, group or SMC key with ⌘F; switch main pages with ⌘1–⌘6 and open Settings with ⌘,.
- Temperature charts follow the Fahrenheit setting and include readings above 105°C. Empty charts explain what they are waiting for.
- Show CPU load as load per core rather than a CPU usage percentage.
- Browser checks show a stopped state and keep the previous result during a new check. Leaving the page or closing the window cancels checks for every browser; late progress from cancelled checks is ignored.
- Main-window errors are visible, with retry after sensor initialization fails. Disk Cleanup reports changed scan scopes and errors, searches paths, and provides keyboard-accessible selection and detail buttons.
- Align disk-space details with the other pages; label Settings controls for accessibility and honor Reduce Motion for page transitions and the scan halo.

## 1.1.7

- One console window for everything (the "Open Console" button in the menu bar panel, or click the Dock icon): Overview with gauges for temperature, CPU load, memory and free disk space, why the Mac is slow and the temperature trend; Sensors as a card per group; Fans; Browser pages; Disk Cleanup and AI Agent Diagnostics; Settings — all in one sidebar.
- The menu bar panel is now a glance: the live numbers, why the Mac is slow, a one-click Auto / Max fan switch, an "Open Console" button and shortcuts to its pages.
- Disk Cleanup scans everything by default and finds build output it missed: `dist`, `build`, `out`, `coverage` and similar folders in web and Python projects (skipped when git tracks them; offered for review, since they can hold renders or release builds).

## 1.1.6

- "Why is my Mac slow" says why in plain words: how much memory has been moved to the disk and that programs are waiting on it, and which program is behind it.
- Big apps are broken down: Chrome and other multi-process apps show their GPU process and heaviest pages, with how long each has run.
- Long-running apps that hold gigabytes get a concrete suggestion ("Chrome has run 31 hours and opened about 2,000 pages; restarting frees about 19 GB") and a Restart button. Thermo checks whether the app reopens its own windows; when Chrome does not, Thermo saves the tabs first and reopens them after the restart.
- Chrome page diagnosis (Overview → "查看页面", or `thermo pulse chrome`): which pages keep growing (memory, DOM nodes, or event listeners piling up), the biggest pages, duplicate tabs, and busy background workers, with a button to close a page. It lists tabs without touching them; measuring memory is a separate click, because Chrome briefly shows its "being debugged" bar while it measures. Needs chrome-use for the memory figures.
- Slowdown history: Thermo notes every minute (every five on battery) what was slowing the Mac, kept for 24 hours — a chart on the Overview and `thermo pulse history`. Cost: about 0.02% of one core.
- Slowdown alerts (Settings → "Warn me before my Mac slows down", on by default): swap growing past 8 GB, memory under pressure, one program using over 1.5 cores for 10 minutes, or thermal throttling — with who is behind it and what to do. Nothing is ever quit automatically.

## 1.1.5

- Your fan setting survives updates and restarts: the helper remembers it and puts it back when it starts (over-temperature protection still applies). Before, an update or reboot quietly returned the fans to automatic.
## 1.1.4

- Disk Cleanup has the same look as AI Agent Diagnostics: a Smart Scan home that says how much can be freed with one button for the safe part, a card per category, and pages where each item opens in place to show its sessions or files. It opens with the last scan when that is recent, instead of scanning from scratch.
- AI Agent Diagnostics has a new look: one verdict ("14 problems found, 9 can be fixed with one click"), a big Fix button that runs the safe fixes with progress and a result, colorful category cards, and plain-language problem cards with the fix right next to each; technical details are one click away.
- Disk cleanup finds more of what fills a Mac: unused Xcode simulator runtimes and simulator data (removed through Xcode's own tool), OrbStack's disk image, and chat apps' storage (Lark, WeChat, WhatsApp, Telegram, Slack…, shown with where to clear it inside the app — Thermo never deletes chat history).
- "Where the space is": the disk's used space by place — apps, app data, caches, Xcode, temporary files, Homebrew, simulator runtimes and swap — with the biggest folders in each (`thermo clean overview`).
- Sizes are what deleting would actually free, so copies that share space on disk (like Chrome's code-signing clones) no longer look huge.
- Disk cleanup moved into its own window (the popover's Disk tab now just sums up and opens it): categories on the left, build output grouped by project with when each was last used, sortable and searchable, and a detail pane with every path or session and why it is safe to remove. `Thermo --disk` opens it directly.
- Settings → AI agents (thermo-use): one click puts the `thermo` command where AI agents find it and adds the thermo-use skill to Claude Code or Codex; it shows what to ask your agent. thermo-use is part of the *-use family.
- Everything the app does is now also a command for agents and scripts: `thermo pulse quit NAME` (the Quit button on the "why is it slow" card) and `thermo settings` (menu bar text, interval, alerts, units, language, Dock icon; a running Thermo applies changes at once).
- Projects are found through the folders your AI agents and editors worked in, and "last used" comes from those sessions and git, not just file dates — so build output of projects you stopped working on is told apart from ones you use every day.
## 1.1.3

- Thermo itself stays out of the way: the "why is my Mac slow" card checks programs only while the panel is open, and each check is far cheaper (about 0.6% of one core with the panel open).
- Busy command-line programs say what they are and whose they are: "vitest ×4 · ~/code/shop · started by Claude Code" instead of a row of "node". Thermo no longer lists itself.
- Turning on fan control takes one click and your Mac password once — no trip to System Settings. After that the helper updates itself along with Thermo (it only accepts a newer helper signed by Thermo's developer), so updates never ask again.
- A fan setting you choose before the helper is ready (say, max) is applied as soon as it is.
- Turning on fan control no longer hangs on "Setting up…" when an earlier System Settings (Login Items) registration is stuck; it goes straight to the password prompt.
- After the password prompt the Fans tab picks up the new helper right away (it kept talking to the old one until Thermo was restarted).

## 1.1.2

- `thermo pulse` (also `thermo status`): why this Mac is slow, in one command — the verdict, which program is behind it, load, memory pressure and swap, thermal state, temperatures and fans; `--json` for scripts and AI agents. AI agents get it through the [thermo-use](https://github.com/leeguooooo/thermo-use) skill.
- Memory per program now counts what Activity Monitor counts (compressed and swapped memory included), so the biggest memory users are named correctly.

## 1.1.1

- Setting a fan to max now keeps it at max when the Mac gets hot. Before, over-temperature protection handed it back to automatic control, so the fan slowed down exactly when you needed it most. Other fan settings are still paused while the Mac is too hot, as before.

## 1.1.0

- **Why is my Mac slow?** The Overview now opens with a one-line answer: overloaded, too hot and throttling, or short on memory, and which program is behind it. The busiest programs are listed with a Quit button (apps quit like ⌘Q; system processes and AI agent sessions are never offered).
- Thermo has a Dock icon (Settings → Show in Dock), and clicking it opens the panel.
- When the menu bar icon is hidden behind the notch, Thermo opens its panel on launch and explains how to make room.
- New **Agents** tab and `thermo agents` command: diagnoses the AI coding agents on this Mac (Claude Code, Codex, Cursor, Gemini). Finds hooks and MCP servers whose programs are missing, plaintext credentials in MCP configs, plugins that are enabled but not installed, broken skill symlinks, launch agents stuck in a restart loop or pointing at deleted programs, and agent processes that leaked or still run a deleted binary. Read-only; secrets are redacted.
- AI agent diagnostics can now fix and uninstall: remove broken skill links, MCP servers, hooks and launch agents, stop launchd restart loops, end leftover processes, disable or uninstall plugins. Every action shows the exact steps first, backs up config files and moves files to the Trash.
- New diagnostics window (sidebar of checks, item list, details with suggestions and actions); the popover tab is now a summary.
- Disk cleanup (`thermo clean`, Disk tab). It recognises what AI tools leave on disk:
  - Claude Code, Codex and Gemini CLI sessions, grouped by project;
  - Cline, Roo and Kilo tasks;
  - editor chat data for projects that have been deleted;
  - agent worktrees;
  - old CLI and plugin versions and agent scratch folders;
  - Ollama, Hugging Face and LM Studio models.

  It also covers developer caches, Xcode, project build output, browsers and logs. Sessions that are still running, apps that are open and anything with unsaved work are skipped. Caches are deleted; your data goes to the Trash.
- Thermo speaks Chinese: Settings → Language (System / English / 简体中文). The `thermo` command stays English unless `THERMO_LANG=zh`.

## 1.0.4

- Over-temperature protection no longer throws away your fan settings: fans go back to automatic control while the Mac is too hot, and your fixed speed or curve comes back once it has cooled down.
- Apple Silicon: the protection triggers at 110 °C instead of 95 °C. These chips normally run their cores at 100–115 °C under load, so the old limit kept switching curves off for no reason.
- A single brief temperature spike no longer triggers the protection; it has to last a few seconds.

## 1.0.3

- Apple Silicon: switching a fan back to Auto works again (it left the fan at its last manual speed); if returning to Auto ever fails, every fan is reset to system control.
- Apple Silicon: setting a fixed speed or curve no longer reports a timeout while the fan control is being unlocked.

## 1.0.2

- Thermo now lives at app.leeguoo.com/thermo — downloads and updates come from there.
- After an update, the fan helper restarts itself on the new version (fans briefly return to automatic control).
- Product screenshots render the panel tabs correctly.

## 1.0.1

- Apple Silicon: fans under system control are no longer shown as "manual", and returning a fan to Auto restores the system's own fan mode.
- Battery temperature and health on recent macOS versions.
- Lower background CPU use on Apple Silicon.
- Sensors that share a name are now listed separately.

## 1.0.0

- Menu bar app showing CPU/GPU temperature, fan speed or system power, with a 10-minute history chart.
- Every SMC temperature sensor with readable names and groups; power, voltage, current and battery health.
- Fan control: fixed speed or temperature curve (Quiet / Balanced / Performance / custom), driven by CPU, GPU or the hottest sensor.
- Safety: fans return to automatic control when any CPU/GPU sensor reaches 95 °C, and whenever the helper stops.
- `thermo` command-line tool: overview, live `watch` view, JSON/CSV output, raw SMC access, fan control.
- High-temperature alerts and launch at login.
