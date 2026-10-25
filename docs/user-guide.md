# Setup and user guide

This guide covers the local `.app` and executable candidate `0.1.0-beta.2`, which is
not published. It targets macOS 13 or later on Apple Silicon
(`arm64`). Intel Macs have not been tested, and no Intel executable is included.
See the [release notes](release-notes.md#known-limits) for remaining acceptance checks.

## Install and open

For a new installation, [build and stage the app](building.md#stage-a-local-app).
If using an archive, extract it first. Place `CamillaCompanion.app` in
`/Applications`, then open it in Finder. First launch without an existing setup
opens Setup. Stop any older controller before opening this build. Older settings
folders and startup jobs are not adopted automatically.

The beta is ad-hoc signed, without Developer ID or Apple notarization. macOS may
block a downloaded copy. The downloaded-app approval flow has not yet been
validated; report the exact refusal message rather than disabling Gatekeeper or
removing quarantine. Local copy/ZIP checks do not establish downloaded-app approval.

## First setup

For a step-by-step walkthrough, see [First-time setup](first-time-setup.md).

Start with an installed CamillaDSP executable and a working YAML configuration.
Supported engine versions are exactly **4.1.3** and **5.0.0-beta.2**, detected
automatically on connection. The app does not bundle or install CamillaDSP,
CamillaGUI or drivers. CamillaDSP 5 requires compatible YAML, and existing v4
YAML is not migrated automatically. The official CamillaGUI backend v5 beta 2 is
available, although its executable reports `camillagui 5.0.0-beta.1`. See the
[compatibility guide](compatibility.md).
The current setup flow uses a virtual capture output and a distinct physical
playback output whose names/selectors match the YAML. Install those devices and
any required drivers separately. CamillaGUI is optional.

The development CLI can also open Setup:

```sh
.build/release/camillacompanion setup
```

1. Use **Find Automatically…** for a one-time search of common installation folders
   and startup definitions. Select candidates and **Use Selection**, or choose the
   CamillaDSP executable and YAML manually. Discovery starts and saves nothing;
   configurations or GUI addresses it cannot identify remain manual choices.
2. Select the matching capture and playback devices. Refresh Devices if needed.
   Advanced accepts known UIDs for disconnected devices; save without activation
   until the required hardware is available.
3. Optionally choose a presets folder and configure CamillaGUI, or confirm that
   CamillaGUI is not installed.
4. Choose Companion or Automatic Switching, then review the configuration.
5. Choose **Save Only** to keep audio unchanged, or **Save and Activate** to start
   the session after readiness and ownership checks.

Setup creates an on-demand DSP job or imports a compatible existing one.
Import requires a direct CamillaDSP executable, the selected configuration and
loopback WebSocket port, with RunAtLoad and KeepAlive off. Imported job files are
preserved. An independently running DSP may conflict with activation; this beta
does not provide arbitrary external-server attachment.

An existing controller configuration opens for inspection without replacement.
Setup handles first-run configuration. Use **Settings > Interfaces** to edit profiles. Invalid existing
JSON is preserved and must be corrected separately. Use **Settings > General >
Setup…** to inspect the initial setup, and Interfaces for additional profiles.

## Interface profiles

**Settings > Interfaces** lists saved profiles with their connection trigger,
DSP input/output and status. Use **+** to add a profile or **Edit…** to change one.
The editor groups Profile, Audio Devices, Startup Preset and Behavior using the
same typography as Settings. **Startup Preset** is the CamillaDSP YAML file used
when the interface starts. **Choose Preset…** reads an existing file and suggests
matching devices without rewriting it. **Show in Finder** reveals the file.
**Open Presets Folder** opens the folder configured in General. Choose Preset
starts there too. If that folder is unavailable, both use the selected preset's
folder when it exists.

**Duplicate Preset…** saves an unchanged copy beside the original and selects it
in the unsaved form. Keeping it in the same folder preserves relative coefficient
references. It never replaces another file or starts processing. The copied file
remains if you cancel the profile editor. Basic-preset creation is planned later.

**Advanced** contains the DSP executable, WebSocket port and system-alert option.
The executable is prefilled from a valid saved profile. **Find…** searches known
installation locations if needed. Collapsed sections leave no reserved space;
the sheet scrolls if its content exceeds the available screen height.

The panel's preset selector changes the running configuration. It does not rewrite
this profile's startup job. New profiles start from their explicitly selected
preset; imported jobs using only a CamillaDSP state file follow that file's saved
preset reference.

Each device field opens a table of devices and their input/output channel counts.
Incompatible devices remain visible with a reason. Offline references retain their
UIDs. **Refresh** reads the current list once. The connection trigger defaults to
DSP output but can be selected independently.

Alternative profiles may share DSP input/output devices. The editor explains
this overlap. Each connection trigger can have only one automatic profile.
Enabling Auto-activate for another profile on that trigger opens a confirmation
naming the affected profiles. **Make Automatic** records the change in the draft;
Cancel keeps the previous choice. **Save Profile** enables it here and disables it
on the other profiles for that trigger in one save. Other triggers, presets and
device assignments are kept. Canceling the editor discards the draft transfer.
Existing duplicate automatic choices are not silently repaired on launch; saving
an automatic profile asks which one should replace the others.

In Automatic Switching with DSP Auto, an eligible selected or active profile keeps
playing when another interface connects. If its required hardware disappears, the
app can hand off to the sole eligible automatic alternative, even after an explicit
selection of the old profile. The replacement becomes the current selection, so
reconnecting the old interface does not steal playback back. If several alternatives
are eligible, select one. Manual alternatives are not started automatically. Off,
forced DSP On and Companion Mode retain their existing policy; Companion follows
only its selected profile. There is no numeric or connection-order priority.

Profile transitions stop the previously managed DSP before starting the next.
Existing identity, device-mapping and endpoint ownership checks still apply.

**Support automatic routing** assigns the DSP input as the system-audio feed.
Use a loopback feed such as BlackHole, with both input and output channels,
separate from DSP output and trigger. Input/output capability alone does not establish
a loopback audio path. Leave it off for input-only or same-interface duplex setups in Companion
Mode. A Companion-only profile cannot be used with Automatic Switching enabled.

**Save Profile** validates and saves the complete profile without changing audio.
**Use Profile** loads saved changes and selects that profile. It requires its
devices to be connected and can interrupt playback; DSP Off stays Off. Browsing
profiles does not activate them. Remove deletes the saved reference, leaving YAML,
preferences and old job files intact; the current or final profile cannot be removed.
Saved edits show **Pending use** until loaded with Use Profile or the next app
launch. An active profile remains marked Active while its saved changes are pending.

The first profile save upgrades `config.json` to version 2. Existing version 1 files
remain readable and are not changed by browsing. Older builds reject version 2;
restore a matching configuration backup before downgrading.

In Automatic Switching, choose DSP **Auto** to clear an explicit profile choice
and follow eligible connected interfaces. If more than one is eligible and none
is active, select one. Companion Mode keeps system routing under your control.
Main/Aux preferences remain associated with the same profile ID. The presets
folder is still global; each profile uses its configured startup preset when its
DSP job starts. Separate preset folders per profile remain future work.

New profiles currently configure DSP only. Existing GUI configuration is preserved
when editing a profile; GUI setup for additional profiles remains manual. A changed
DSP port must also match the GUI backend's configuration when GUI is used.

## Open and close

Use the menu bar icon to open the panel; Pin keeps it open while using other apps.
Open `CamillaCompanion.app` again to reveal the same panel. For the executable
beta, this also opens a saved setup or reveals its current panel:

```sh
.build/release/camillacompanion launch
```

**Show Menu Bar Icon** can be disabled in General. An explicit reopen uses the
same panel and temporarily shows its menu bar anchor until the panel closes.
A second launch for the same state path requests the running controller's panel.
Implicit app launch adopts configuration/state paths and mode/profile arguments
from one compatible known app login job. Malformed, conflicting or mismatched
known jobs produce an error rather than starting a default session. Explicit
CLI `--config` and `--state` options remain available for advanced use.
Discovery trusts the app bundle being opened. Development copies may need
explicit paths when startup points into a different installed bundle.

Closing the panel does not quit DSP. Choose Quit from More to stop the controller
and its managed DSP where possible. In Automatic Switching, owned output routes
are restored during clean shutdown. Companion Mode leaves macOS outputs alone.

## Audio controls

Turn **Automatic Switching** off in General for Companion Mode. Entry keeps the
current macOS output. DSP **On** retains intent while required hardware is absent
and resumes on reconnect; **Off** stays stopped. Offline controls disable without
an endless retry loop. CamillaGUI remains independently controllable.

With Automatic Switching on, DSP has Auto/On/Off controls. **Processed** routes
through the virtual output after readiness; **Bypassed** releases system routing
while keeping a healthy DSP running. Fallback modes are:

| Mode | Output selection |
| --- | --- |
| Auto | The app chooses the return output; the device menu is read-only. |
| Force | Choose a device; enforce it once on interface disconnect/reconnect, even after another output was selected. |
| Off | Choose a device for explicit Bypassed routing; automatic disconnect fallback is disabled. |

For a laptop with Automatic Switching enabled and DSP/Fallback on **Auto**,
connecting the configured USB interface starts DSP and routes audio through the
virtual output once ready. While the app manages that route, unplugging the
interface returns audio to an available fallback, such as built-in speakers.
Reconnecting resumes processing.

**Follow macOS Output** optionally remembers manual macOS output selections as
the saved Fallback/Bypass target while Automatic Switching is on. It does not
follow those changes in Companion Mode. Off disables app-driven fallback, not
macOS's own behavior when a device disappears.

## Volume, meters and presets

Main Volume controls overall DSP gain independently of Aux trims. Linked Aux groups
move together while preserving each channel's level offset. Hold Shift while
dragging or muting to affect only one Aux. Double-click a slider knob to reset to
0 dB; linked Aux offsets are preserved. Hold Shift while double-clicking an Aux
slider to reset only that channel. Reset changes volume only. Mute states and other
settings remain unchanged, and CamillaDSP's allowed volume limits still apply.
Mixed mute labels identify a split group; only the muted channel's label is red.

Expand Live Metering to read levels while the panel is visible. Collapse it or
close the panel to stop reads. Realtime follows levels; Peak Hold retains the
highest reading. The mode is shared with **Settings > Main Output**. Meter and
slider display ranges do not change DSP gain limits.

The preset selector shows up to eight entries before scrolling; every preset
remains accessible, including those with duplicate display titles.

Select a presets folder in General. Presets use direct DSP control and do not
require CamillaGUI. A timing/buffering warning marks presets that need extra
attention. Presets and DSP activation can interrupt playback.

**Read Levels from DSP** in General refreshes Main/Aux values and mute states
after external edits without changing audio. Settings validate and save changes
automatically. Invalid input or a failed save remains visible. Close Settings
with the macOS close control, Escape or Command-W.

## Start at Login

Enable **Settings > General > Start at Login** to start after signing in.
New setups default Off. Changing the setting affects future logins and does not
stop or start the current session. Turning it off retains the disabled job file.
Automatic Switching is a separate audio policy.

Startup uses `org.camillacompanion.login` in your per-user LaunchAgents folder.
An existing job with that current identity keeps its enabled/disabled choice when
its executable, configuration and state paths match this session. Keep the app
and configuration at their registered locations.

Older development jobs and folders are not adopted automatically. Moving from an
older build requires a deliberate settings/startup cutover; copying the app alone
does not migrate it. The checkbox reflects the current job and macOS disabled
override, with failures shown. Two sign-out/sign-in cycles on the tested Mac
confirmed that On starts one controller and Off starts none. The macOS disabled
override was also checked through `launchctl`, including the case where the plist
remains enabled while the override makes the setting Off. This did not test the
System Settings UI, a clean user account, or downloaded-app approval. Those remain
unverified installation cases.

## Files and backups

The folder for a new installation is:

```text
~/Library/Application Support/CamillaCompanion/
```

Older settings folders and startup jobs are not adopted automatically. Stop the
older controller before using this build; copy or reconfigure settings deliberately
rather than running both controllers. **Open Settings Folder** reveals the
active runtime-state directory. `--config` and `--state` can select independent
locations: preferences and LoginItemBackups follow the state path; the setup
receipt and generated DSP jobs follow the configuration path.

| File or folder | Purpose |
| --- | --- |
| `config.json` | Profiles, device UIDs, DSP job/endpoint and optional GUI configuration |
| `runtime-state.json.ui-preferences.json` | Appearance, mode, meter settings, Main ranges and presets folder |
| `runtime-state.json.aux-preferences.json` | Per-profile Aux labels, visibility, groups and display range |
| `runtime-state.json.fallback-preferences.json` | Per-profile fallback policy and target |
| `app-setup.json` | Versioned setup receipt beside the controller configuration |
| `DSPJobs/` | Generated on-demand DSP job and its DSP state; imported jobs stay at their original paths |
| `GUIJobs/` | Generated on-demand GUI jobs |
| `LoginItemBackups/` | Previous app login-job files saved before explicit startup changes |
| `Backups/` | Local deployment rollback copies |
| `runtime-state.json`, `.lock` and command sockets | Runtime ownership and coordination, not portable preferences |

Preferences use versioned, validated JSON and atomic replacement. Start at Login
is stored through the login job and macOS override, not a UI preference Boolean.
The login job lives in `~/Library/LaunchAgents/`: the app uses
`org.camillacompanion.login.plist`.

Quit before editing JSON or taking a settings backup. Preserve controller JSON,
preference sidecars and the setup receipt, plus separately stored DSP YAML,
coefficient files, presets and any imported job files. Generated DSP state can
contain the active preset and should also be backed up if it matters to the
setup. Do not copy locks, command sockets or route-ownership records as portable
settings. Paths and device UIDs need review on another Mac.

## Updates and removal

There is no automatic updater or public installer/uninstaller. Installed local
app updates are maintainer-managed; this guide does not provide an end-user update
workflow.

### Updating an installed app

Keep a settings backup and the previous verified app. Use a reviewed replacement
procedure that stops the controller cleanly, and keep the app at its registered
`/Applications/CamillaCompanion.app` path. Do not copy over a running bundle or
move a registered app without updating its login job. There is no in-app update
action.

### Older development builds

This beta uses `CamillaCompanion` settings, `camillacompanion` as its executable,
and `org.camillacompanion.login` for startup. Older development names are not
recognized automatically. Stop and disable the older controller first, back up
its configuration and preferences, then configure or deliberately move them to
the new location. Review paths and device UIDs before activation. Do not run both
controllers against the same DSP or audio devices.

The maintainer helper supports only the current names and a narrow verified
single-profile policy. It is not an importer for older development builds.

### Stop using the beta

1. Turn **Start at Login** off in General.
2. Choose **More > Quit**. Disabling startup alone leaves the current session running.

For optional app-only removal, after Quit move only
`/Applications/CamillaCompanion.app` to the Trash. This leaves the disabled login
job and saved settings in place for reuse. Full removal has not been validated.
Keep CamillaDSP, CamillaGUI, drivers, YAML, coefficients, presets and imported
jobs: they belong to the existing audio setup, not the companion app.

Optional settings cleanup is a separate manual task and has not been validated.
The app may use custom configuration and state paths, and imported jobs remain at
their original locations. Inspect each exact path and file before removing anything;
do not delete an entire settings or configuration folder if it contains external
or imported files. The app does not provide an ownership-safe cleanup operation.

## Troubleshooting

- **DSP Waiting:** check the required interface and selected profile. On intent
  can wait for reconnection; a physical device cannot process while absent.
- **DSP cannot start:** inspect Status and on-demand diagnostics, confirm the
  executable/YAML paths and check for another process owning the endpoint/device.
- **GUI unavailable:** Not configured, Uninstalled and Not found describe different
  setup conditions. CamillaGUI is not required for DSP controls or presets.
- **Stale levels after another client changes them:** use Read Levels from DSP.
- **Cannot reopen:** use `camillacompanion launch` with the same configuration/state paths
  as the running controller. Do not create another state path as a workaround.
- **Underruns or buffer instability:** investigate the CamillaDSP configuration,
  engine and hardware. CamillaCompanion does not tune or repair the audio engine.

When sharing diagnostics, include the app version and operating mode, and review
paths or other personal details first. **More > About & Diagnostics** also displays
the CamillaDSP version after readiness is verified, or `Unavailable` before then.
The [repository](https://github.com/Edek/CamillaCompanion)
is private; public issue reporting is not available yet.
