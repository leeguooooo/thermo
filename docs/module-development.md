# Writing a Thermo module

A third-party module is a WebAssembly program that describes pages and menu bar items as data. Thermo
draws them with its own controls and runs the program in a sandboxed runner that can do nothing but
ask the kernel for what the module declared. This guide covers the `thermo dev` tools; the formats are
in [module-market.md](module-market.md) (packaging and signing) and the code (`ModuleView`, `ModuleManifest`).

Requirements: macOS 15 or later and Thermo 1.5.58 or later (the tools ship in `Thermo.app/Contents/Helpers`).
No compiler to install: modules are written in WebAssembly text and assembled by Thermo.

## Five minutes

```sh
thermo dev new com.example.hello      # creates ./hello
cd hello
thermo dev run                        # builds, loads it into Thermo, rebuilds on every save
```

Open **Feature Center**: *Hello* is listed and already switched on. Its page is in the sidebar and its
item in the menu bar panel. Edit `views/main.json` and save — the page redraws within a second. A build
error is printed and Thermo keeps the last good build. Ctrl-C stops watching; the module stays loaded
until you switch it off.

```sh
thermo dev test                       # runs fixtures/*.json, compares page snapshots
thermo dev test --update              # accept the current pictures as the new reference
thermo dev build                      # just build: .thermo-build/<id>/{module.json,module.wasm}
```

## The folder

| Path | What it is |
|---|---|
| `module.json` | The manifest: id, name, entries (pages and menu bar items, each with a `scene`), declared `capabilities`, translations. |
| `src/module.wat` | The program. Must contain the line `;; @thermo-strings` once. |
| `views/*.json` | Documents the program sends. Each is checked as a `ModuleView` when you build. |
| `strings/*.txt` | Other bytes the program needs, e.g. a needle to search the request for. A final newline is dropped. |
| `fixtures/*.json` | Test inputs; see below. `fixtures/<name>.png` is a reference snapshot. |

`thermo dev build` replaces `;; @thermo-strings` with the memory, the heap and every file in `views/`
and `strings/` as data. `views/main.json` becomes `(global.get $view_main)` (address) and
`(global.get $view_main_len)` (length); `strings/scene_menu.txt` becomes `$str_scene_menu`. Names use
letters, digits, `_` and `-`.

## The program's contract

Exports:

- `thermo_alloc(len) -> ptr` — the kernel calls it once at the start of every call, for the request.
  Reset your heap there (`(global.set $heap (global.get $heap_base))`) so nothing piles up.
- `thermo_render(ptr, len) -> status` — request `{"language":"en","scene":"main"}` (keys sorted). Output
  the page (`sections`) for a page scene or a `menuBarItem` for a menu bar scene. Status 0 is success.
- `thermo_action(ptr, len) -> status` — request `{"action":"refresh","language":…,"scene":…,"values":{…}}`.
  `values` holds a submitted form. Output a page to show next, or nothing to render the page again.

Imports, and nothing else (no WASI, no clock, no files, no network):

- `thermo.request(capPtr, capLen, payloadPtr, payloadLen) -> i32` — ask the kernel, e.g. capability
  `processes.read` with payload `{"op":"list"}`. Returns the answer's length, or -1 denied, -2 declined
  by the person, -3 failed. Undeclared capabilities are always denied, and every request is in the
  module's access record in Feature Center.
- `thermo.answer(ptr, len) -> i32` — copy the last answer into your memory.
- `thermo.output(ptr, len)` — set what the call returns.

Limits: 64 MB of memory, a per-call execution budget and 5 s of wall time (time spent waiting for the
kernel or the person doesn't count). Three failures in a row switch the module off until it is switched on again.

## Views

```json
{"version": 1, "title": "Processes", "subtitle": "…", "sections": [
  {"type": "card", "title": "Running", "value": "{{n}}", "caption": "…", "symbol": "cpu",
   "actions": [{"action": "refresh", "title": "Refresh"}]},
  {"type": "list", "id": "rows", "title": "…", "rows": [{"id": "a", "title": "…", "subtitle": "…", "value": "…", "symbol": "star", "action": "open.a"}]},
  {"type": "detail", "title": "…", "fields": [{"label": "…", "value": "…"}]},
  {"type": "form", "id": "prefs", "title": "…", "fields": [
    {"id": "name", "label": "Name", "input": "text", "value": "x"},
    {"id": "count", "label": "Count", "input": "number", "value": 2},
    {"id": "on", "label": "On", "input": "toggle", "value": true},
    {"id": "mode", "label": "Mode", "input": "choice", "value": "a", "options": [{"id": "a", "title": "A"}]}],
   "submit": {"action": "save", "title": "Save"}}]}
```

A menu bar scene sends `{"version": 1, "menuBarItem": {"title": "…", "value": "…", "symbol": "…"}}`.
Text is shown as plain text — never Markdown or links. Symbols are SF Symbol names. Sizes, counts and
ids are capped; an unknown section type rejects the whole document. `{{n}}` is only a convention of the
example: the build checks views with a number in its place, and the program replaces it at run time.

The request's `language` is the app's (`en`, `zh-Hans`, …): send text in that language, and put the
manifest's own texts in its `localizations`.

## Fixtures

```json
{"scene": "main", "language": "en", "action": "refresh", "values": {"name": "x"},
 "answers": {"processes.read": {"processes": [{"pid": 1}]}, "files.read": "denied"},
 "expect": ["Running processes", "\"value\":\"1\""], "snapshot": true}
```

`thermo dev test` builds the module and runs each fixture through the real sandboxed runner. `answers`
stand in for the Mac: a declared capability gets the given JSON (`"denied"` or `"failed"` refuse it);
the kernel's manifest check still applies, so an undeclared capability is refused as in the app.
`expect` lists text that must appear in the resulting view (as JSON). With `"snapshot": true` the page
is drawn offscreen by Thermo's own renderer (`Thermo --module-test`) and compared with
`fixtures/<name>.png`; up to 1% of pixels may differ (fonts and antialiasing vary between Macs). A
differing picture is saved as `fixtures/<name>.actual.png`. Exit status: 0 passed, 1 a fixture failed,
2 usage or build error.

## A complete example

[`examples/process-count`](../examples/process-count) declares `processes.read`, counts the processes the
kernel returns, writes the number into its card and menu bar item, shows a different page when the
kernel refuses, and has fixtures for all four cases plus a reference snapshot:

```sh
thermo dev test examples/process-count
thermo dev run examples/process-count
```

## Shipping

`thermo dev run` loads modules from a development folder only you set; nobody else gets them. To
distribute a module, package and sign it for the market — see [module-market.md](module-market.md).

## Environment overrides

For working on Thermo itself: `THERMO_WAT2WASM`, `THERMO_WASM_RUNNER` and `THERMO_APP_EXECUTABLE`
point the tools at freshly built binaries (`scripts/module-dev-harness.sh` does this).
