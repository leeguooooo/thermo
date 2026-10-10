# Changelog

## 1.1.3

- Thermo itself stays out of the way: the "why is my Mac slow" card checks programs only while the panel is open, and each check is far cheaper (about 0.6% of one core with the panel open).
- Busy command-line programs say what they are and whose they are: "vitest ×4 · ~/code/shop · started by Claude Code" instead of a row of "node". Thermo no longer lists itself.
- Turning on fan control takes one click and your Mac password once — no trip to System Settings. After that the helper updates itself along with Thermo (it only accepts a newer helper signed by Thermo's developer), so updates never ask again.
- A fan setting you choose before the helper is ready (say, max) is applied as soon as it is.
- Turning on fan control no longer hangs on "Setting up…" when an earlier System Settings (Login Items) registration is stuck; it goes straight to the password prompt.

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
