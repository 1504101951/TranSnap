# TranSnap

[中文](README.md) | [English](README.en.md)

**TranSnap** is a macOS 26+ desktop productivity suite combining instant global text translation with screen capture, annotation, recording, scrolling screenshots, live on-screen translation, and local MCP integration. Built with Flutter/Dart for UI and orchestration alongside a native Swift layer for non-activating panels, macOS Liquid Glass surfaces, and system capture frameworks.

> Currently targets **macOS 26+ (Darwin 25+)** on Apple silicon (arm64) Macs only.

![TranSnap Demo](docs/media/transnap-intro.gif)

---

## Key Features

### 1. Global Selection Translation & Writing Tools
- **Zero-Focus Disruption**: Trigger translation from any app via mouse selection or global hotkeys—results appear in a non-activating floating card near your selection.
- **Four Processing Modes**: Switch seamlessly between **Translate**, **Polish**, **Correct**, and **Explain**, or retry with an alternate translation service per card.
- **Adaptive Card Layouts**: Compact stacked layout for single blocks, side-by-side comparison (`720×420`), or dedicated dictionary view for single words, complete with offline TTS and **Vocabulary** bookmarking.
- **Inline Input Translation**: Translate editable text selections directly via a compact popover and replace source text in place.
- **Flexible Providers**: Works out of the box with Apple on-device system translation and zero-config web translation, plus configurable OpenAI-compatible endpoints, cloud translation APIs, and custom glossaries.

### 2. Screen Capture, Editing & Live Translation
- **Region Capture & Annotation**: Interactive cropping, shapes (rect, oval, arrow, line), pens/highlighter/mosaic, step badges, rich text, color picker, ruler, custom stickers, and gradient beautification. Pin captures to your desktop or run local **Vision OCR** and barcode/QR decoding.
- **Favorites & Full Toolbar**: Every capture opens a favorites toolbar of up to 6 tools on plain keys `1–6`. Double-click the drag handle or press `Tab` twice to show the full toolbar, where the remaining tools sit in modifier-key groups (`⌘` and `⌥` by default); each tool has exactly one shortcut. Arrange tools, nested trays, and modifier groups in **Settings**.
- **Screen Recording & Export**: Record regions, windows, or entire apps with countdown timers, trim clips in a unified 52pt result window, and export to **MP4**, **GIF**, **APNG**, or **WebM**.
- **Scrolling Capture & Image Tools**: Stitch long pages manually or with accessibility auto-scrolling, and stitch, split, or pixel-diff images in Screenshot History.
- **Live Region Translation**: Continuously OCR and render real-time translated overlays above an active region or window, skipping recognition while the picture stays the same.

### 3. Local MCP Server
- Bundles a verified stdio MCP helper at `/Applications/TranSnap.app/Contents/MacOS/transnap-mcp` with one-click setup for **Claude Code**, **Claude Desktop**, **Codex**, and **Grok** inside **Settings → MCP**.
- Exposes screen/window inspection, controlled capture, Vision document OCR, and opt-in UI automation tools.

Setup:
1. In **Settings → MCP**, turn on **允许 agent 截图** (allow agent screenshots); turn on **允许操控电脑** (allow computer control) only when the model should click or type for you.
2. Click **复制客户端配置** (copy client config), or click **安装** (install) for your client on the **接入平台** (platforms) card. CLI clients register the `transnap` server through their official CLI; Claude Desktop backs up and updates `mcpServers.transnap` in `claude_desktop_config.json`.
3. If the page shows **路径已变化** (path changed) after you move the app, click **重新安装** (reinstall) to refresh the config. The first time the model controls a protected app, macOS shows a one-time authorization card.

---

## Getting Started

1. Install TranSnap to `/Applications/TranSnap.app` from GitHub Releases or by running `./scripts/package-and-install-macos.sh`.
2. Launch `/Applications/TranSnap.app` and grant **Accessibility** and **Screen Recording** permissions in **Settings → General → Permissions & Startup**.

```bash
open /Applications/TranSnap.app
```

### Default Shortcuts
| Action | Shortcut |
| --- | --- |
| Translate selection | `⌘ + ⇧ + T` |
| Replace input / Translate selection | `⌘ + ⇧ + R` |
| Region capture & recording | `⌘ + ⇧ + S` |

---

## Development & Packaging

### Requirements
- macOS 26.0+ (SDK 26+) on an Apple silicon Mac
- Xcode 27+ & Command Line Tools
- Flutter SDK (Dart `^3.11.1`)
- A `TranSnap Local Signing` certificate in your login keychain (see [macOS Guide](docs/macos.md))

```bash
flutter pub get
flutter analyze && flutter test
./scripts/package-and-install-macos.sh
```

---

## Documentation

- [Architecture Overview (Chinese)](docs/architecture.md)
- [macOS Signing & Keychain Guide (Chinese)](docs/macos.md)
- [Domain Glossary (Chinese)](docs/glossary.md)
- [Docs Index (Chinese)](docs/index.md)

---

## License

TranSnap is licensed under the [Apache License 2.0](LICENSE). Third-party attributions and licenses are listed in [NOTICE](NOTICE).
