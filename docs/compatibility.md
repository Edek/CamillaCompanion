# Compatibility

The local CamillaCompanion `0.1.0-beta.2` candidate supports exactly these
CamillaDSP versions:

| CamillaDSP version | Support |
| --- | --- |
| [4.1.3](https://github.com/HEnquist/camilladsp/releases/tag/v4.1.3) | Supported |
| [5.0.0-beta.2](https://github.com/HEnquist/camilladsp/releases/tag/v5.0.0-beta.2) | Supported |

The app detects the connected engine version automatically. It rejects other
versions before sending control writes. About & Diagnostics has a CamillaDSP
version field populated from the verified readiness handshake. It displays
`Unavailable` until a version has been verified. Include this field when reporting
a compatibility issue; the app's own version appears separately.

CamillaCompanion does not bundle or install CamillaDSP, CamillaGUI, virtual audio
devices or drivers. Install and configure those separately. The DSP job, endpoint
and selected YAML must all refer to the same engine and devices.

CamillaDSP 5 has YAML configuration and WebSocket protocol changes. Use YAML and
presets compatible with the selected engine. Existing v4 YAML is not converted or
migrated automatically. Review and validate the configuration with the matching
CamillaDSP executable before activation.

For a v5 web interface, the official
[CamillaGUI backend v5.0.0-beta.2](https://github.com/HEnquist/camillagui-backend/releases/tag/v5.0.0-beta.2)
is available. Its executable currently reports `camillagui 5.0.0-beta.1`; that
version string does not change the release tag or the app's DSP version detection.
CamillaGUI remains optional and is installed separately.

This is a local candidate, not a published release. Its engine-version support
does not claim new live hardware acceptance. See [release notes](release-notes.md)
for platform and validation limits.
