import Foundation
import ModuleKit

/// `thermo dev new <id>`: a module that builds and runs as generated — a page with a card and a
/// list, a menu bar item, a refresh action, and fixtures with their expected text.
public enum ModuleTemplate {
    public static func create(id: String, in parent: URL, name: String? = nil) throws -> URL {
        let shortName = id.split(separator: ".").last.map(String.init) ?? id
        let folder = parent.appendingPathComponent(shortName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ModuleSource.Failure("\(folder.path) already exists") }
        let title = name ?? shortName.prefix(1).uppercased() + shortName.dropFirst()
        let manifest = ModuleManifest(id: id, name: title, summary: "A module made with thermo dev.", symbol: "puzzlepiece.extension",
                                      version: "0.1.0", entries: [
                                          .init(id: "main", kind: .page, title: title, scene: "main"),
                                          .init(id: "menu", kind: .menuBarItem, title: title, scene: "menu"),
                                      ], localizations: ["zh-Hans": ["name": title, "summary": "用 thermo dev 创建的模块。"]])
        let problems = manifest.problems()
        guard problems.isEmpty else { throw ModuleSource.Failure("id \(id): " + problems.joined(separator: "; ")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let files: [String: Data] = [
            "module.json": try encoder.encode(manifest),
            "src/module.wat": Data(wat.utf8),
            "views/main.json": Data(mainView(title).utf8),
            "views/menu.json": Data(menuView(title).utf8),
            "strings/scene_menu.txt": Data(#""scene":"menu""#.utf8),
            "fixtures/main.json": Data(#"{"scene": "main", "expect": ["Hello", "Edit views/main.json"], "snapshot": true}"#.utf8),
            "fixtures/menu.json": Data(#"{"scene": "menu", "expect": ["\#(title)"]}"#.utf8),
            "fixtures/refresh.json": Data(#"{"scene": "main", "action": "refresh", "expect": ["Hello"]}"#.utf8),
            ".gitignore": Data(".thermo-build/\n".utf8),
        ]
        for (path, data) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return folder
    }

    static func mainView(_ title: String) -> String {
        """
        {
          "version": 1,
          "title": "\(title)",
          "subtitle": "Edit views/main.json and src/module.wat; thermo dev run reloads it.",
          "sections": [
            {"type": "card", "title": "Hello", "value": "1", "caption": "Edit views/main.json", "symbol": "hand.wave",
             "actions": [{"action": "refresh", "title": "Refresh"}]},
            {"type": "list", "id": "steps", "title": "Next steps", "rows": [
              {"id": "views", "title": "Change the text in views/", "symbol": "doc.text"},
              {"id": "logic", "title": "Add logic in src/module.wat", "symbol": "chevron.left.forwardslash.chevron.right"},
              {"id": "access", "title": "Declare what it reads in module.json", "symbol": "lock.shield"}
            ]}
          ]
        }

        """
    }

    static func menuView(_ title: String) -> String {
        #"{"version": 1, "menuBarItem": {"title": "\#(title)", "value": "1", "symbol": "puzzlepiece.extension"}}"# + "\n"
    }

    /// The module. Plain WebAssembly text: no compiler to install, `thermo dev build` assembles it.
    static let wat = """
    ;; A Thermo module (#48). The kernel calls:
    ;;   thermo_render(request) — the page or menu bar item for {"language":…,"scene":…}
    ;;   thermo_action(request) — {"action":…,"language":…,"scene":…,"values":…}; no output re-renders
    ;; and the module may import only thermo.request / thermo.answer / thermo.output.
    ;; `thermo dev build` replaces the @thermo-strings line with memory, the heap and every file in
    ;; views/ and strings/ as data: (global.get $view_main) is its address, $view_main_len its length.
    (module
      (import "thermo" "request" (func $request (param i32 i32 i32 i32) (result i32)))
      (import "thermo" "answer" (func $answer (param i32 i32) (result i32)))
      (import "thermo" "output" (func $output (param i32 i32)))
      ;; @thermo-strings

      ;; The kernel calls this once at the start of every call for the request's bytes: start the heap over.
      (func (export "thermo_alloc") (param $len i32) (result i32)
        (global.set $heap (global.get $heap_base))
        (call $alloc (local.get $len)))

      (func $alloc (param $len i32) (result i32)
        (local $p i32)
        (local.set $p (global.get $heap))
        (global.set $heap (i32.add (global.get $heap) (local.get $len)))
        (local.get $p))

      ;; 1 when [p, p+n) starts with the bytes [needle, needle+len).
      (func $starts (param $p i32) (param $n i32) (param $needle i32) (param $len i32) (result i32)
        (local $j i32)
        (if (i32.lt_u (local.get $n) (local.get $len)) (then (return (i32.const 0))))
        (block $done
          (loop $compare
            (br_if $done (i32.ge_u (local.get $j) (local.get $len)))
            (if (i32.ne (i32.load8_u (i32.add (local.get $p) (local.get $j))) (i32.load8_u (i32.add (local.get $needle) (local.get $j))))
              (then (return (i32.const 0))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $compare)))
        (i32.const 1))

      ;; 1 when the needle occurs anywhere in [p, p+n).
      (func $contains (param $p i32) (param $n i32) (param $needle i32) (param $len i32) (result i32)
        (local $i i32)
        (block $done
          (loop $scan
            (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
            (if (call $starts (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i)) (local.get $needle) (local.get $len))
              (then (return (i32.const 1))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $scan)))
        (i32.const 0))

      (func (export "thermo_render") (param $p i32) (param $n i32) (result i32)
        (if (call $contains (local.get $p) (local.get $n) (global.get $str_scene_menu) (global.get $str_scene_menu_len))
          (then (call $output (global.get $view_menu) (global.get $view_menu_len)))
          (else (call $output (global.get $view_main) (global.get $view_main_len))))
        (i32.const 0))

      ;; "refresh" needs nothing: leaving the output empty shows the page again.
      (func (export "thermo_action") (param $p i32) (param $n i32) (result i32)
        (i32.const 0))
    )

    """
}
