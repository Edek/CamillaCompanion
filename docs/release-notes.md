# CamillaCompanion 0.1.0-beta.1

First release, public beta.

CamillaCompanion adds menu bar control to an existing CamillaDSP setup on macOS.

## Included

- Main volume/mute and named Aux faders with linked groups and individual Shift trims.
- Input/output meters with Realtime and Peak Hold modes.
- Preset selection and optional independent CamillaGUI control.
- Companion Mode that leaves macOS output selection alone.
- Optional Automatic Switching with Processed/Bypassed routing and fallback targets.
- Guided setup with **Find Automatically…** for existing DSP/GUI installations.
- Start at Login, immediate validated Settings saves,
  a pinnable panel, optional menu icon and Open Settings Folder.

Settings use `Application Support/CamillaCompanion`; the development executable
is `camillacompanion`. Older development settings/jobs are not imported
automatically. Stop the older controller before starting this build.

## Before using

Bring an installed CamillaDSP executable and a working YAML configuration.
The setup flow currently expects separate virtual capture and physical playback
outputs. CamillaGUI is optional. Dependencies and drivers are not installed by
CamillaCompanion. See the [user guide](user-guide.md).

Compatibility: macOS 13 or later on Apple Silicon (ARM64). Intel Macs have not
been tested, and this package does not contain an Intel executable. The app is
ad-hoc signed, without Developer ID or Apple notarization. Downloaded-app approval
remains unvalidated: the local Chrome download check was blocked by browser
policy before Gatekeeper. See [installation limits](user-guide.md#install-and-open).

## Known limits

- Hardware validation currently covers one Clarett-based setup; testing every
  macOS version and audio interface remains future work.
- Start at Login On/Off was confirmed across two sign-out/sign-in cycles on the
  tested Mac. The macOS disabled override was checked with `launchctl`; the
  System Settings UI path was not tested. Clean-user activation, downloaded-app
  approval and full removal remain unverified. App-only removal instructions
  retain the disabled login job and saved settings; optional settings cleanup is
  manual and unverified. There is no general end-user update workflow.
- Existing setups can be inspected, but profile editing and multi-interface
  activation presets are not provided.
- The app manages configured local DSP jobs; arbitrary external DSP attachment
  is not included. There is no in-app updater.
- Audio-engine underruns and buffer tuning remain CamillaDSP concerns.
- Translations, keyboard invocation and Dim are deferred.

The [repository](https://github.com/Edek/CamillaCompanion) is linked from About.
The limits above distinguish packaged functionality from unvalidated installation cases.

GPL-3.0-only. See [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY_NOTICES.md).
