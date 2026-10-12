#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("export_rules", pathlib.Path(__file__).with_name("export-clean-rules.py"))
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class ExportRulesTests(unittest.TestCase):
    def test_current_catalogue_and_retention(self):
        source = export.RULES.read_text()
        rules = [export.parse(call, source) for call in export.rule_calls(source)]
        self.assertEqual(len(rules), source.count('PathRule("'))
        by_id = {r["id"]: r for r in rules}
        self.assertEqual(by_id["xcode-device-support"]["keepNewest"], 2)
        chrome = by_id["chrome-profile-caches"]
        self.assertIn("~/Library/Application Support/Google/Chrome/*/GPUCache", chrome["paths"])
        self.assertIn("~/Library/Application Support/Google/Chrome/ShaderCache", chrome["paths"])
        self.assertEqual(chrome["apps"], ["Google Chrome"])
        self.assertFalse(any('\\(' in p for r in rules for p in r["paths"]))

    def test_helper_cache_names_come_from_source(self):
        source = export.RULES.read_text().replace('"GPUCache", "DawnCache"', '"FutureCache", "DawnCache"')
        self.assertIn("~/Library/Application Support/Chromium/*/FutureCache", export.chromium_paths(source, "Chromium"))

    def test_unknown_helper_shape_is_rejected(self):
        with self.assertRaises(SystemExit):
            export.chromium_paths("", "Chromium")

    def test_unknown_interpolation_is_rejected(self):
        with self.assertRaises(SystemExit):
            export.strings('"\\(future.path)/Cache"')

    def test_string_escapes_are_decoded(self):
        self.assertEqual(export.strings(r'"a\"b"'), ['a"b'])


if __name__ == "__main__":
    unittest.main()
