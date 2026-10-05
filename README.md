# UE4.27 on Linux: edit natively, ship Windows paks

This is a full guide for **modding a Windows UE4.27 game from Linux**. 
To follow this guide, you will need basic/mid level Linux experience and feel somewhat comfortable behind a terminal. 
You will also need a fully downloaded UE4.27 **Windows** Editor build alongside the Native Linux Editor. UE source access requires Epic access.

What makes this guide easier is having modding/Unreal experience, although it is not required. It's also faster if you already have an existing modding setup on Windows. 

- Edit assets in a **native Linux UE4.27 editor** (fast, no wine, no VM).
- **Cook and pak for Windows** inside Epic's patched-wine container, driven from Linux.
- Finished `.pak` files land back on your Linux filesystem, ready to drop into the game.

The reason for this setup is the fact that a Linux UE4.27 editor cannot cook Windows content. `ShaderFormatD3D` is gated to `Win64` in its own `.Build.cs`, so a Linux editor exposes
no usable Windows shader format at all. For a Windows-only UE game, this is a hard blocker for any native Linux user wanting to create blueprint mods. 

| Step | Runs where |
|---|---|
| Import/edit assets, blueprints, content browser | native Linux editor |
| Cook `-TargetPlatform=WindowsNoEditor` | Windows engine under wine, in docker |
| `UnrealPak -create` | same container |
| Deploy the pak | native Linux |

I personally ran this on Arch Linux, with UE 4.27.2 source (Linux) + UE 4.27.2 binary (Windows), docker 29.7,
`epicgames/wine-patched:11.7`, project = Voices of the Void. 

In this repo:

- `README.md` - this guide.
- `tools/pakinfo.py` - prints a pak's version and mount point (§7c).
- `tools/port-plugins.sh` - copies marketplace plugins from a Windows engine and builds them
  for Linux (§4).
- `tools/plugin-status.py` - lists which of a project's plugins have Linux binaries (§4f).


### Budget/Requirements

| Item | Size |
|---|---|
| Linux source + downloaded dependencies (§2) | ~60 GB |
| Linux source after a full editor build (§2) | **~130 GB** |
| `Engine/Binaries/Linux` alone | ~7.5 GB |
| Windows 4.27 engine copy (§3) | **~48 GB** |
| of that, `Engine/Plugins/Marketplace` | ~6 GB |
| `epicgames/wine-patched:11.7` image (§5) | ~3.8 GB |
| Shared DDC after one full cook (§6) | ~3 GB |
| Cooked output for a 21.5k-package project (§7a) | ~3 GB |
| **Total, engines + container + caches** | **~185 GB** |
| Build time (32 threads) | ~1-2 h |

Your project is on top of that: the Voices of the Void tree used here is ~14 GB including
its cooked output. So plan for **~200 GB free** before you start, on a fast disk.

<img width="1215" height="843" alt="image" src="https://github.com/user-attachments/assets/9eba1f78-fe4d-4e22-86a2-738c39007d75" />

---

## 1. Get access to the Unreal Engine source

The native engine source repo is private. You have to link your GitHub account to your Epic
Games account first, or the repo 404s:

1. Follow Epic's instructions at **<https://www.unrealengine.com/ue-on-github>** .
2. The 4.27 branch then becomes visible at
   **<https://github.com/EpicGames/UnrealEngine/tree/4.27>**.

Use of the engine source is governed by the [Unreal Engine EULA](https://www.unrealengine.com/eula).

```sh
git clone -b 4.27 git@github.com:EpicGames/UnrealEngine.git ~/UnrealEngine427Src
```

## 2. Build the native Linux editor

**The engine ships its own Linux build instructions:**
**`Engine/Build/BatchFiles/Linux/README.md`** in the tree you just cloned. Read that file
or search online if you have issues building on your system.

It's roughly:

```sh
cd ~/UnrealEngine427Src
./Setup.sh                  # pulls binary dependencies, ~10+ GB, sets up the toolchain
./GenerateProjectFiles.sh   # writes the Makefile / IDE projects
make UE4Editor              # or `make` for everything
make UnrealPak              # handy to have natively too
```

Prerequisites (the engine's `Setup.sh` only automates Debian/Ubuntu):

- `clang` (the bundled cross-toolchain is fetched by `Setup.sh`), `mono`, `dotnet`/`msbuild`
  as required by your revision, `python`, `git-lfs`, plus the usual `base-devel` /
  `build-essential` set.
- On Arch: `sudo pacman -S --needed base-devel clang mono python git-lfs`. 

Expect a long initial build time.

Result: `Engine/Binaries/Linux/UE4Editor`. Launch a project with:

```sh
~/UnrealEngine427Src/Engine/Binaries/Linux/UE4Editor 
```

### Project plugins must exist for Linux

A Blueprint-only project needs no game module, but every **C++ plugin** it enables needs a
Linux build, both the marketplace ones (which live in the engine) and the ones in
`MyProject/Plugins/`. A plugin that only ships `Binaries/Win64` cannot load here at all.

In this example we're modding against VotV. It's heavy Blueprint, but specifically extra Blueprint Plugins, like VictoryBP. 
These need to be built against the native Linux editor to allow access to their nodes. 

That is the fiddly/weird part of the whole setup, so it has its own section: §4.

## 3. Get a *Windows* 4.27 engine on disk

The container cooks with a Windows engine, so you need one - a plain copy of a Windows
UE4.27.2 installation is fine (e.g. copied from a Windows machine or an Epic Launcher
install in Bottles). Put it anywhere; this guide uses `~/Unreal427`. It must contain:

```
~/Unreal427/Engine/Binaries/Win64/UE4Editor-Cmd.exe
~/Unreal427/Engine/Binaries/Win64/UnrealPak.exe
```

Copy an install that already has all your marketplace plugins installed and working. That
copy is both the cooker and the source of the plugin code you port to Linux in §4, so grab it
from a machine where the project opens fine:

```
~/Unreal427/Engine/Plugins/Marketplace/<Plugin>/Source/...
```

I suppose you could technically just mount a shared drive of some sort with Windows as well and just share an editor location. You could also use Bottles/Lutris + Epic Launcher to download the Windows editor and plugins inside of Linux, however that isn't covered here. 

**Version compatibility matters.** Compare `Engine/Build/Build.version` on both sides: the
`CompatibleChangelist` must match (e.g. `17155196` for 4.27.2), or the Windows engine will
reject packages your Linux editor saved. `Changelist` itself may differ (a source build
reports `0`).

Your project's C++ plugins also need their **Win64** binaries present for the cook - the
container loads the same `.uproject`. If they're not built, you may need to build them inside of the patched Wine container, or on a seperate Windows install. 

## 4. Port your marketplace plugins to the Linux engine

Windows plugins usually reside in the `Engine/Plugins/Marketplace/` folder. (Epic Launcher/Fab installed). The Linux editor needs these to open the project or it just won't open. 
So copy the sources over, build them all once, and fix the few that do not compile.

Two rules:

- Only plugins that ship a `Source/` folder can be ported. A plugin that ships only
  `Binaries/Win64` is just DoA on Linux, no way around it.
- Never copy `Binaries/` or `Intermediate/` from Windows. Those are Win64 DLLs and stale
  build state.

Leave the Windows engine from §3 untouched. It keeps its own Win64 plugin binaries, which is
what the wine cook (§7) loads.

This repo has some tools to assist in porting plugins:

### 4a. Set the variables

```sh
WIN_ENGINE="$HOME/Unreal427"            # Windows 4.27 install (§3)
LIN_ENGINE="$HOME/UnrealEngine427Src"   # Linux source build (§2)
PROJECT="$HOME/git/MyProject"
STUB="$HOME/PluginBuild"                # throwaway project, see §4c
```

### 4b. Copy the plugin sources

```sh
tools/port-plugins.sh --no-build
```

Or by hand:

```sh
mkdir -p "$LIN_ENGINE/Engine/Plugins/Marketplace"
for d in "$WIN_ENGINE"/Engine/Plugins/Marketplace/*/; do
    rsync -a --ignore-existing \
        --exclude 'Binaries/' --exclude 'Intermediate/' --exclude 'Saved/' \
        "$d" "$LIN_ENGINE/Engine/Plugins/Marketplace/$(basename "$d")/"
done
```

`--ignore-existing` matters once you start fixing code: a plain `rsync -a` on the second run
copies the Windows version back over every fix you made. The script defaults to the safe
behaviour and only overwrites with `--overwrite`.

30 plugins were about 78 MB of source here. Copy content-only plugins (no `Source/`, just
`Content/`) too: nothing compiles, but the project still wants the assets.

**The folder name is not the plugin name.** The plugin name is the `.uplugin` file name:
`BlueprintWebsockets/` holds `EasyWebsockets.uplugin`, `ZenMode_4.27/` holds
`ZenDev.uplugin`,  Your `.uproject` lists plugin names, so always go by the `.uplugin`.

### 4c. Build them all with a stub project

UBT only compiles an engine plugin when a project enables it. Marketplace descriptors have
`"Installed": true` and no `EnabledByDefault`, and `PluginInfo.IsEnabledByDefault`
(`Engine/Source/Programs/UnrealBuildTool/System/Plugins.cs`) then returns true only for
plugins loaded from a project. A plain `make UE4Editor` builds none of them.

So make a throwaway project that enables everything and build against that. Your real project
stays out of it until the plugins are known good.

```sh
mkdir -p "$STUB"
python3 - "$LIN_ENGINE" "$STUB/PluginBuild.uproject" <<'EOF'
import json, os, sys
root = os.path.join(sys.argv[1], "Engine/Plugins/Marketplace")
names = []
for e in sorted(os.listdir(root)):
    d = os.path.join(root, e)
    if os.path.isdir(os.path.join(d, "Source")):
        names += [f[:-8] for f in os.listdir(d) if f.endswith(".uplugin")]
json.dump({"FileVersion": 3, "EngineAssociation": "4.27",
           "Plugins": [{"Name": n, "Enabled": True} for n in names]},
          open(sys.argv[2], "w"), indent="\t")
EOF

"$LIN_ENGINE/Engine/Build/BatchFiles/Linux/Build.sh" UE4Editor Linux Development \
    -Project="$STUB/PluginBuild.uproject" -TargetType=Editor -progress
```

`tools/port-plugins.sh` does the copy, the stub and this build in one go.

This takes a couple of minutes, not hours: the engine is already built, only plugin modules
compile. When it fails, the readable error list is in the UBT log, not in the terminal spam:

```sh
grep -E "error:|ERROR:" "$LIN_ENGINE/Engine/Programs/UnrealBuildTool/Log.txt" \
    | sed 's/^.*ActionDebugOutput: //' | sort -u
```

Fix, rebuild, repeat until it exits 0. 30 plugins produced 47 `.so` files here.

### 4d. The fixes you will need

Windows builds with MSVC on a case-insensitive filesystem. Linux builds with clang, `-Werror`
and real case rules, so plugin code that was never built for Linux breaks in the same handful
of ways.

| Error | Cause | Fix |
|---|---|---|
| `'HAL/PlatformFileManager.h' file not found` | the engine header is `PlatformFilemanager.h`, small `m` | one sed, see below |
| `'HTTPManager.h' file not found` | the engine header is `HttpManager.h` | same |
| `'FooMacros.h' file not found` while the file is sitting right there | the plugin's own header is misspelled by case (`AutoSIzeCommentsMacros.h`) | `mv` the file to the spelling the includes use |
| `'&&' within '\|\|' [-Werror,-Wlogical-op-parentheses]` | MSVC does not care, clang does | parenthesize the `&&` groups |
| `loop variable 'X' creates a copy [-Werror,-Wrange-loop-construct]` | `for (const FString X : Set)` copies | `for (const FString& X : Set)` |
| `expression result unused [-Werror,-Wunused-value]` | a statement like `Foo::Bar;` with the `return` missing | add the `return` |
| `'/*' within block comment [-Werror,-Wcomment]` | nested comment | delete the inner `/*` |
| `conditional expression is ambiguous; 'TSubclassOf<UObject>' ... 'UClass *'` | clang refuses the two-way implicit conversion | cast both arms to the same type |
| builds fine but no `.so` appears | the `.uplugin` module has `WhitelistPlatforms` without `Linux` | add `"Linux"` |
| `Unable to find module 'X'`, whole build stops | the plugin has no `Source/` | it cannot be built, move it out (§4e) |

The two include-case fixes as one-liners:

```sh
cd "$LIN_ENGINE/Engine/Plugins/Marketplace"
grep -rl 'HAL/PlatformFileManager\.h' . | xargs -r sed -i 's|HAL/PlatformFileManager\.h|HAL/PlatformFilemanager.h|g'
grep -rl '"HTTPManager\.h"' .          | xargs -r sed -i 's|"HTTPManager\.h"|"HttpManager.h"|g'
```

Whitelisting Linux is an edit in the `.uplugin`:

```json
"Modules": [
    { "Name": "VictoryBPLibrary", "Type": "Runtime", "LoadingPhase": "PreDefault",
      "WhitelistPlatforms": [ "Win64", "Win32", "Linux" ] }
]
```

Plugins that needed only that: EasyWebsockets, DriftIslandPlugin, NativeFunctionLibrary,
PhysicalLayout, RuntimeImageLoader, SimpleXML, VictoryBP. If your `.uproject` also lists the
plugin with `"SupportedTargetPlatforms": [ "Win64" ]`, add `"Linux"` there too, or UBT skips
it again.

**Third-party libs with UE5 paths.** A plugin written for UE5 can point at library folders
that 4.27 lays out differently. RuntimeAudioImporter links libvorbisenc from
`Vorbis/libvorbis-1.3.2/lib/Unix/<arch>/`, but 4.27 ships it under `lib/Linux/<arch>/`, so the
link fails with `ld.lld: error: cannot open .../lib/Unix/x86_64-unknown-linux-gnu/libvorbisenc.a`.
Probe for both in the `.Build.cs`:

```csharp
string VorbisLibPath = Path.Combine(Target.UEThirdPartySourceDirectory, "Vorbis", "libvorbis-1.3.2", "lib");
// UE4 keeps the Unix libs under lib/Linux/<arch>, UE5 under lib/Unix/<arch>
string VorbisPlatformDir = Directory.Exists(Path.Combine(VorbisLibPath, "Unix")) ? "Unix" : "Linux";
PublicAdditionalLibraries.Add(Path.Combine(VorbisLibPath, VorbisPlatformDir, Target.Architecture, "libvorbisenc.a"));
```

**Engine plugins are gated too.** SteamAudio is whitelisted to Win32/Win64/Android in 4.27
even though `Engine/Source/ThirdParty/libPhonon/phonon_api/lib/Linux64/libphonon.so` ships in
the tree. Three edits make it build and load. First a Linux branch in
`Engine/Source/ThirdParty/libPhonon/LibPhonon.Build.cs`, next to the Android one:

```csharp
else if (Target.Platform == UnrealTargetPlatform.Linux)
{
    string LinuxBinaryPath = System.IO.Path.Combine(Target.UEThirdPartyBinariesDirectory, "Phonon", "Linux");

    PublicAdditionalLibraries.Add(System.IO.Path.Combine(LinuxBinaryPath, "libphonon.so"));
    PublicRuntimeLibraryPaths.Add(LinuxBinaryPath);
    RuntimeDependencies.Add(System.IO.Path.Combine(LinuxBinaryPath, "libphonon.so"));
}
```

Then put the shared library where that path expects it, and whitelist Linux for both modules:

```sh
cd "$LIN_ENGINE/Engine"
mkdir -p Binaries/ThirdParty/Phonon/Linux
cp Source/ThirdParty/libPhonon/phonon_api/lib/Linux64/libphonon.so Binaries/ThirdParty/Phonon/Linux/
# add "Linux" to both WhitelistPlatforms in Plugins/Runtime/Steam/SteamAudio/SteamAudio.uplugin
```

Build again, then check the link, because a module that loads and then cannot find its
shared library fails at runtime instead of at build time:

```sh
ldd "$LIN_ENGINE/Engine/Plugins/Runtime/Steam/SteamAudio/Binaries/Linux/libUE4Editor-SteamAudio.so" | grep phonon
```

### 4e. Project plugins

Plugins under `MyProject/Plugins/` build when you build the editor target against the
project:

```sh
"$LIN_ENGINE/Engine/Build/BatchFiles/Linux/Build.sh" UE4Editor Linux Development \
    -Project="$PROJECT/MyProject.uproject" -TargetType=Editor -progress
```

They break the same ways marketplace plugins do, so apply the same fixes inside
`$PROJECT/Plugins`.

**`"Enabled": false` in the `.uproject` does not stop the build.** UBT scans
`MyProject/Plugins/` and compiles every module it finds there. A plugin you cannot fix has to
leave the folder:

```sh
mkdir -p "$PROJECT/PluginsDisabled"
mv "$PROJECT/Plugins/BrokenPlugin" "$PROJECT/PluginsDisabled/"
```

A binary-only plugin is worse than a broken one: `Unable to find module 'X'` aborts the whole
makefile, so nothing builds until you move it out. Set `"Enabled": false` for it as well so
the editor does not hunt for it. Move the folder back and flip the flag to restore it.

Editor-only plugins you wrote yourself must also be gated to Linux, or they break the Windows
cook that loads the same `.uproject` - see §8.

### 4f. Check what actually built

```sh
tools/plugin-status.py "$PROJECT/MyProject.uproject" --engine "$LIN_ENGINE"
```

```
OK         RuntimeAudioImporter             2 module(s)
OK         VictoryBP                        1 module(s)
NO-LINUX   WindowsDialogBox                 blocked: WindowsDialogBox
CONTENT    DefaultValues

CONTENT=1  NO-LINUX=2  OK=40
```

It reads every enabled plugin from the `.uproject`, finds its `.uplugin` in the project or the
engine, and checks `Binaries/Linux/libUE4Editor-<Module>.so` for each module Linux is allowed
to build. `MISSING` or `NOT-FOUND` is what makes the editor complain at startup.

### 4g. What could not be ported

| Plugin | Why |
|---|---|
| WindowsDialogBox | the module is raw Win32 `MessageBox`, there is nothing to port it to |
| ModelingToolsEditorMode, MeshModelingToolset | Epic gates all six modules to Win64 in 4.27, and the editor-only ones need ProxyLOD, which needs Embree, which ships Win64 and Mac only |
| DefaultValues | content-only plugin, nothing to compile |
| any plugin with `Binaries/Win64` and no `Source/` | nothing to compile from |

For a Blueprint-only project that is usually fine: you lose the tool in the Linux editor, and
the Windows engine still has it for the cook.

## 5. Build the patched-wine container

Epic maintains the wine patches and a container recipe. Honestly, this is the whole thing that makes this work. I've previously spent entire weekends trying to get Linux cooks working, and on this instance, another couple of hours before finally trying their custom container. 

The container and workflow is actually for UE5+, but it surprisingly applies to UE4.27 just the same. Without this you'd likely have to manually install all of their patches/shims (I didn't bother attempting this, the container works perfectly):

```sh
git clone https://github.com/EpicGames/WineResources.git ~/WineResources
cd ~/WineResources/build
./build.sh
```

That produces the image **`epicgames/wine-patched:11.7`** (~3.8 GB). Notes worth knowing
before you run it:

- Requires Python ≥ 3.7, Docker Engine ≥ 23 **and the buildx plugin**. On Arch, buildx is a
  separate package, and the daemon is not started for you:

  ```sh
  sudo pacman -S --needed docker docker-buildx
  sudo systemctl enable --now docker
  docker buildx version    # must print a version, not an error
  ```

- **Fully update your system first** (`sudo pacman -Syu`, nothing held back in `IgnorePkg`).
  `build.sh` creates a Python venv, and on a partially upgraded system (e.g. a new `python`
  with an old `expat`) pip fails with a misleading
  `No module named 'pip._internal.operations.install.wheel'`. Run `python3 -c "import pyexpat"`
  to see the real error.
- You need to be in the `docker` group (`sudo usermod -aG docker $USER`). The change only
  applies to new login sessions, and logging out isn't always enough, so reboot if
  `id -nG` doesn't list `docker`. `sg docker ./build.sh` works in the meantime. Being in
  `docker` is effectively root access; `sudo ./build.sh` (and `sudo docker run ...` later) avoids it.

`WineResources/docs/status.md` documents which UE workloads are known to work under wine -
worth a read before assuming a workload will behave.

## 6. The mount layout

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
which the container's `nonroot` user cannot create the `4.27/` sibling - and then the engine
logs `Could not save memory cache …/Boot.ddc` as an **Error**. See §9 for why that single
error breaks everything.

## 7. Cook and pak by hand (no plugin required)

### 7a. Full project cook

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

This is the slow one (tens of minutes; it compiles every shader). Do it **once** - it fills
the shared DDC, after which per-mod cooks take seconds.

`-run=Cook` produces **loose cooked files only**. It never makes a pak:

```
<Project>/Saved/Cooked/WindowsNoEditor/<ProjectName>/{Content/,AssetRegistry.bin,Metadata/}
<Project>/Saved/Cooked/WindowsNoEditor/Engine/
```

### 7b. Cook only what you changed

Two flags turn on scoped cooking, and you need **both**:

```
-cooksinglepackagenorefs      # actually enables single-package mode in 4.27
-cooksinglepackage            # despite the name: KEEP hard references
-iterate                      # reuse previous cook results
-Map=/Game/Mods/MyMod/Foo -Map=/Game/Mods/MyMod/Bar …
```

Append those to the command in §7a. Meaning: *cook exactly these packages plus what they
hard-reference, nothing else*. Without them, a cook that requests no maps falls back to
cooking every map in the project.

Consequences to plan around:

- Single-package mode makes **`-CookDir` a no-op**, so folders must be expanded into explicit
  `-Map=` switches. Under `/Game`, a package name *is* its file path, so a plain `find` over
  `<Project>/Content/<sub>` for `*.uasset`/`*.umap` gives you the list - no editor needed.
- `-Map=` values are **split on `+`**, so a package whose name contains `+` cannot be
  requested at all.
- wine hands the command line to a Windows process, so the **32767-character** Windows limit
  applies. Split long selections across several cook runs; it makes no difference to the pak.

A 56-package mod cook against a warm DDC takes **~25 s** end to end, including paking.

### 7c. Pak it

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

Verify what you built - this is the step that catches wrong mount paths:

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
not a bug - the mount point is the thing to check. Do **not** grep the pak for
`../../../`: cooked assets embed such strings themselves, so you will read the wrong one and
conclude your mount paths are broken when they are fine.

Name a patch pak `something_P.pak` if it must **override** assets that ship with the game:
Unreal gives `*_P.pak` a higher mount priority.

### 7d. Paking natively (optional)

`UnrealPak` is a plain archiver - the *contents* are already Windows-cooked, so the Linux
`Engine/Binaries/Linux/UnrealPak` can build the pak too, with host paths in the response
file. It is faster (no container start). Cooking is the part that must stay in wine.

## 8. Building a C++ editor plugin for the Linux editor

```sh
~/UnrealEngine427Src/Engine/Build/BatchFiles/Linux/Build.sh \
    UE4Editor Linux Development \
    -Project="$HOME/git/MyProject/MyProject.uproject" -TargetType=Editor
```

Output: `MyProject/Plugins/<Plugin>/Binaries/Linux/libUE4Editor-<Plugin>.so` (~40 s for a
single small module). Works on Blueprint-only projects - adding a code plugin does not
require a game module.

**Gate editor-only tooling plugins to Linux** in the `.uplugin`:

```json
"Modules": [ { "Name": "MyTool", "Type": "Editor", "LoadingPhase": "Default",
               "WhitelistPlatforms": [ "Linux" ] } ]
```

Without that, the **Windows** cook loads the same `.uproject`, looks for
`UE4Editor-MyTool.dll`, does not find it, and refuses to start. (4.27 uses
`WhitelistPlatforms`; `PlatformAllowList` is UE5.)

## 9. Gotchas that will eat an afternoon

**A single logged error fails the cook, even when the cook succeeded.**
`LaunchEngineLoop` prints `Failure - N error(s)` and returns exit code **1** if anything was
logged at `Error` severity - the cook commandlet itself still reports `result 0`. So
`LogDerivedDataCache: Error: Could not save memory cache …/Boot.ddc` alone makes every
scripted cook look failed while producing perfect output. Fix it by mounting the boot DDC
directory (§6), not by ignoring exit codes.

**`-UTF8Output` makes wine emit UTF-16 logs.** Your `grep` silently matches nothing because
the text is NUL-interleaved. Leave the flag off; if you already have such a log:
`tr -d '\000\r' < log | less`.

**Docker creates missing mount parents as root** (§6). Any "the engine ignores my cache"
symptom is usually this.

**Project paths with spaces** (`~/git/VotV 4.27`) work everywhere here, but quote every
`-v "$PROJECT:…"` and remember the container path (`C:/p`) has no space, so
container-side command lines stay simple.

**Boot.ddc vs the real cache.** The `Common/DerivedDataCache` mount is the one that matters
for speed (shaders, textures). The `4.27/…/Boot.ddc` snapshot only saves a couple of seconds
of engine init - mount it purely so the write does not fail (see above).

**Harmless noise you can ignore** in wine cook logs: `aqProf.dll`/`VtuneApi.dll` load
failures, `MLSDK not found`, `Unable to create Visual Studio setup instance`, `PIX capture
plugin failed`, `RTSCom.dll` / StylusInput, missing `Game.locmeta`.

**Not harmless:** `LogMaterial: Warning: … Failed to compile Material Instance … Default
Material will be used in game` and `LogAudio: … Failed to build OGG derived data` - those
mean the asset in question will be broken in-game. (Not an issue for vanilla game content you're not packaging into your mods)

**Two editors, one project.** Do not run a second editor instance against the same project
directory; they fight over `Saved/Config` and the asset registry.

## 10. ModPackager: the one-click version

Once the manual flow works, the plugin removes the ceremony: right-click a folder or an asset
selection in the Content Browser → it cooks *just that* in the container, paks it, and copies
the result where you want it.

**Repo: <https://github.com/modestimpala/UE4-Modding-Plugins/tree/linux/ModPackager>** (`ModPackager`; use the Linux
branch - the original targets a Windows editor).

```sh
git clone -b linux git@github.com:modestimpala/UE4-Modding-Plugins.git
```

### What it actually does

1. Expands your selection via the **asset registry** (and optionally walks hard dependencies).
2. Saves dirty content packages, warns about anything still dirty and in scope.
3. Deletes the previously cooked output for that selection, so deleted assets cannot linger.
4. Runs the scoped cook in `epicgames/wine-patched:11.7` (§7b), splitting `-Map=` lists to
   stay under the Windows command-line limit.
5. Enumerates the cooked files natively, writes the response file with container source paths
   and `../../../<Project>/Content/…` mount paths, runs `UnrealPak -create -compress` (§7c).
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

## 11. Troubleshooting

| Symptom | Cause |
|---|---|
| Cook exits 1, output looks fine | Something logged an `Error`; check `Failure - N error(s)` near the end. Usually Boot.ddc (§6/§9). |
| `grep` finds nothing in a cook log | UTF-16 output from `-UTF8Output` (§9). |
| Cook cooks the whole project | Missing `-cooksinglepackagenorefs -cooksinglepackage` (§7b). |
| `-CookDir` ignored | Expected in single-package mode; expand to `-Map=` (§7b). |
| Cook aborts: plugin module not found | A project plugin has no Win64 binary, or an editor plugin is not gated to Linux (§8). |
| Game ignores the pak | Wrong mount point (check with `tools/pakinfo.py`), or it needs the `_P` suffix to win over base content (§7c). |
| Every cook recompiles shaders | DDC mount missing or root-owned (§6). |
| Editor refuses to load a marketplace plugin | No Linux build of it; port and build it (§4). |
| Windows engine rejects your assets | `CompatibleChangelist` mismatch (§3). |
| Plugin compiles but its module is "missing" | `.uplugin` module has no `Linux` in `WhitelistPlatforms` (§4d). |
| `'HAL/PlatformFileManager.h' file not found` | Header case; the engine file is `PlatformFilemanager.h` (§4d). |
| `Unable to find module 'X'` and nothing builds | Binary-only project plugin; move it out of `Plugins/` (§4e). |
| Disabled project plugin still gets compiled | UBT scans `Plugins/` regardless of `"Enabled": false` (§4e). |
| `ld.lld: cannot open .../lib/Unix/.../libvorbisenc.a` | UE5 third-party path in a plugin's `.Build.cs`; 4.27 uses `lib/Linux` (§4d). |
| `./build.sh` dies in pip: `No module named 'pip._internal.operations.install.wheel'` | Partial system upgrade (python newer than expat); `sudo pacman -Syu` (§5). |
| `unknown flag: --progress`, exit status 125 | `docker-buildx` not installed (§5). |
| `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock` | Current session isn't in the `docker` group yet; reboot or use `sg docker` (§5). |

