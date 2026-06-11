<p align="center">
  <img src="docs/icon.png" width="160" alt="neofsn app icon" />
</p>

# neofsn

> **Status: beta.** neofsn is under active development. Expect rough edges, changing behavior, and the occasional bug.
>
> **Requires macOS 15 (Sequoia) or later.**

A spatial filesystem navigator for macOS — a modern homage to SGI's **FSN** (the "File System Navigator" famously shown as the 3D UNIX interface in *Jurassic Park*). Folders become blue platforms, files become flat slabs you fly through, and a warm pulsing halo marks whatever you've selected. Built with SwiftUI for the shell and SceneKit for the 3D scene.

> *"It's a UNIX system. I know this."*

![neofsn](docs/screenshot.png)

## Features

- **3D folder visualization.** Each folder is a plate; its files are flat slabs and its subfolders are raised macOS-blue platforms carrying their own contents.
- **Fly camera.** WASD / arrow keys to move, `Q`/`E` to change altitude, drag to look, scroll to dolly. Hold `Shift` to move faster.
- **Configurable coloring** — toggle between **age heat-map** (FSN-style: red this week → through orange, yellow, green, teal, blue → purple for >1 year) and **file-type palette** (categorical: code, images, audio, video, docs, archives, config, …). Switch live from the top bar; the scene recolors in place without a rescan.
- **File-type icons** stamped on each slab using a shared `FileKind` taxonomy that drives both the icon and the type-mode color.
- **Layered descent.** Stepping into a subfolder drops a new plate beside-and-below the current one and pans the camera to it — the parent stays on screen, so you keep your bearings instead of losing context to a full redraw.
- **Hierarchical sidebar** mirroring the tree, with two-way sync: pick something in 3D and the sidebar scrolls to it; click in the sidebar and the camera flies to it.
- **Interactive breadcrumb bar** — jump to any ancestor folder with a click.
- **Selection halo.** The selected item gets a soft warm-gold ring of light around its base, gently pulsing — the app's signature visual.
- **Remembers your last folder.** The opened folder is persisted as a security-scoped bookmark and reopened automatically on the next launch.
- **Expanded metadata HUD** with kind chip, name, full path, size (or file/subdir count for folders), modified/created dates, permissions (`rwx`), and age — plus an inline action strip: Quick Look, Open, Copy Path (`⇧⌘C`), Reveal in Finder, and Descend (for folders).
- **Finder integration & Quick Look** — open in the default app (`⇧⌘O`), reveal in Finder (`⌘R`), copy path (`⇧⌘C`), or press `Space` to Quick Look the selection.
- **Reset view** (`⌘0`, the scope button, or click empty space) re-frames the current folder.

## Requirements

- macOS 15.0 (Sequoia) or later — this is the app's minimum deployment target
- Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build (the `.xcodeproj` is generated from `project.yml`)

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install it once, then generate the project:

```sh
brew install xcodegen
xcodegen generate
```

Then open `neofsn.xcodeproj` in Xcode and build, or from the command line:

```sh
xcodebuild -project neofsn.xcodeproj -scheme neofsn -configuration Debug build
```

`project.yml` is the source of truth; `neofsn.xcodeproj` is generated and not tracked in git. Re-run `xcodegen generate` after pulling changes that touch `project.yml`.

## Testing

Unit tests for the model layer live in `neofsnTests/` (Swift Testing). Run them with:

```sh
xcodebuild -project neofsn.xcodeproj -scheme neofsn -destination 'platform=macOS' test
```

## Running

The easiest way is to open `neofsn.xcodeproj` in Xcode and press **Run** (`⌘R`).

To launch a command-line build directly, open the product Xcode just built:

```sh
open "$(xcodebuild -project neofsn.xcodeproj -scheme neofsn -configuration Debug \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{d=$3} END{print d}')/neofsn.app"
```

On first launch the 3D view is empty. Click **Open…** (or press `⌘O`) and choose a folder to visualize. The app is sandboxed and uses security-scoped bookmarks, so it only ever reads the folders you explicitly pick — and it remembers the last one, reopening it automatically on the next launch. Once a folder is open, fly around with the keyboard and mouse (see below), click items to inspect them, and step into subfolders to descend.

## Keyboard & mouse

| Action | Binding |
| --- | --- |
| Move / strafe | `W` `A` `S` `D` or arrow keys |
| Altitude | `E` (up) / `Q` (down) |
| Speed boost | hold `Shift` |
| Look around | left- or right-drag |
| Dolly | scroll |
| Select / enter | single-click |
| Open file / re-root folder | double-click |
| Quick Look | `Space` |
| Open in default app | `⇧⌘O` |
| Reveal in Finder | `⌘R` |
| Copy path | `⇧⌘C` |
| Open folder… | `⌘O` |
| Back | `⌘[` |
| Reset view | `⌘0` |

## Project layout

```
neofsn/
├── neofsnApp.swift              # App entry point, window configuration
├── Model/
│   ├── BrowserViewModel.swift   # Navigation state, scanning, selection, focus requests
│   ├── FileKind.swift           # File-type taxonomy (icon symbols + type-mode palette)
│   ├── FileSystemNode.swift     # Tree node model
│   ├── FileSystemScanner.swift  # Async (cancellable) directory scanner
│   └── LastFolderBookmark.swift # Security-scoped bookmark for the last opened folder
├── Scene/
│   ├── SceneBuilder.swift       # Builds level plates, slabs, icons, labels
│   ├── SceneHostView.swift      # SCNView host, level stack, picking, framing, Quick Look
│   └── FlyCameraController.swift# WASD/look/scroll fly camera
└── UI/
    ├── ContentView.swift        # NavigationSplitView shell, top bar, breadcrumbs, empty state
    ├── SidebarView.swift        # Hierarchical tree sidebar
    ├── MetadataHUD.swift        # Selected-item metadata panel
    └── Theme.swift              # Color, type, and panel design tokens

neofsnTests/                     # Swift Testing unit tests for the model & scene math

scripts/
├── generate-icon.swift          # Renders the app icon set
└── gen-compile-commands.sh      # Generates compile_commands.json for sourcekit-lsp
```

## Tooling notes

The project is generated from `project.yml` via XcodeGen (the `.xcodeproj` is not committed). For editors that use `sourcekit-lsp`, run `scripts/gen-compile-commands.sh` to generate a `compile_commands.json` so cross-file symbols resolve. The build itself always goes through `xcodebuild` / Xcode.

## Acknowledgements

Inspired by Silicon Graphics' *fsn* (1992) and its cameo in *Jurassic Park*. This is an independent reimplementation and is not affiliated with SGI.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
