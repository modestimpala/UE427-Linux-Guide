#!/usr/bin/env bash
# Copy marketplace plugin sources from a Windows UE4.27 install into a Linux
# source build, write a stub project that enables all of them, and build them.
#
#   ./tools/port-plugins.sh                 # copy + generate stub + build
#   ./tools/port-plugins.sh --no-build      # copy + generate stub only
#   ./tools/port-plugins.sh --no-copy       # stub + build only
#   ./tools/port-plugins.sh --overwrite     # re-copy over files you already fixed
#   ./tools/port-plugins.sh --dry-run       # print what would happen
#
# Existing files are left alone by default, so a second run never throws away the
# Linux fixes you made. Use --overwrite to force a fresh copy from Windows.
#
# Override paths with env vars or flags:
#   WIN_ENGINE   Windows engine root      (default ~/Unreal427)
#   LIN_ENGINE   Linux source build root  (default ~/UnrealEngine427Src)
#   STUB         stub project dir         (default ~/PluginBuild)

set -euo pipefail

WIN_ENGINE="${WIN_ENGINE:-$HOME/Unreal427}"
LIN_ENGINE="${LIN_ENGINE:-$HOME/UnrealEngine427Src}"
STUB="${STUB:-$HOME/PluginBuild}"
DO_BUILD=1
DO_COPY=1
OVERWRITE=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --win-engine) WIN_ENGINE="$2"; shift 2 ;;
        --lin-engine) LIN_ENGINE="$2"; shift 2 ;;
        --stub)       STUB="$2";       shift 2 ;;
        --no-build)   DO_BUILD=0;      shift ;;
        --no-copy)    DO_COPY=0;       shift ;;
        --overwrite)  OVERWRITE=1;     shift ;;
        --dry-run)    DRY=1;           shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

SRC_DIR="$WIN_ENGINE/Engine/Plugins/Marketplace"
DST_DIR="$LIN_ENGINE/Engine/Plugins/Marketplace"

[ -d "$SRC_DIR" ] || { echo "no marketplace plugins at $SRC_DIR" >&2; exit 1; }
[ -d "$LIN_ENGINE/Engine/Build/BatchFiles/Linux" ] || { echo "not an engine source tree: $LIN_ENGINE" >&2; exit 1; }

echo "windows engine : $WIN_ENGINE"
echo "linux engine   : $LIN_ENGINE"
echo "stub project   : $STUB"
echo

run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }

# 1. copy sources (never the Windows Binaries/Intermediate)
if [ "$DO_COPY" = 1 ]; then
    KEEP=--ignore-existing
    [ "$OVERWRITE" = 1 ] && KEEP=
    run mkdir -p "$DST_DIR"
    for d in "$SRC_DIR"/*/; do
        name="$(basename "$d")"
        if [ -d "$d/Source" ]; then
            kind="source"
        elif [ -d "$d/Content" ]; then
            kind="content-only"
        else
            echo "skip      $name (no Source, no Content)"
            continue
        fi
        printf 'copy      %-32s %s\n' "$name" "$kind"
        run rsync -a ${KEEP:+$KEEP} \
            --exclude 'Binaries/' --exclude 'Intermediate/' --exclude 'Saved/' \
            "$d" "$DST_DIR/$name/"
    done
fi

# 2. stub project: UBT only compiles plugins a project references
echo
echo "writing $STUB/PluginBuild.uproject"
if [ "$DRY" = 0 ]; then
    mkdir -p "$STUB"
    python3 - "$DST_DIR" "$STUB/PluginBuild.uproject" <<'PY'
import json, os, sys
dst, out = sys.argv[1], sys.argv[2]
names = []
for entry in sorted(os.listdir(dst)):
    d = os.path.join(dst, entry)
    if not os.path.isdir(d) or not os.path.isdir(os.path.join(d, "Source")):
        continue
    up = [f for f in os.listdir(d) if f.endswith(".uplugin")]
    if not up:
        continue
    # the plugin name is the .uplugin filename, not the folder name
    names.append(os.path.splitext(up[0])[0])
proj = {
    "FileVersion": 3,
    "EngineAssociation": "4.27",
    "Category": "",
    "Description": "stub project used only to force UBT to build marketplace plugins",
    "Plugins": [{"Name": n, "Enabled": True} for n in names],
}
with open(out, "w") as f:
    json.dump(proj, f, indent="\t")
    f.write("\n")
print(f"{len(names)} plugins enabled")
PY
fi

# 3. build
if [ "$DO_BUILD" = 1 ]; then
    echo
    echo "building UE4Editor against the stub project"
    run "$LIN_ENGINE/Engine/Build/BatchFiles/Linux/Build.sh" \
        UE4Editor Linux Development \
        -Project="$STUB/PluginBuild.uproject" -TargetType=Editor -progress
    echo
    echo "errors (if any):"
    grep -E "error:|ERROR:" "$LIN_ENGINE/Engine/Programs/UnrealBuildTool/Log.txt" \
        | sed 's/^.*ActionDebugOutput: //' | sort -u || true
fi
