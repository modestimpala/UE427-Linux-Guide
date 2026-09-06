# UE4.27 on Linux: edit natively, ship Windows paks

A working end-to-end setup for **modding a Windows UE4.27 game from Linux**:

- Edit assets in a **native Linux UE4.27 editor** (fast, no wine, no VM).
- **Cook and pak for Windows** inside Epic's patched-wine container, driven from Linux.
- Finished `.pak` files land back on your Linux filesystem, ready to drop into the game.

The reason for the split is not preference, it is a hard limitation:
**a Linux UE4.27 editor cannot cook Windows content.** `ShaderFormatD3D` — the module that
compiles D3D shaders — is gated to `Win64` in its own `.Build.cs`, so a Linux editor exposes
no usable Windows shader format at all. Everything *except* the cook can happen natively.

| Step | Runs where |
|---|---|
| Import/edit assets, blueprints, content browser | native Linux editor |
| Cook `-TargetPlatform=WindowsNoEditor` | Windows engine under wine, in docker |
| `UnrealPak -create` | same container |
| Deploy the pak | native Linux |

Verified on: Arch Linux, UE 4.27.2 source (Linux) + UE 4.27.2 binary (Windows), docker 29.7,
`epicgames/wine-patched:11.7`, project = Voices of the Void (Blueprint-only, ~21.5k packages).

In this repo:

- `README.md` — this guide.
- `tools/pakinfo.py` — prints a pak's version and mount point (§6c).

---

## 1. Get access to the Unreal Engine source

The engine source repository is private. You must link your GitHub account to your Epic
Games account first, otherwise the repo 404s for you:

1. Follow Epic's instructions at **<https://www.unrealengine.com/ue-on-github>** and accept
   the invitation that Epic emails you.
2. The 4.27 branch then becomes visible at
   **<https://github.com/EpicGames/UnrealEngine/tree/4.27>**.

Use of the engine source is governed by the [Unreal Engine EULA](https://www.unrealengine.com/eula).
Nothing from the engine tree is reproduced in this guide — only pointers to it.

```sh
git clone --depth 1 -b 4.27 git@github.com:EpicGames/UnrealEngine.git ~/UnrealEngine427Src
```

### Budget for it

| Item | Size |
|---|---|
| Source + downloaded dependencies | ~60 GB |
| After a full editor build | **~130 GB** |
| `Engine/Binaries/Linux` alone | ~7.5 GB |
| Build time (32 threads) | ~1–2 h |

## 2. Build the native Linux editor

**The engine ships its own Linux build instructions and they are the authority:**
**`Engine/Build/BatchFiles/Linux/README.md`** in the tree you just cloned. Read that file
rather than a blog post — it is short and current for your exact revision.

The shape of it, so you know what you are getting into:

```sh
cd ~/UnrealEngine427Src
./Setup.sh                  # pulls binary dependencies, ~10+ GB, sets up the toolchain
./GenerateProjectFiles.sh   # writes the Makefile / IDE projects
make UE4Editor              # or `make` for everything
make UnrealPak              # handy to have natively too
```

Prerequisites in distro terms (the engine's `Setup.sh` only automates Debian/Ubuntu):

- `clang` (the bundled cross-toolchain is fetched by `Setup.sh`), `mono`, `dotnet`/`msbuild`
  as required by your revision, `python`, `git-lfs`, plus the usual `base-devel` /
  `build-essential` set.
- On Arch: `sudo pacman -S --needed base-devel clang mono python git-lfs`. If `Setup.sh`
  complains about a missing package, install the Arch equivalent by name and re-run it; it is
  idempotent.

Result: `Engine/Binaries/Linux/UE4Editor`. Launch a project with:

```sh
~/UnrealEngine427Src/Engine/Binaries/Linux/UE4Editor "$HOME/git/MyProject/MyProject.uproject"
```

### Project plugins must exist for Linux

A Blueprint-only project needs no game module, but every **C++ plugin** it enables needs a
Linux build:

- Marketplace/engine plugins: they must be present in your Linux engine's
  `Engine/Plugins/Marketplace/` (built from source for Linux). Windows-only binary plugins
  will refuse to load.
- Project plugins with source: build them with UBT (see §7).
- A plugin that only ships `Binaries/Win64` cannot load in the Linux editor. Disable it in
  the `.uproject` for the Linux side.

## 3. Get a *Windows* 4.27 engine on disk

The container cooks with a Windows engine, so you need one — a plain copy of a Windows
UE4.27.2 installation is fine (e.g. copied from a Windows machine or an Epic Launcher
install). Put it anywhere; this guide uses `~/Unreal427`. It must contain:

```
~/Unreal427/Engine/Binaries/Win64/UE4Editor-Cmd.exe
~/Unreal427/Engine/Binaries/Win64/UnrealPak.exe
```

**Version compatibility matters.** Compare `Engine/Build/Build.version` on both sides: the
`CompatibleChangelist` must match (e.g. `17155196` for 4.27.2), or the Windows engine will
reject packages your Linux editor saved. `Changelist` itself may differ (a source build
reports `0`).

Your project's C++ plugins also need their **Win64** binaries present for the cook — the
container loads the same `.uproject`.

## 4. Build the patched-wine container

Epic maintains the wine patches and a container recipe:

```sh
git clone https://github.com/EpicGames/WineResources.git ~/git/WineResources
cd ~/git/WineResources/build
./build.sh
```

That produces the image **`epicgames/wine-patched:11.7`** (~3.8 GB). Notes worth knowing
before you run it:

- Requires Python ≥ 3.7 and Docker Engine ≥ 23. `./build.sh --layout` renders the Dockerfile
  without building, if you want to build elsewhere.
- Keep the **mitigations** (they are on by default) — they are what make UE workloads survive
  under wine.
- The container's non-root user defaults to **uid 1000**. If your uid is not 1000, pass
  `--user-id=$(id -u) --group-id=$(id -g)`, otherwise every file the cook writes into your
  bind-mounted project will be owned by the wrong user.
- The wine prefix inside the image lives at
  `/home/nonroot/.local/share/wineprefixes/prefix`; its `drive_c` is the mount target for
  everything below.
- You need to be in the `docker` group (`sudo usermod -aG docker $USER`, then re-login).

`WineResources/docs/status.md` documents which UE workloads are known to work under wine —
worth a read before assuming a workload will behave.

## 5. The mount layout

Everything the container needs is reachable through four bind mounts:

| Host | Container |
|---|---|
| Windows engine (`~/Unreal427`) | `C:/UnrealEngine` |
| Your project | `C:/p` |
| Shared DDC cache | `C:/users/nonroot/AppData/Local/UnrealEngine/Common/DerivedDataCache` |
| Boot DDC cache | `C:/users/nonroot/AppData/Local/UnrealEngine/4.27/DerivedDataCache` |

Because the project is mounted, cooked output appears **directly on your Linux filesystem**
at `<Project>/Saved/Cooked/WindowsNoEditor/<ProjectName>/…`, so you can enumerate, pak and
copy it natively.

Create the cache directories yourself before the first run:

```sh
mkdir -p ~/.cache/ue427-wine-ddc ~/.cache/ue427-wine-ddc-boot
```

**Why by hand:** docker creates missing bind-mount *parents* as **root**. Mount only the
`Common` cache and docker will create a root-owned `…/AppData/Local/UnrealEngine/`, after
which the container's `nonroot` user cannot create the `4.27/` sibling — and then the engine
logs `Could not save memory cache …/Boot.ddc` as an **Error**. See §8 for why that single
error breaks everything.

## 6. Cook and pak by hand (no plugin required)

### 6a. Full project cook

```sh
ENGINE="$HOME/Unreal427"
PROJECT="$HOME/git/MyProject"
DRIVE_C="/home/nonroot/.local/share/wineprefixes/prefix/drive_c"

docker run --rm -it --init \
    -e WINEDEBUG=-all \
    -e WINEDLLOVERRIDES=d3dcompiler_47=n \
    -v "$ENGINE:$DRIVE_C/UnrealEngine" \
    -v "$PROJECT:$DRIVE_C/p" \
    -v "$HOME/.cache/ue427-wine-ddc:$DRIVE_C/users/nonroot/AppData/Local/UnrealEngine/Common/DerivedDataCache" \
    -v "$HOME/.cache/ue427-wine-ddc-boot:$DRIVE_C/users/nonroot/AppData/Local/UnrealEngine/4.27/DerivedDataCache" \
    epicgames/wine-patched:11.7 \
    wine64 "C:/UnrealEngine/Engine/Binaries/Win64/UE4Editor-Cmd.exe" \
        "C:/p/MyProject.uproject" \
        -run=Cook -TargetPlatform=WindowsNoEditor \
        -unversioned -NullRHI -NoSound -NoSplash \
        -unattended -nopause -nocrashreports -NoCrashDialog \
        -stdout -FullStdOutLogOutput \
    2>&1 | tee ~/cook-full.log
```

This is the slow one (tens of minutes; it compiles every shader). Do it **once** — it fills
the shared DDC, after which per-mod cooks take seconds.

`-run=Cook` produces **loose cooked files only**. It never makes a pak:

```
<Project>/Saved/Cooked/WindowsNoEditor/<ProjectName>/{Content/,AssetRegistry.bin,Metadata/}
<Project>/Saved/Cooked/WindowsNoEditor/Engine/
```

### 6b. Cook only what you changed

Two flags turn on scoped cooking, and you need **both**:

```
-cooksinglepackagenorefs      # actually enables single-package mode in 4.27
-cooksinglepackage            # despite the name: KEEP hard references
-iterate                      # reuse previous cook results
-Map=/Game/Mods/MyMod/Foo -Map=/Game/Mods/MyMod/Bar …
```

Append those to the command in §6a. Meaning: *cook exactly these packages plus what they
hard-reference, nothing else*. Without them, a cook that requests no maps falls back to
cooking every map in the project.

Consequences to plan around:

- Single-package mode makes **`-CookDir` a no-op**, so folders must be expanded into explicit
  `-Map=` switches. Under `/Game`, a package name *is* its file path, so a plain `find` over
  `<Project>/Content/<sub>` for `*.uasset`/`*.umap` gives you the list — no editor needed.
- `-Map=` values are **split on `+`**, so a package whose name contains `+` cannot be
  requested at all.
- wine hands the command line to a Windows process, so the **32767-character** Windows limit
  applies. Split long selections across several cook runs; it makes no difference to the pak.

A 56-package mod cook against a warm DDC takes **~25 s** end to end, including paking.

### 6c. Pak it

`UnrealPak` takes a response file of `"<source>" "<mount path>"` pairs. Sources must be
**container** paths (it runs under wine); mount paths are what the shipped game looks for:

```
"C:/p/Saved/Cooked/WindowsNoEditor/MyProject/Content/Mods/MyMod/Foo.uasset" "../../../MyProject/Content/Mods/MyMod/Foo.uasset"
```

Generate one and run it:

```sh
COOKED="$PROJECT/Saved/Cooked/WindowsNoEditor/MyProject/Content"
mkdir -p "$PROJECT/Saved/ModPackager"
: > "$PROJECT/Saved/ModPackager/MyMod.txt"
find "$COOKED/Mods/MyMod" -type f | while IFS= read -r f; do
    rel="${f#"$COOKED/"}"
    printf '"%s" "%s"\n' \
        "C:/p/Saved/Cooked/WindowsNoEditor/MyProject/Content/$rel" \
        "../../../MyProject/Content/$rel" \
        >> "$PROJECT/Saved/ModPackager/MyMod.txt"
done

docker run --rm --init -e WINEDEBUG=-all \
    -v "$ENGINE:$DRIVE_C/UnrealEngine" -v "$PROJECT:$DRIVE_C/p" \
    epicgames/wine-patched:11.7 \
    wine64 "C:/UnrealEngine/Engine/Binaries/Win64/UnrealPak.exe" \
        "C:/p/Saved/ModPackager/MyMod.pak" \
        "-create=C:/p/Saved/ModPackager/MyMod.txt" \
        -compress
```

Verify what you built — this is the step that catches wrong mount paths:

```sh
docker run --rm -e WINEDEBUG=-all \
    -v "$ENGINE:$DRIVE_C/UnrealEngine" -v "$PROJECT:$DRIVE_C/p" \
    epicgames/wine-patched:11.7 \
    wine64 "C:/UnrealEngine/Engine/Binaries/Win64/UnrealPak.exe" \
        "C:/p/Saved/ModPackager/MyMod.pak" -List 2>&1 | tr -d '\000\r' | head

# mount point + pak version, read from the pak index (see tools/pakinfo.py)
tools/pakinfo.py "$PROJECT/Saved/ModPackager/MyMod.pak"
```

```
version:     11
mount point: ../../../MyProject/Content/Mods/MyMod/
```

`-List` prints entries *relative to the mount point*, so bare filenames there are correct,
not a bug — the mount point is the thing to check. Do **not** grep the pak for
`../../../`: cooked assets embed such strings themselves, so you will read the wrong one and
conclude your mount paths are broken when they are fine.

Name a patch pak `something_P.pak` if it must **override** assets that ship with the game:
Unreal gives `*_P.pak` a higher mount priority.

### 6d. Paking natively (optional)

`UnrealPak` is a plain archiver — the *contents* are already Windows-cooked, so the Linux
`Engine/Binaries/Linux/UnrealPak` can build the pak too, with host paths in the response
file. It is faster (no container start). Cooking is the part that must stay in wine.

## 7. Building a C++ editor plugin for the Linux editor

```sh
~/UnrealEngine427Src/Engine/Build/BatchFiles/Linux/Build.sh \
    UE4Editor Linux Development \
    -Project="$HOME/git/MyProject/MyProject.uproject" -TargetType=Editor
```

Output: `MyProject/Plugins/<Plugin>/Binaries/Linux/libUE4Editor-<Plugin>.so` (~40 s for a
single small module). Works on Blueprint-only projects — adding a code plugin does not
require a game module.

**Gate editor-only tooling plugins to Linux** in the `.uplugin`:

```json
"Modules": [ { "Name": "MyTool", "Type": "Editor", "LoadingPhase": "Default",
               "WhitelistPlatforms": [ "Linux" ] } ]
```

Without that, the **Windows** cook loads the same `.uproject`, looks for
`UE4Editor-MyTool.dll`, does not find it, and refuses to start. (4.27 uses
`WhitelistPlatforms`; `PlatformAllowList` is UE5.)

## 8. Gotchas that will eat an afternoon

**A single logged error fails the cook, even when the cook succeeded.**
`LaunchEngineLoop` prints `Failure - N error(s)` and returns exit code **1** if anything was
logged at `Error` severity — the cook commandlet itself still reports `result 0`. So
`LogDerivedDataCache: Error: Could not save memory cache …/Boot.ddc` alone makes every
scripted cook look failed while producing perfect output. Fix it by mounting the boot DDC
directory (§5), not by ignoring exit codes.

**`-UTF8Output` makes wine emit UTF-16 logs.** Your `grep` silently matches nothing because
the text is NUL-interleaved. Leave the flag off; if you already have such a log:
`tr -d '\000\r' < log | less`.

**Docker creates missing mount parents as root** (§5). Any "the engine ignores my cache"
symptom is usually this.

**Project paths with spaces** (`~/git/VotV 4.27`) work everywhere here, but quote every
`-v "$PROJECT:…"` and remember the container path (`C:/p`) has no space, so
container-side command lines stay simple.

**Boot.ddc vs the real cache.** The `Common/DerivedDataCache` mount is the one that matters
for speed (shaders, textures). The `4.27/…/Boot.ddc` snapshot only saves a couple of seconds
of engine init — mount it purely so the write does not fail (see above).

**Harmless noise you can ignore** in wine cook logs: `aqProf.dll`/`VtuneApi.dll` load
failures, `MLSDK not found`, `Unable to create Visual Studio setup instance`, `PIX capture
plugin failed`, `RTSCom.dll` / StylusInput, missing `Game.locmeta`.

**Not harmless:** `LogMaterial: Warning: … Failed to compile Material Instance … Default
Material will be used in game` and `LogAudio: … Failed to build OGG derived data` — those
mean the asset in question will be broken in-game.

**Two editors, one project.** Do not run a second editor instance against the same project
directory; they fight over `Saved/Config` and the asset registry.

## 9. ModPackager: the one-click version

Once the manual flow works, the plugin removes the ceremony: right-click a folder or an asset
selection in the Content Browser → it cooks *just that* in the container, paks it, and copies
the result where you want it.

**Repo: <https://github.com/modestimpala/UE4-Modding-Plugins>** (`ModPackager`; use the Linux
branch — the original targets a Windows editor).

### What it actually does

1. Expands your selection via the **asset registry** (and optionally walks hard dependencies).
2. Saves dirty content packages, warns about anything still dirty and in scope.
3. Deletes the previously cooked output for that selection, so deleted assets cannot linger.
4. Runs the scoped cook in `epicgames/wine-patched:11.7` (§6b), splitting `-Map=` lists to
   stay under the Windows command-line limit.
5. Enumerates the cooked files natively, writes the response file with container source paths
   and `../../../<Project>/Content/…` mount paths, runs `UnrealPak -create -compress` (§6c).
6. Copies the pak to your deploy folder and toasts you with a link to it.

Everything after step 3 lives in a single script, `Plugins/ModPackager/Scripts/modpak.sh`,
so it also works with **no editor running**:

```sh
printf '/Game/Mods/MyMod\n' > /tmp/folders.txt
Plugins/ModPackager/Scripts/modpak.sh \
    --project "$PWD" --name MyMod --folders /tmp/folders.txt --out ~/mods
# …
# MODPAK_RESULT ok files=114 bytes=1023989 pak=/home/you/mods/MyMod.pak
```

Individual assets go in a `--packages` file (`/Game/audio/00000000audio`, one per line).
Useful flags: `--dry-run` (print the docker commands and stop), `--platform`, `--engine`,
`--image`, `--ddc`, `--no-compress`, `--no-iterate`, `--no-clean`, `--cookdir`. Environment
overrides: `MODPAK_ENGINE`, `MODPAK_IMAGE`, `MODPAK_DDC`, `MODPAK_BOOT_DDC`, `MODPAK_DOCKER`,
`MODPAK_DRIVE_C`.

### Install

```sh
cp -r ModPackager "$HOME/git/MyProject/Plugins/"
# enable "ModPackager" in MyProject.uproject
~/UnrealEngine427Src/Engine/Build/BatchFiles/Linux/Build.sh UE4Editor Linux Development \
    -Project="$HOME/git/MyProject/MyProject.uproject" -TargetType=Editor
```

Restart the editor. You get Content Browser entries (**Package Mod**, **Package Patch Pak**,
plus "…to Last Location" / "…to…" variants) and **Tools → Mod Packager** with
**Rebuild Last Pak** (Ctrl+Alt+P).

Defaults assume `~/Unreal427` and `~/.cache/ue427-wine-ddc`; override them in
**Project Settings → Plugins → Mod Packager** along with the deploy folder, compression,
iterative cooking, precise cooking, `_P` suffix and dependency inclusion.

### Two Linux-specific details worth stealing for your own tooling

- **The folder picker runs off the game thread.** Waiting on `kdialog`/`zenity` from the game
  thread stops Slate pumping: the editor appears frozen and the dialog can end up behind the
  dead window. Spawn the picker on a worker, resume on the game thread with the answer. (The
  editor's own `IDesktopPlatform` dialog *is* safe on the game thread — it pumps Slate — but
  it has none of your desktop's places/bookmarks, which hurts when deploy targets live in
  Proton prefixes.)
- **Gate the module to Linux** (`WhitelistPlatforms`, §7), or your own plugin will break the
  Windows cook it is trying to drive.

## 10. Troubleshooting

| Symptom | Cause |
|---|---|
| Cook exits 1, output looks fine | Something logged an `Error`; check `Failure - N error(s)` near the end. Usually Boot.ddc (§5/§8). |
| `grep` finds nothing in a cook log | UTF-16 output from `-UTF8Output` (§8). |
| Cook cooks the whole project | Missing `-cooksinglepackagenorefs -cooksinglepackage` (§6b). |
| `-CookDir` ignored | Expected in single-package mode; expand to `-Map=` (§6b). |
| Cook aborts: plugin module not found | A project plugin has no Win64 binary, or an editor plugin is not gated to Linux (§7). |
| Game ignores the pak | Wrong mount point (check with `tools/pakinfo.py`), or it needs the `_P` suffix to win over base content (§6c). |
| Every cook recompiles shaders | DDC mount missing or root-owned (§5). |
| Editor refuses to load a marketplace plugin | No Linux build of it (§2). |
| Windows engine rejects your assets | `CompatibleChangelist` mismatch (§3). |

---

## Licensing

This guide is original documentation; it deliberately paraphrases rather than reproduces
anything from the Unreal Engine source tree, which is governed by the
[Unreal Engine EULA](https://www.unrealengine.com/eula). `WineResources` is MIT-licensed by
Epic Games. Read `WineResources/docs/licenses.md` before shipping anything that runs
proprietary Windows tooling under wine.
