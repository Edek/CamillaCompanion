# CamillaCompanion 0.1.0-beta.2 local candidate

This candidate is installed locally and has not been published. The README
download link still points to the previously published beta 1.

## Candidate changes

- Use one automatic profile per connection trigger, with confirmation and an
  atomic save when transferring that choice. Different triggers remain independent.
- Keep a healthy running interface when another connects. In Automatic Switching
  with DSP Auto, allow a unique eligible alternative to take over when selected
  hardware disappears; multiple alternatives still require selection.
- Clarify Startup Preset labels, add duplication and preset-folder access, and
  group the profile editor consistently with Settings.
- Keep larger preset libraries in an eight-row scrolling selector.
- Replace the Interfaces form with a saved-profile table, + editor, and shared
  device browser showing input/output channels and offline references. Prefill the
  DSP executable from saved profiles and suggest mappings from the chosen YAML.
- Separate DSP input from the managed system-audio feed. Companion-only profiles
  support input-only sources and same-device duplex mapping. Profile saves use
  configuration version 2; existing version 1 files remain readable.
  Saving leaves audio unchanged; Use Profile loads saved changes.

- Detect and support exactly CamillaDSP **4.1.3** and **5.0.0-beta.2**. Other
  engine versions are rejected before control writes.
- Show the app version and verified CamillaDSP version in About & Diagnostics.
  The DSP version field says `Unavailable` until readiness is confirmed.
- Double-click a slider knob to reset to 0 dB within DSP limits. Linked Aux
  channels preserve their offsets; Shift resets only the selected Aux.
  Reset changes volume only, leaves mute and other settings unchanged, and follows
  CamillaDSP's volume limits.

See the [compatibility guide](compatibility.md) for engine and GUI requirements.
CamillaCompanion does not include CamillaDSP, CamillaGUI or audio drivers. CamillaDSP
5 requires a compatible YAML and is not an automatic migration of v4 configurations.
The official CamillaGUI backend v5 beta 2 is available; its executable reports
`camillagui 5.0.0-beta.1`.

## Known limits

- macOS 13 or later on Apple Silicon (ARM64). Intel is untested and no Intel
  executable is included. The app is ad-hoc signed without Developer ID or
  notarization.
- Existing beta hardware validation remains limited to the previously tested
  one-interface setup. This candidate does not claim new live hardware acceptance.
- Interface profiles and their startup presets are implemented and installed
  locally. Physical multi-interface handoff has not been accepted yet. A basic
  preset-creation wizard, per-profile preset folders and GUI editing for additional
  profiles remain future work.
- A keyboard shortcut to open the panel remains a possible future idea, with no
  commitment or release date.
- Arbitrary external DSP attachment is not included. The app manages a configured
  local DSP job.
- Clean-user activation, downloaded-app approval, the System Settings login UI path
  and full removal remain unverified. There is no public installer or updater.
- Audio-engine underruns and buffer tuning remain CamillaDSP concerns.

The [repository](https://github.com/Edek/CamillaCompanion) is linked from About.
GPL-3.0-only. See [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY_NOTICES.md).
