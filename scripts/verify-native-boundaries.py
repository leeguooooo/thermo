#!/usr/bin/env python3
"""Check native feature source dependencies from SwiftPM's dump-package JSON."""
import argparse
import json
from pathlib import Path
import re
import sys


def source_code(text):
    # Ignore embedded Swift examples and comments before inspecting import statements.
    text = re.sub(r'(?s)(#*)""".*?"""\1', '', text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def source_imports(text):
    return set(re.findall(r'(?m)^\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|package|internal|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?([A-Za-z_]\w*)', source_code(text)))


def problems(package, complete=False, source_root=None):
    graph = {}
    for target in package.get("targets", []):
        edges = set()
        for dependency in target.get("dependencies", []):
            for kind in ("byName", "target", "product"):
                if kind in dependency:
                    edges.add(dependency[kind][0])
                    break
        graph[target["name"]] = edges
    errors = []
    for name, allowed in (("ThermoUI", {"ThermoL10n"}), ("NativeFeatureAPI", {"ModuleKit"})):
        if name not in graph:
            errors.append(f"missing native boundary target: {name}")
        for dependency in sorted(graph.get(name, set()) - allowed):
            errors.append(f"{name} must not depend on {dependency}")

    if "SystemServicesAPI" in graph:
        for dependency in sorted(graph["SystemServicesAPI"] - {"ThermoKit", "ThermoL10n"}):
            errors.append(f"SystemServicesAPI must not depend on {dependency}")

    def reachable(start):
        seen, pending = set(), list(graph.get(start, set()))
        while pending:
            item = pending.pop()
            if item in seen:
                continue
            seen.add(item)
            pending.extend(graph.get(item, set()) - seen)
        return seen

    features = {name for name in graph if name.endswith("Feature")}
    hosts = {"ThermoApp", "ThermoShell", "ThermoKernel", "ThermoComposition"}
    for feature in sorted(features):
        for dependency in sorted(reachable(feature) & (hosts | {"ModuleKernelCore"} | (features - {feature}))):
            errors.append(f"{feature} reaches forbidden implementation target {dependency}")
    # The concrete kernel is already extracted, even while the shell/composition split is staged.
    for feature in sorted(reachable("ThermoKernel") & features):
        errors.append(f"ThermoKernel reaches feature implementation {feature}")
    for host in sorted(reachable("ThermoKernel") & {"ThermoApp", "ThermoShell", "ThermoComposition"}):
        errors.append(f"ThermoKernel reaches forbidden host target {host}")
    if source_root is not None:
        root = Path(source_root).resolve()
        definitions = {target["name"]: target for target in package.get("targets", [])}
        for name in sorted(graph):
            target = definitions.get(name, {})
            base = "Tests/" if target.get("type") == "test" else "Sources/"
            directory = (root / (target.get("path") or base + name)).resolve()
            if not directory.is_relative_to(root):
                errors.append(f"{name} source path escapes package")
                continue
            excluded = [(directory / path).resolve() for path in target.get("exclude", [])]
            excluded += [(directory / item["path"]).resolve() for item in target.get("resources", []) if "path" in item]
            for file in directory.rglob("*.swift"):
                path = file.resolve()
                if not path.is_relative_to(root):
                    errors.append(f"{name} source file escapes package: {file.name}")
                    continue
                if any(path == item or path.is_relative_to(item) for item in excluded):
                    continue
                text = file.read_text()
                imports = source_imports(text) & graph.keys()
                for imported in sorted(imports):
                    if imported != name and imported not in reachable(name):
                        errors.append(f"{name} imports undeclared target {imported} in {file.relative_to(root)}")
                    if complete and name in {"ThermoApp", "ThermoShell", "ThermoKernel"} and imported in features:
                        errors.append(f"{name} must not import feature implementation {imported}")
                if complete and name == "ThermoComposition":
                    exported = set(re.findall(r'@_exported\s+import\s+(\w+)', source_code(text))) & features
                    for imported in sorted(exported):
                        errors.append(f"ThermoComposition must not re-export {imported}")
    if complete:
        for name in sorted(hosts):
            if name not in graph:
                errors.append(f"incomplete #41 target split: missing {name}")
        if graph.get("ThermoApp") != {"ThermoComposition"}:
            errors.append("ThermoApp must depend only on ThermoComposition")
        for host in ("ThermoShell",):
            for feature in sorted(reachable(host) & features):
                errors.append(f"{host} reaches feature implementation {feature}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--complete", action="store_true", help="require the finished #41 graph")
    parser.add_argument("--source-root", type=Path, help="also reject imports missing from the package graph")
    args = parser.parse_args()
    try:
        errors = problems(json.load(sys.stdin), args.complete, args.source_root)
    except (ValueError, KeyError, TypeError) as error:
        print(f"invalid SwiftPM package graph: {error}", file=sys.stderr)
        return 2
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print("Native feature dependency boundaries verified" + (" (#41 complete graph)" if args.complete else " (migrated targets only)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
