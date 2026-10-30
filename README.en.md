# AudioRateMatch

**Match a macOS output device's sample rate to a verified playback stream.**

[Download](https://github.com/QiHang-78/AudioRateMatch/releases/latest) · [简体中文](README.md) · [Architecture](docs/ARCHITECTURE.md) · [Validation](docs/VALIDATION.md) · [Publishing guide](docs/RELEASING.md)

AudioRateMatch is a native Swift menu-bar utility built with AppKit and Core Audio. It discovers audio processes, follows all active sources or a selected app, writes the output device's nominal sample rate, and reads back both the system setting and physical stream format.

**Discovering every audio process does not make every app's original source rate observable.** The current detector relies on recognizable Audio Queue format and playback events. Unknown formats, conflicting sources, unsupported rates and device ownership prevent automatic changes. It cannot recover audio that an application has already mixed or resampled.

## Features

- Process discovery without a player allowlist, with playback activity and device routing checks.
- Automatic agreement across active sources, or explicit app selection.
- Follow the system default output or choose a fixed device.
- Device capability and exclusive-access checks, followed by readback verification.
- A stability delay and per-device switching limit.
- A status window, diagnostics, local logs and command-line tools.

## Requirements

- macOS 14.2 deployment target; see [validation](docs/VALIDATION.md) for the environments actually tested.
- Apple Command Line Tools or Xcode with macOS SDK 14.2+ and Swift 5.9+; compiled in Swift 5 language mode.
- Native arm64, x86_64 and Universal builds are available. Intel hardware playback has not been tested.
- System frameworks and `/usr/bin/log`; no third-party package dependencies.
- The app interface and runtime diagnostics are currently in Simplified Chinese.

The deployment target is not a compatibility guarantee for every later macOS release. Detection depends on system log availability and format, which can change with macOS or player updates.

## Build and run

Install Apple's tools with `xcode-select --install` if needed. From the repository root:

```sh
bash test.sh
bash build.sh
open dist/AudioRateMatch.app
```

The default build targets the current architecture. You can copy the app to Applications. Build and test commands do not monitor or change audio devices; launching the GUI enables automatic switching by default.

```sh
bash build.sh --arch universal
bash package.sh --arch arm64
```

`package.sh` produces a release ZIP and a SHA-256 checksum under `dist/`. Both scripts accept `--arch native|arm64|x86_64|universal`. Build caches stay in `.build/`.

Builds use an ad-hoc local signature and are not notarized by Apple. macOS may block downloaded binaries. Building reviewed source locally is an option; the project does not require disabling system security features.

## Usage

The first launch, and the first launch after a version change, opens a status window. The app then lives in the `SR` menu-bar item.

| Menu / status | Meaning |
| --- | --- |
| 自动跟随所有应用 | Switch only when every active output on the selected device has a known, matching rate |
| 跟随应用 | Follow one app; hold the current rate when it is idle or its format is unknown |
| 输出设备 | Follow the default output or select a fixed device |
| 暂停自动切换 | Pause changes without restoring an earlier rate |
| 重新检测 | Reload evidence and reconnect the log monitor |
| `SR 96 ✓` | The followed stream, nominal setting and physical stream all report 96 kHz |

A device uses one sample rate at a time. When following one app, other sources may still be resampled. Matching sample rates does not guarantee bit-perfect audio: effects, gain and mixing can still modify the signal.

Changes may briefly interrupt playback. Run one sample-rate controller at a time. Pausing, quitting or becoming idle leaves the device at its last setting.

## Compatibility

Recognizable Audio Queue paths can be followed. Hardware checks covered `afplay`, an independent AVAudioPlayer example and a QQ Music local-playback case. Unknown Audio Unit / AVAudioEngine paths stay at the current setting. Browser, game, conferencing, DRM and internal mixing paths have no general compatibility guarantee.

Two known sources at the same rate can be followed together. Conflicting or unknown sources hold the current setting; selecting an app can resolve a conflict but cannot reveal an unknown source format. See [architecture and limitations](docs/ARCHITECTURE.md).

## CLI

Run these from the repository root:

```sh
dist/AudioRateMatch.app/Contents/MacOS/AudioRateMatch --help
dist/AudioRateMatch.app/Contents/MacOS/AudioRateMatch --version
dist/AudioRateMatch.app/Contents/MacOS/AudioRateMatch --status
dist/AudioRateMatch.app/Contents/MacOS/AudioRateMatch --watch --seconds 20
```

`--status` reports devices and audio clients as JSON, including a `selectionKey`. `--watch` observes for 1–300 seconds (default 20); it writes diagnostic logs but does not change device settings by default. Optional selectors are `--source SELECTION_KEY` and `--device NAME_OR_UID`.

`--watch --apply` enables real automatic device changes. `--set 96000` immediately sets and verifies 96 kHz on the default output; `--device` can select another output. Quit other rate controllers before using either write mode.

## Privacy

The app has no networking, reads no music files, records no audio, installs no drivers and injects no code into other processes. It reads Core Audio process metadata and filtered system audio logs.

Preferences use the `local.audioratematch` UserDefaults domain. Logs are written to `~/Library/Logs/AudioRateMatch/AudioRateMatch.log`; a log larger than roughly 2 MB is rotated on the next GUI launch. Diagnostics may include app/device names, source identifiers, rates, timestamps and errors. `--status` also exposes process IDs, executable paths and device UIDs. Remove personal paths and device identifiers before sharing diagnostics.

## Development

`Sources/` contains the app; `Tests/` contains synthetic playback-policy checks; `Resources/Info.plist` is the app metadata template. `VERSION` supplies the bundle version during builds. The test suite exercises process identity, queue transitions, routing, app selection, ambiguity and switching limits without touching audio hardware.

The GitHub Actions configuration runs tests and native builds on both Apple Silicon and Intel macOS runners. Hosted CI does not verify real DAC behavior. See [contribution guidelines](CONTRIBUTING.md), [validation](docs/VALIDATION.md) and [publishing](docs/RELEASING.md) for details; supporting documents are currently in Chinese.

## License

[MIT](LICENSE). Copyright © 2026 AudioRateMatch contributors.
