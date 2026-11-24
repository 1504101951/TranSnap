# TranSnap

[简体中文](README.md) | English

<p align="center"><img src="docs/media/transnap-intro.gif" alt="TranSnap pixel-art intro animation: a summoner commands Grok, GPT, and Claude to showcase translation services, selection & input translation, pinning, screenshot annotation & OCR, scrolling capture, screen recording & GIF export, customizable toolbar, live screen translation & synchronized recording, and translation history" width="640"></p>

macOS 26+ Liquid Glass global selection & live screen translator with screenshot annotation, scrolling capture, pinning, and screen recording. Flutter/Dart powers the UI and translation logic; Swift provides native macOS capabilities and Liquid Glass materials.

## Features

- **Selection Translation**: Select text in any app and click the **Translate** button or press a shortcut to expand a side-by-side paragraph card with translation on the left and source text on the right.
- **Input Translation**: Type text in an input field and press a shortcut to replace it directly with its translation.
- **Screenshot & Annotation**: Freeze the screen to select a region and annotate with shapes, arrows, text, brush, and mosaic; copy, save, or pin on top.
- **OCR / Translate Text**: Recognize text in a screenshot for copying, or overlay translations directly over the original text in place.
- **Screen Recording & GIF**: Record a region, window, or full screen to MP4, and export the result as GIF.
- **Scrolling Capture**: Select a region and scroll down to stitch a long screenshot automatically while removing fixed headers and footers.
- **Live Translation**: Select a region, window, or full screen to overlay paragraph translations in real time over the source text, with optional synchronized recording.
- **Customizable Toolbar**: Reorder, hide, bind shortcuts, and combine tools into a two-level parent/child hierarchy in Settings.
- **Translation History**: Successful translations are saved automatically with keyword, source, and date filtering, single deletion, and clear all; retained for 30 days by default or forever.
- **Images & Glossary**: Open local or clipboard images for annotation, OCR, and translation; import, preview, and export glossaries in CSV/JSON.

See [Usage Guide](docs/usage.md) (in Chinese) for full details.

## Installation & Launch

```sh
./scripts/package-and-install-macos.sh
open /Applications/TranslateApp.app
```

Grant **Accessibility** (for selection translation) and **Screen Recording** (for screenshots, screen recording, and live translation) permissions on first launch. See [macOS Installation](docs/macos.md) (in Chinese) for code signing, permissions, and handling old copies.

| Default Shortcut | Action |
|---|---|
| ⌃⌥T | Translate current selection |
| ⌃⌥R | Input translation: replace source text in the input field with its translation |
| ⌃⌥S | Region screenshot |

## Translation Services

Add and test services in **Settings → Translation → Service List**; API keys are stored only in macOS Keychain.

| Service | Required Fields |
|---|---|
| Google Free API (unofficial, initial default) | None |
| Baidu Translate | App ID, Secret Key |
| Google Translate (Cloud Translation Basic v2) | API Key |
| OpenAI | API Key, Model ID |
| DeepSeek | API Key, Model ID |
| Anthropic | API Key, Model ID |
| Apple System Translation (on-device offline) | None; download language packs in System Settings |

## Development

```sh
flutter test
flutter analyze
flutter run -d macos
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=arm64'
```

Building requires Xcode with the macOS 26 SDK. See [Architecture](docs/architecture.md) for architecture details; requirements are tracked in GitHub Issues—see [Specs Index](docs/specs/README.md) (docs in Chinese).
