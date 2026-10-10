# Changelog

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
