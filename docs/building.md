# Build and verify

CamillaCompanion is a Swift package targeting macOS 13 or later, using Swift tools
5.9 or later. The package and application source folder are named
`CamillaCompanion`; the CLI executable is `camillacompanion`. Yams is pinned in the dependencies.

## Build

From the repository root:

```sh
swift build -c release --product camillacompanion
.build/release/camillacompanion version
```

Building does not install the controller, register login startup or change audio.
The first build needs access to the package dependency.

Launch [setup](user-guide.md) with `.build/release/camillacompanion setup`, or use
`.build/release/camillacompanion launch` for a saved configuration. These can activate
DSP and, in Automatic Switching, change output routing. Keep the executable at
its configured path when using Start at Login.

For read-only inspection:

```sh
.build/release/camillacompanion devices
.build/release/camillacompanion validate --config Examples/bedroom.json
```

`devices` lists CoreAudio names and UIDs. `validate` checks the controller JSON
format, not hardware availability or live DSP readiness. Example UID placeholders
must be replaced before using the example for a real setup. Guided setup also
validates the chosen YAML with CamillaDSP before saving.

## CamillaDSP compatibility

This local `0.1.0-beta.2` candidate detects CamillaDSP **4.1.3** and
**5.0.0-beta.2** on each connection. Those are the only supported engine versions;
other versions are rejected before control writes. CamillaCompanion does not bundle
or install CamillaDSP or CamillaGUI.

Use YAML and presets valid for the selected engine. CamillaDSP 5 changes its YAML
configuration and WebSocket protocol; existing v4 YAML is not converted
automatically. Presets must match their engine, and the app does not rewrite them.
Engine selection is automatic from the version reported by CamillaDSP.

For v5's web interface, use the independently released
[CamillaGUI backend v5 beta 2](https://github.com/HEnquist/camillagui-backend/releases/tag/v5.0.0-beta.2).
Its executable reports `camillagui 5.0.0-beta.1`. The existing GUI configuration
format and `-c` argument remain supported. Keep the web binding local and the DSP
endpoint/configuration paths matched to the selected engine. See the
[compatibility guide](compatibility.md).

## Stage a local app

The packager uses Python 3.10+ and the macOS command-line developer tools.
The local packager targets Apple Silicon (`arm64`) and macOS 13 or later. It wraps
the supplied executable without rebuilding it or installing it, and checks its
recorded SHA-256. Substitute the intended executable's hash for
`YOUR_RECORDED_SHA256` below:

```sh
python3 tools/packaging/build_app.py \
  --binary .build/release/camillacompanion \
  --expected-sha YOUR_RECORDED_SHA256 \
  --version 0.1.0-beta.2 \
  --minimum-os 13.0 \
  --output .build/packaging/CamillaCompanion.app
```

The packager verifies the input hash and architecture, includes the app icon,
license and dependency notices, and signs the bundle with an ad-hoc signature.
Its adjacent `CamillaCompanion.app.manifest.json` records the input hash and the
executable hash after bundle signing. Preserve both the bundle and its manifest.
Existing output paths are refused rather than overwritten.

Ad-hoc signing requires no paid developer membership. This local candidate has no
Developer ID signature or notarization and has not been published. Existing
beta limits include unverified clean-user setup, downloaded-app approval and full
removal. Previous login acceptance is retained; packaging does not repeat it.

For a fresh installation, copy the staged app into Applications and open it for
setup. Stop an older development controller before opening this build. It does not
adopt older settings or startup jobs; see [older builds](user-guide.md#older-development-builds).

## Checks

```sh
swift run camillacompanion-checks
```

The check runner uses fake audio/services, temporary files and finite fixtures.
It does not operate installed DSP or login services. Native fixtures need an
unlocked macOS desktop for focus checks. XCTest coverage is also provided:

```sh
swift test
```

Setup discovery also has an isolated native confirmation/cancellation fixture:

```sh
AUTOSWITCH_NATIVE_SETUP_DISCOVERY_ONLY=1 .build/release/camillacompanion-checks
```

It uses injected candidates and temporary paths; no installed DSP/GUI or settings
are changed.

XCTest requires a full Xcode toolchain on the development host. The currently
used Command Line Tools do not supply it. Automated checks do not establish
hardware, login or audio-quality acceptance.

## Controller ownership

`camillacompanion --help` lists the CLI. `--config PATH` selects controller JSON;
`--state PATH` selects its runtime record and preference sidecars. A shared state
path enforces one controller. Deliberately separate state paths are separate
sessions, not a way to reopen the same panel.

The preserved original watcher and the controller must not run together. Setup
also checks for conflicting DSP ownership. Do not use a second DSP instance to
work around a refused activation.

Reuse the same controller state path to reopen a running session. The original
watcher and the controller must not run together, and Setup refuses conflicting
DSP ownership. This local candidate is not a public installer. See the
[release notes](release-notes.md#known-limits) for platform and acceptance limits
and [source archive contents](source-archive.md) for the distributed source and
dependency files.
