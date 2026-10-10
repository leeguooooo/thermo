# thermo — design

macOS temperature / fan / power monitor with fan control. CLI + menu bar app.
Closed source for now. Targets macOS 13+, Intel and Apple Silicon.

## Architecture (one Swift Package)

| Target | Lang | Role |
|---|---|---|
| `CSMC` | C | AppleSMC user client: open, key enumeration, cached key info, read, write, type decode/encode. IOHID temperature sensors (Apple Silicon). |
| `ThermoKit` | Swift | Sensor discovery + naming + grouping, `Sampler` (discover once, read only known keys), battery via `AppleSmartBattery`, fan control logic, fan policies + curves, XPC protocol, helper installer. |
| `thermo` | Swift | CLI. |
| `thermo-helper` | Swift | Root LaunchDaemon (`dev.thermo.helper`), XPC Mach service. Only process that writes SMC. |
| `ThermoApp` | Swift/SwiftUI | Menu bar app (`Thermo.app`, LSUIElement). |

## Features

Read (no root): all temperature sensors with names and groups (CPU, GPU, Memory,
Storage, Battery, Ambient, Other), fans (actual/min/max/target/mode), power (W),
voltage (V), current (A), battery (temp, voltage, amperage, cycles, charge).

CLI:
- `thermo` summary; `thermo temps|fans|power|battery`
- `thermo watch [-i SEC]` full-screen live view; `--json`, `--csv` everywhere (streaming for watch)
- `thermo list [--all]` raw SMC keys with type/size/value; `thermo get KEY...`
- `thermo fan status|set <id|all> <rpm>|auto [id|all]|curve <id|all> <t:rpm,...> [--sensor cpu|gpu|max]`
- `thermo helper install|uninstall|status`
- `thermo bench` sampling latency

Menu bar: title shows chosen metric (CPU temp / hottest / fan RPM / temp+fan);
popover with grouped sensors, fans, power, 10-minute charts, fan control
(auto / fixed RPM / curve), settings (interval, title metric, alert threshold,
launch at login). Sampling slows when the popover is closed.

## Fan control & safety

- Helper owns fan policies (`auto`, `fixed rpm`, `curve`) and runs a 2 s loop while any non-auto policy is active. Clients may exit; the policy stays.
- RPM always clamped to SMC min..max.
- Helper reverts all fans to auto on start and on SIGTERM/SIGINT. Over-temperature (1.0.4): when the hottest CPU/GPU sensor stays at or above the ceiling for 2 ticks (Intel 95 °C, Apple Silicon 110 °C) fans go to auto and policies are suspended, resuming after 60 s below ceiling − 10 °C.
- Writes: Apple Silicon unlocks with `Ftst=1` when present, then `F<i>Md=1`, `F<i>Tg`; Intel uses `F<i>Md` when present, otherwise the `FS! ` force bitmask. Values encoded with the key's own SMC type.
- XPC clients must match `setCodeSigningRequirement`: when the helper is Developer ID signed it requires the same Team ID (read from its own signature at runtime) plus identifier `dev.thermo.cli`/`dev.thermo.app`; ad-hoc builds check identifiers only (weak, documented).
- Install: Developer ID builds of the app register the bundled daemon via `SMAppService.daemon` (user approves in Login Items). Ad-hoc builds and the CLI use `osascript … with administrator privileges` to copy into `/Library/PrivilegedHelperTools` + `/Library/LaunchDaemons` and `launchctl bootstrap`.
- Writes are rate-limited: hysteresis 50 rpm, ramp-down ≤ 400 rpm per 2 s tick.

## Performance

- One SMC connection per process; key info cached in an open-addressing table in C.
- Discovery runs once and is cached on disk (line-based text, byte-level parser) keyed by model + key count.
- Sampling scopes: `essential` / `known` / `all`, plus per-command parts and group filters. On T2 Macs each SMC read costs ~370 µs serialised in firmware, so fewer keys is the only lever.
- Measured (MacBookPro16,1): CLI cold start 11 ms (`--version`), 20 ms (`fans`), 35 ms (overview); app idle 0.18 % of one core.

## Testing

Unit tests: type decode/encode (fixed-point/int/float types), FourCC, sensor
classification, curve parsing/interpolation, policy engine + failsafe, policy coding,
discovery cache round-trip, battery parsing, and a live SMC test (skipped without SMC). Hardware verification
on the dev machine (Intel i9-9880H MBP 2019). Apple Silicon paths need an M-series
machine for verification.
