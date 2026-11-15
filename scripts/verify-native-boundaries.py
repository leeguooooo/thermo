#!/usr/bin/env python3
"""Check native feature source dependencies from SwiftPM's dump-package JSON."""
import argparse
import json
import sys


def problems(package, complete=False):
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
        for dependency in sorted(reachable(feature) & (hosts | (features - {feature}))):
            errors.append(f"{feature} reaches forbidden implementation target {dependency}")
    if complete:
        for name in sorted(hosts):
            if name not in graph:
                errors.append(f"incomplete #41 target split: missing {name}")
        if graph.get("ThermoApp") != {"ThermoComposition"}:
            errors.append("ThermoApp must depend only on ThermoComposition")
        for host in ("ThermoKernel", "ThermoShell"):
            for feature in sorted(reachable(host) & features):
                errors.append(f"{host} reaches feature implementation {feature}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--complete", action="store_true", help="require the finished #41 graph")
    args = parser.parse_args()
    try:
        errors = problems(json.load(sys.stdin), args.complete)
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
