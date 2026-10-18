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
validates the chosen YAML with CamillaDSP before publication.

## Stage a local app

The packager uses Python 3.10+ and the macOS command-line developer tools.
The local packager targets Apple Silicon (`arm64`) and macOS 13 or later. It wraps
an already verified release executable without rebuilding it or installing it.
Retain the exact executable whose final checks passed and its recorded SHA-256.
Substitute that hash for `YOUR_RECORDED_SHA256` below:

```sh
python3 tools/packaging/build_app.py \
  --binary .build/release/camillacompanion \
  --expected-sha YOUR_RECORDED_SHA256 \
  --version 0.1.0-beta.1 \
  --minimum-os 13.0 \
  --output .build/packaging/CamillaCompanion.app
```

The packager verifies the input hash and architecture, includes the app icon,
license and dependency notices, and signs the bundle with an ad-hoc signature.
Its adjacent `CamillaCompanion.app.manifest.json` records the input hash and the
executable hash after bundle signing. Preserve both the bundle and its manifest.
Existing output paths are refused rather than overwritten.

Ad-hoc signing requires no paid developer membership. The package has no
Developer ID signature or notarization, and there is no public download.
Fresh-default Finder activation passed on the tested account. Separate clean-user,
login, Gatekeeper and removal acceptance remain pending.

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

## Controller and deployment

`camillacompanion --help` lists the CLI. `--config PATH` selects controller JSON;
`--state PATH` selects its runtime record and preference sidecars. A shared state
path enforces one controller. Deliberately separate state paths are separate
sessions, not a way to reopen the same panel.

The preserved original watcher and the controller must not run together. Setup
also checks for conflicting DSP ownership. Do not use a second DSP instance to
work around a refused activation.

Maintainer-only local installation follows [deployment.md](deployment.md).
`tools/deploy.py` replaces an existing supported local beta installation; it is
not a first-install or public installer. The separate local app migrator is
`tools/packaging/migrate_install.py`; its default invocation is read-only, and
`--apply` requires explicit installation authorization after preflight review.
It supports one settled single-profile session using current CamillaCompanion
names, or an explicit
`--update-installed-app` replacement of the existing target bundle, with DSP Auto,
GUI Auto and managed routing. An explicit `--preserve-gui-off` also supports a
settled GUI Off session, restoring that override after startup. The GUI may
start briefly before Off is restored. It retains configuration/state paths and
the same current startup authority. Other policies or older development names
require a reviewed manual transition.

Reuse the verified artifact, preserve settings/policy and keep installation
readiness separate from live acceptance. See the [release notes](release-notes.md#known-limits)
for remaining acceptance checks and [source archive contents](source-archive.md)
for the distributed source and dependency files.
