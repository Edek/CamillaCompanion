<p align="center">
  <img src="docs/images/app-icon.png" alt="CamillaCompanion icon" width="128" height="128">
</p>

<h1 align="center">CamillaCompanion</h1>

<p align="center">A macOS menu bar companion for CamillaDSP.</p>

<p align="center">
  <img src="https://img.shields.io/badge/local_candidate-0.1.0--beta.2_unpublished-1687ed" alt="Local candidate 0.1.0-beta.2, unpublished">
  <img src="https://img.shields.io/badge/macOS-13%2B-555555" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/architecture-Apple_Silicon-22b8ad" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--only-80b918" alt="GPL-3.0-only license"></a>
</p>

<p align="center">
  <a href="https://github.com/Edek/CamillaCompanion/releases/tag/v0.1.0-beta.1"><strong>Latest published beta</strong></a>
  &nbsp;·&nbsp; <a href="docs/first-time-setup.md">Setup guide</a>
  &nbsp;·&nbsp; <a href="docs/release-notes.md">Candidate notes</a>
</p>

Control volume, linked outputs, presets and live meters from the menu bar.
Use Companion Mode for DSP controls, or enable Automatic Switching to manage
macOS audio routing when your interface connects and disconnects.

## Features

- Main volume and mute, plus named Aux faders with linked groups.
- Shift-drag or Shift-mute to adjust one Aux without unlinking its group.
- Input/output meters with synchronized Realtime and Peak Hold modes.
- Preset selection with an eight-row scrolling list for larger libraries.
- Interface profiles with validated startup presets, device mapping and one
  automatic profile per connection trigger.
- Optional CamillaGUI controls.
- DSP-only Companion Mode, or Automatic Switching with Processed/Bypassed routing.
- Configurable fallback output, Start at Login and a pinnable panel.
- Optional menu bar icon and direct access to the settings folder.
- Guided setup with a one-time search for existing DSP and GUI installations.
- About & Diagnostics show the app version and verified CamillaDSP version; the
  DSP field says Unavailable until readiness is confirmed.
- Double-click a slider knob to reset to 0 dB; DSP limits still apply.

Settings validate and save changes without an Apply button. Meter reads stop
when the panel closes, metering is collapsed or DSP becomes unavailable. There
is no recurring device scan or idle health polling.

<p align="center">
  <img src="docs/images/main-panel.png" alt="CamillaCompanion main panel" width="380">
</p>

## Requirements and setup

Bring an existing CamillaDSP executable and working YAML configuration.
CamillaCompanion does not install CamillaDSP, CamillaGUI, virtual audio devices
or interface drivers. CamillaGUI is optional.

The current setup flow expects separate virtual capture and physical playback
outputs matching the YAML. It manages a configured local DSP job; it does not
attach to any independently running CamillaDSP instance. Supported DSP versions
are exactly **4.1.3** and **5.0.0-beta.2**, detected automatically. See the
[compatibility guide](docs/compatibility.md).

[Build and stage the app](docs/building.md). For a new installation, place
`CamillaCompanion.app` in Applications and open it to start setup. See
[installation limits](docs/user-guide.md#install-and-open) for this non-notarized
beta. Stop any older controller before opening this build; it uses new settings
and startup names.

Use Setup’s **Find Automatically…** action or choose CamillaDSP and its configuration
manually, then select matching devices and an operating mode.
**Save Only** leaves audio unchanged. **Save and Activate** starts the configured
session. Opening the app again reveals its running panel. The development CLI
also provides `camillacompanion setup` and `camillacompanion launch`.

Follow the [first-time setup tutorial](docs/first-time-setup.md) for a step-by-step
walkthrough. The [user guide](docs/user-guide.md) covers startup, storage, controls,
updates and removal.

**Local candidate:** `0.1.0-beta.2`, not published. macOS 13+ on Apple Silicon
(ARM64); Intel is untested and not included. The app is ad-hoc signed without
Apple notarization. Hardware validation remains limited; see the
[known limits](docs/release-notes.md#known-limits).

## Operating modes

| Mode | Behavior |
| --- | --- |
| Companion Mode | Controls the configured DSP without changing macOS outputs. DSP On waits for required hardware and resumes when it reconnects; Off stays Off. |
| Automatic Switching | Manages DSP and routes system audio through its virtual output when ready. Processed/Bypassed and fallback controls are available. |

**MacBook Pro: at your desk and on the go.** Enable Automatic Switching with
DSP and Fallback on **Auto**. At your desk, connect the configured USB interface:
DSP starts and audio routes through BlackHole once ready. Unplug the interface
when leaving with your MacBook: the managed route returns to the previous
available output, or an available fallback such as **MacBook Pro Speakers**.
Reconnect at your desk to resume processing.

**More than one interface.** Add profiles in **Settings > Interfaces** and choose
their devices and startup presets. Each connection trigger can have one automatic
profile. Enabling another for the same trigger asks before replacing that choice;
other profiles remain available manually. Save Profile persists the change, and
Use Profile loads saved changes.

Connecting a second interface keeps the current one playing. In Automatic
Switching with DSP Auto, losing the current interface hands off to one eligible
automatic alternative. Several eligible alternatives require a choice. Companion
Mode follows only its selected profile. See the [profile guide](docs/user-guide.md#interface-profiles).

Prefer a specific output? Set Fallback to **Force** and select it under
**Fallback/Bypass Output**. Force enforces that device on both disconnection and
reconnection.

Switch modes in **Settings > General > Automatic Switching**. Entering Companion
Mode keeps the current macOS output. Companion DSP Off and Quit also leave it
untouched. Bypassed routing keeps a healthy DSP running; it is not a mute button.

## Settings and support

Settings live in `~/Library/Application Support/CamillaCompanion/`.
**Open Settings Folder** reveals the active location. Quit before editing JSON
files directly. Older settings folders are not imported automatically.

Support development through [Ko-fi](https://ko-fi.com/camillacompanion).
Contributions are optional; all features remain available to everyone.

For a problem report, include the app version, operating mode, relevant status
and on-demand diagnostics. Review diagnostics for personal paths before sharing.
Project source and release information: [GitHub](https://github.com/Edek/CamillaCompanion).
CamillaDSP audio-engine buffer and underrun problems remain outside this app's
scope.

## Future roadmap

- Improve installation, updates and removal, and broaden macOS and hardware testing.
- Add a basic-preset creation wizard and separate preset libraries per interface.
- Validate multi-interface handoff on additional hardware.
- Consider a keyboard shortcut to show the panel; no shortcut is committed.
- Consider translations if there is demand.

These are future plans without committed dates or guarantees. The current source
includes an Interfaces profile table and device browser; multi-interface hardware
acceptance remains pending.

## Development and release status

[Build and checks](docs/building.md) · [Release notes](docs/release-notes.md) ·
[Source archive contents](docs/source-archive.md) · [Contributing](CONTRIBUTING.md)

## License

Copyright (C) 2026 CamillaCompanion contributors.

GNU General Public License, version 3 only (`GPL-3.0-only`). See
[LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
