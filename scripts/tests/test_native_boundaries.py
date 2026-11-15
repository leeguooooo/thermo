import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location("native_boundaries", Path(__file__).resolve().parents[1] / "verify-native-boundaries.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def target(name, *dependencies):
    return {"name": name, "dependencies": [{"byName": [dependency, None]} for dependency in dependencies]}


class NativeBoundariesTests(unittest.TestCase):
    def setUp(self):
        self.package = {"targets": [target("ModuleKit"), target("ThermoL10n"), target("NativeFeatureAPI", "ModuleKit"), target("ThermoUI", "ThermoL10n"), target("ConnectionsFeature", "NativeFeatureAPI", "ThermoUI"), target("ThermoKernel", "NativeFeatureAPI"), target("ThermoShell", "ThermoKernel", "ThermoUI"), target("ThermoComposition", "ThermoShell", "ConnectionsFeature"), target("ThermoApp", "ThermoComposition")]}

    def test_static_composition_passes_both_gates(self):
        self.assertEqual(check.problems(self.package), [])
        self.assertEqual(check.problems(self.package, complete=True), [])

    def test_feature_cannot_reach_host_through_an_innocent_bridge(self):
        self.package["targets"] += [target("Bridge", "ThermoApp")]
        self.package["targets"][4]["dependencies"].append({"target": ["Bridge", None]})
        self.assertTrue(any("ConnectionsFeature reaches forbidden implementation target ThermoApp" == error for error in check.problems(self.package)))

    def test_neutral_ui_cannot_acquire_a_business_engine(self):
        self.package["targets"][3]["dependencies"].append({"byName": ["AgentDoctor", None]})
        self.assertIn("ThermoUI must not depend on AgentDoctor", check.problems(self.package))

    def test_sibling_features_cannot_share_internal_models_via_a_bridge(self):
        self.package["targets"] += [target("DiskFeature"), target("Bridge", "DiskFeature")]
        self.package["targets"][4]["dependencies"].append({"byName": ["Bridge", None]})
        self.assertIn("ConnectionsFeature reaches forbidden implementation target DiskFeature", check.problems(self.package))

    def test_staged_graph_does_not_claim_final_completion(self):
        staged = copy.deepcopy(self.package)
        staged["targets"] = [item for item in staged["targets"] if item["name"] not in ("ThermoShell", "ThermoComposition")]
        self.assertEqual(check.problems(staged), [])
        self.assertTrue(check.problems(staged, complete=True))

    def test_kernel_cannot_import_features_in_the_final_graph(self):
        self.package["targets"][5]["dependencies"].append({"byName": ["ConnectionsFeature", None]})
        self.assertIn("ThermoKernel reaches feature implementation ConnectionsFeature", check.problems(self.package, complete=True))

    def test_extracted_kernel_cannot_reach_optional_runtime_in_a_staged_graph(self):
        self.package["targets"] += [target("Bridge", "ConnectionsFeature")]
        self.package["targets"][5]["dependencies"].append({"byName": ["Bridge", None]})
        self.assertIn("ThermoKernel reaches feature implementation ConnectionsFeature", check.problems(self.package))

    def test_system_services_api_cannot_acquire_its_own_implementation(self):
        self.package["targets"] += [target("SystemServicesAPI", "ThermoKit", "ThermoL10n", "ThermoKernel")]
        self.assertIn("SystemServicesAPI must not depend on ThermoKernel", check.problems(self.package))

    def test_undeclared_import_is_rejected_even_when_compiler_search_path_contains_it(self):
        self.package["targets"].append(target("HiddenFeature"))
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Sources/ConnectionsFeature"
            source.mkdir(parents=True)
            (source / "Feature.swift").write_text("@preconcurrency import HiddenFeature\n")
            errors = check.problems(self.package, source_root=temporary)
            self.assertTrue(any("ConnectionsFeature imports undeclared target HiddenFeature" in error for error in errors))

    def test_shared_library_cannot_silently_import_undeclared_localization(self):
        self.package["targets"].append(target("AgentCore"))
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Sources/AgentCore"
            source.mkdir(parents=True)
            (source / "Category.swift").write_text("import ThermoL10n\n")
            errors = check.problems(self.package, source_root=temporary)
            self.assertTrue(any("AgentCore imports undeclared target ThermoL10n" in error for error in errors))

    def test_executable_cannot_import_a_transitively_linked_feature(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Sources/ThermoApp"
            source.mkdir(parents=True)
            (source / "main.swift").write_text("import ConnectionsFeature\n")
            self.assertIn("ThermoApp must not import feature implementation ConnectionsFeature", check.problems(self.package, complete=True, source_root=temporary))

    def test_composition_cannot_reexport_feature_implementations(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Sources/ThermoComposition"
            source.mkdir(parents=True)
            (source / "Application.swift").write_text("@_exported import ConnectionsFeature\n")
            self.assertIn("ThermoComposition must not re-export ConnectionsFeature", check.problems(self.package, complete=True, source_root=temporary))

    def test_embedded_swift_templates_do_not_create_import_dependencies(self):
        text = '\n'.join(['// import FakeFeature', 'let code = #"""', 'import FakeFeature', '"""#', '/* import FakeFeature */', '@_implementationOnly import struct ModuleKit.ModuleManifest'])
        self.assertEqual(check.source_imports(text), {"ModuleKit"})


if __name__ == "__main__":
    unittest.main()
