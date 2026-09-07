<p align="center">
  <img src="docs/icon.png" alt="MicPin" width="128">
</p>

<h1 align="center">MicPin</h1>

<p align="center"><a href="README.fr.md">Version française</a></p>

A small macOS menu bar utility that pins your input microphone and its volume, so macOS stops changing them behind your back.

![The MicPin panel](docs/panel.png)

## The problem

macOS promotes any newly connected audio device to default input. Plug in headphones, pair a Bluetooth headset, let an app open a virtual device — and your built-in mic is no longer the one listening. Worse, each device keeps its own input level, so the volume shifts along with the source.

You usually notice mid-call, when someone asks why you sound distant.

MicPin fixes both halves: it pins the microphone **and** its volume, restoring them the moment macOS drifts away.

## Features

- **Pick your source** — every available microphone in one menu, with its connection type.
- **Set the input level** — a slider, without a trip to System Settings.
- **Pin a microphone** — MicPin watches for switches and immediately restores the device and its volume.
- **Lightweight** — a native SwiftUI app, no virtual audio driver, no external dependencies.
- **Out of the way** — lives in the menu bar, no Dock icon.
- **Keep the mic awake** — removes the wake-up latency of Bluetooth headsets, for the duration of a call.
- **Self-updating** — checks daily for a new version, and installs only what the author signed.

## Installation

Download the disk image from the [latest release](https://github.com/dimer47/MicPin/releases/latest), then drag MicPin into your Applications folder.

The app is signed and notarized by Apple, so there's no security warning on first launch.

The location matters: `SMAppService` refuses to register launch-at-login for an app living anywhere other than `/Applications`.

**Requirements**: macOS 26 or later.

### Building from source

```bash
git clone https://github.com/dimer47/MicPin.git
cd MicPin
xcodebuild -project MicPin.xcodeproj -scheme MicPin -configuration Release build
```

Xcode 26 is required. To run the tests, replace `build` with `test`.

## Usage

1. Launch MicPin — its icon appears in the menu bar.
2. Click it to see your microphones, then pick one.
3. Adjust the input level with the slider.
4. Click the pin to lock that microphone and its volume in place.

Once pinned, the menu bar icon changes and MicPin restores your choice every time macOS tries to switch. Click the pin again to release it.

### If the icon doesn't appear

A crowded menu bar leaves macOS no visible slot for new items. Free up space by Cmd-dragging an icon out of the bar, or use a menu bar manager.

### Keeping the mic awake

macOS closes the audio stream as soon as no application is using it, and the microphone goes to sleep. Waking it costs latency — clearly noticeable over Bluetooth, where the headset has to renegotiate its profile: the start of a sentence sometimes gets swallowed.

The toggle holds a stream open to avoid that. It is **off by default and manual**, because it has a cost:

- The orange microphone indicator stays lit while it's active — macOS shows it whenever an input stream exists, and no application can turn it off.
- The Bluetooth radio never idles, which drains both devices.

No audio is recorded or transmitted: the stream is read and discarded; its mere presence is what keeps the device awake.

## How it works

Three decisions are worth explaining, since they aren't obvious from reading the code.

**Persistence keys on UID, not device ID.** The `AudioObjectID` CoreAudio assigns to a device changes on every reconnection. The UID survives reboots, so that's what gets stored — which is why pinning holds when you unplug and replug the microphone.

**Restoration is rate-limited.** If a device stubbornly refused to stay selected, rewriting the default input in a loop would spin the app against CoreAudio indefinitely. MicPin caps restorations at five per ten-second window, then pauses enforcement for one window. The pin itself is kept: a burst of notifications — waking from sleep, say — must never erase the user's setting.

**The volume slider greys out on some microphones.** Many USB and Bluetooth devices don't expose `kAudioDevicePropertyVolumeScalar` as writable — their gain is hardware-controlled. MicPin detects this and says so, instead of leaving a dead control on screen.

### Architecture

| File | Role |
|---|---|
| `CoreAudioBridge.swift` | Low-level CoreAudio access: enumeration, property reads and writes, observers |
| `MicrophoneController.swift` | App state and pinning logic |
| `AudioDevice.swift` | Input device description |
| `Preferences.swift` | Persistence and launch-at-login |
| `MenuContentView.swift` | The menu bar panel |
| `MenuBarIcon.swift` | Menu bar icon rendering |
| `UpdateChecker.swift` | Update checking and installation |

The app is not sandboxed: reading and changing system audio devices requires it.

## Contributing

Run the tests with `xcodebuild -project MicPin.xcodeproj -scheme MicPin test`; they also run on every push via GitHub Actions.

The release process is documented in [docs/publication.md](docs/publication.md) (in French).

## License

GPL-3.0. See [LICENSE](LICENSE).
