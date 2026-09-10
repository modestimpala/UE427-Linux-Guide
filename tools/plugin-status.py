#!/usr/bin/env python3
"""Report which plugins of a .uproject have Linux binaries.

    tools/plugin-status.py ~/git/MyProject/MyProject.uproject [--engine ~/UnrealEngine427Src]

For every plugin the project enables it finds the .uplugin (project first, then
engine), lists the modules that are allowed on Linux, and checks whether
Binaries/Linux/libUE4Editor-<Module>.so exists.

Status:
    OK           every Linux-allowed module has a .so
    MISSING      a module is allowed on Linux but was never built
    NO-LINUX     the descriptor whitelists other platforms only (add "Linux")
    CONTENT      no modules at all, nothing to compile
    NOT-FOUND    no .uplugin anywhere (binary-only plugin, or not installed)
"""
import argparse
import json
import os
import re
import sys


def load_json(path):
    """UE tolerates trailing commas and // comments in .uplugin/.uproject files."""
    with open(path, "r", encoding="utf-8-sig") as f:
        text = f.read()
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text)


def find_uplugins(*roots):
    found = {}
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if d not in ("Binaries", "Intermediate", "Content", "Saved", "Source")]
            for name in filenames:
                if name.endswith(".uplugin"):
                    found.setdefault(name[:-len(".uplugin")], os.path.join(dirpath, name))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("uproject")
    ap.add_argument("--engine", default=os.path.expanduser("~/UnrealEngine427Src"))
    args = ap.parse_args()

    uproject = os.path.abspath(os.path.expanduser(args.uproject))
    project_dir = os.path.dirname(uproject)
    engine = os.path.abspath(os.path.expanduser(args.engine))

    catalog = find_uplugins(os.path.join(project_dir, "Plugins"),
                            os.path.join(engine, "Engine", "Plugins"))

    enabled = [p["Name"] for p in load_json(uproject).get("Plugins", []) if p.get("Enabled")]

    counts = {}
    for name in sorted(enabled):
        path = catalog.get(name)
        if not path:
            status, detail = "NOT-FOUND", ""
        else:
            plugin_dir = os.path.dirname(path)
            modules = load_json(path).get("Modules", [])
            linux_modules, blocked = [], []
            for m in modules:
                allowed = m.get("WhitelistPlatforms")
                if allowed is None or "Linux" in allowed:
                    linux_modules.append(m["Name"])
                else:
                    blocked.append(m["Name"])
            missing = [m for m in linux_modules
                       if not os.path.exists(os.path.join(
                           plugin_dir, "Binaries", "Linux", f"libUE4Editor-{m}.so"))]
            if not modules:
                status, detail = "CONTENT", ""
            elif not linux_modules:
                status, detail = "NO-LINUX", "blocked: " + ", ".join(blocked)
            elif missing:
                status, detail = "MISSING", "no .so: " + ", ".join(missing)
            else:
                status, detail = "OK", f"{len(linux_modules)} module(s)"
        counts[status] = counts.get(status, 0) + 1
        print(f"{status:<10} {name:<32} {detail}")

    print()
    print("  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 1 if counts.get("MISSING") or counts.get("NOT-FOUND") else 0


if __name__ == "__main__":
    sys.exit(main())
