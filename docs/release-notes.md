# CamillaCompanion 0.1.0-beta.2 local candidate

This is a local candidate for review. It has not been published or deployed as a
release. The README download link still points to the previous published beta.

## Candidate changes

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
- Existing setups can be inspected, but profile editing and multi-interface
  activation presets are not included. Interface profiles remain a future plan.
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
