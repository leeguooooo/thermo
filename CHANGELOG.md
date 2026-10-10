# Changelog

## Unreleased

- AI agent diagnostics can now fix and uninstall: remove broken skill links, MCP servers, hooks and launch agents, stop launchd restart loops, end leftover processes, disable or uninstall plugins. Every action shows the exact steps first, backs up config files and moves files to the Trash.
- New diagnostics window (sidebar of checks, item list, details with suggestions and actions); the popover tab is now a summary.
- Thermo speaks Chinese: Settings → Language (System / English / 简体中文). The `thermo` command stays English unless `THERMO_LANG=zh`.

- New **Agents** tab and `thermo agents` command: diagnoses the AI coding agents on this Mac (Claude Code, Codex, Cursor, Gemini). Finds hooks and MCP servers whose programs are missing, plaintext credentials in MCP configs, plugins that are enabled but not installed, broken skill symlinks, launch agents stuck in a restart loop or pointing at deleted programs, and agent processes that leaked or still run a deleted binary. Read-only; secrets are redacted.
- Disk cleanup (`thermo clean`, Disk tab). It recognises what AI tools leave on disk:
  - Claude Code, Codex and Gemini CLI sessions, grouped by project;
  - Cline, Roo and Kilo tasks;
  - editor chat data for projects that have been deleted;
  - agent worktrees;
  - old CLI and plugin versions and agent scratch folders;
  - Ollama, Hugging Face and LM Studio models.

  It also covers developer caches, Xcode, project build output, browsers and logs. Sessions that are still running, apps that are open and anything with unsaved work are skipped. Caches are deleted; your data goes to the Trash.

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
