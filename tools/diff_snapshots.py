#!/usr/bin/env python3
"""Diff two FFResonanceAP snapshot files (dumps/snapshots/*.json).

Prints every leaf value that changed, appeared or disappeared between the snapshots.
Used to discover which game objects and properties change when you do something in game,
for example opening a chest or receiving an item.

Usage: diff_snapshots.py BEFORE.json AFTER.json [--max N]
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Iterator


def flatten(value: Any, prefix: str = "") -> Iterator[tuple[str, Any]]:
    if isinstance(value, dict):
        for key in sorted(value):
            yield from flatten(value[key], f"{prefix}.{key}" if prefix else str(key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from flatten(item, f"{prefix}[{index}]")
    else:
        yield prefix, value


def index_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Key instances by object path instead of list position, so ordering changes don't show up as diffs."""
    flat: dict[str, Any] = {}
    for class_name, instances in snapshot.get("classes", {}).items():
        for position, instance in enumerate(instances):
            key = instance.get("path") or f"#{position}"
            for path, leaf in flatten(instance.get("properties", {})):
                flat[f"{class_name}|{key}|{path}"] = leaf
    return flat


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--max", type=int, default=500, help="maximum number of differences to print")
    args = parser.parse_args(argv)

    with open(args.before, encoding="utf-8") as f:
        before = index_snapshot(json.load(f))
    with open(args.after, encoding="utf-8") as f:
        after = index_snapshot(json.load(f))

    changes = []
    for key in sorted(before.keys() | after.keys()):
        old, new = before.get(key, "<absent>"), after.get(key, "<absent>")
        if old != new:
            changes.append((key, old, new))

    for key, old, new in changes[: args.max]:
        print(f"{key}: {old!r} -> {new!r}")
    print(f"{len(changes)} difference(s)" + (f" (showing {args.max})" if len(changes) > args.max else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
