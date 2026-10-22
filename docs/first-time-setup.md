# First-time setup

This tutorial is for a new CamillaCompanion setup. Stop any older controller
before starting; old settings folders and startup jobs are not imported.

## Before opening the app

Have an installed `camilladsp` executable, working YAML configuration and the
audio devices/drivers it uses. CamillaGUI is optional. CamillaCompanion does not
install these dependencies or generate DSP filters. See the
[CamillaDSP installation guide](https://github.com/HEnquist/camilladsp#installing)
if needed. The YAML must name explicit
CoreAudio devices:

| Selection | Purpose |
| --- | --- |
| Capture device | The virtual audio device that receives playback for DSP processing. |
| Playback device | The distinct physical interface/output that plays the processed audio. |

Both selections must match the YAML's device names or UIDs. Do not select the same
device for both roles.

The app supports exactly CamillaDSP **4.1.3** and **5.0.0-beta.2** and detects the
connected engine version automatically. It does not install or bundle CamillaDSP,
CamillaGUI, devices or drivers. CamillaDSP 5 requires a compatible YAML; existing
v4 YAML is not converted automatically. The corresponding official CamillaGUI
backend v5 beta 2 is available, though its executable reports
`camillagui 5.0.0-beta.1`. See [Compatibility](compatibility.md) before selecting
a v5 setup.

## Open Setup

Follow [Install and open](user-guide.md#install-and-open), placing the app in
Applications before opening it.
With no existing configuration, **Set Up CamillaCompanion** opens automatically.
**Already configured** means an existing setup is being shown without replacement.

## Review and save

1. Click **Find Automatically…** to search common installation folders and startup
   definitions once. Select matching DSP/GUI entries and **Use Selection** to fill
   their paths. **Cancel** keeps your current entries. For custom locations or
   anything not found, use **Choose…** beside **CamillaDSP** and **Configuration**.
   Select a working YAML if discovery found only the executable. The search
   starts no application and saves no settings.
2. Check **Capture device** and **Playback device**. The YAML can select matching
   connected devices automatically. Use **Refresh Devices** if needed.
3. Optionally choose a **Presets folder** containing your DSP configurations.
4. Choose **Mode**. **Companion**, the default, controls DSP and leaves macOS
   outputs unchanged; your existing routing must feed the virtual device.
   **Automatic Switching** also routes macOS audio through it when DSP is ready.
5. Under **CamillaGUI (optional)**, choose its executable and configuration if you
   use it. YAML and JSON syntax are supported; addresses and ports must match
   Advanced. Otherwise select **CamillaGUI is not installed**. GUI is not required
   for volume, meters or presets.
6. Leave **Advanced** unchanged for a normal setup. If discovery could not identify
   the GUI address, enter it there before review. Advanced also contains device UIDs,
   connection addresses/port and existing DSP job import. See the
   [setup details](user-guide.md#first-setup) for those cases.
7. Click **Review Setup**. The app checks the YAML with CamillaDSP and shows the
   paths, devices and mode without starting DSP or changing audio. Use **Edit**
   to correct a selection.
8. Choose **Save Only** to save without changing DSP or macOS outputs, or
   **Save and Activate** to save and start the managed session. Activation requires
   both devices and no conflicting DSP owner. For disconnected hardware, enter
   known UIDs in Advanced and use **Save Only**. The activation button then reads
   **Activate**; you can also close and reopen the app later when ready.

## Check the first session

Open the menu bar panel. Confirm DSP is ready before checking playback.

- Use **Main Volume** and mute for overall output. Configure available Aux faders
  in **Settings > Aux Outputs**. Hold Shift while dragging or muting to adjust
  one Aux without unlinking its group.
- Linked Aux faders move together, preserving each channel's level offset.
  Double-click a slider knob to reset to 0 dB; linked Aux offsets are preserved.
  Hold Shift while double-clicking an Aux slider to reset only that channel.
  Reset changes volume only, leaves mute states and other settings unchanged, and
  remains subject to DSP volume limits.
- Expand **Live Metering**. Realtime follows levels; Peak Hold keeps the highest
  reading. Closing the panel or collapsing metering stops meter reads.
- Choose presets from the panel; set their folder in **Settings > General**.
  A preset may restart processing and interrupt playback.
- **More > About & Diagnostics** shows the connected CamillaDSP version after
  readiness verification, or **Unavailable** until then.
- Use **Settings > General > Read Levels from DSP** if another client changed
  volume or mute values. Settings save valid changes automatically.

Opening the app again reveals the same panel. Closing the panel keeps DSP
running; use **More > Quit** to stop the controller and its managed DSP.

## Startup and saved settings

**Settings > General > Start at Login** is initially Off for a new setup. Enable
it after checking your configuration. It affects future logins and does not
restart the current session. Keep the app in its registered Applications location.

Settings live in `~/Library/Application Support/CamillaCompanion/`.
Older settings folders are not imported automatically.
**Open Settings Folder** in General reveals the active preference directory;
advanced configuration paths may be separate. Quit before editing JSON or making
a backup. Preserve external YAML, coefficients and presets too. See
[Files and backups](user-guide.md#files-and-backups).

## If something fails

- **Device mismatch:** check the YAML selectors and refresh the connected devices.
  A missing interface cannot activate; save without activation until it is ready.
- **DSP already running:** stop it through its existing manager, or review the
  compatible job-import path. Setup will not stop another manager's DSP.
- **DSP ready but no processed audio:** check that the player/macOS output feeds
  the virtual capture device, especially in Companion mode, then check Main mute
  and the YAML's output routing.
- **Review fails:** correct the reported executable, YAML or selection error.
  Existing files are preserved.

The package targets Apple Silicon and macOS 13 or later. Start at Login On/Off
was confirmed across two sign-out/sign-in cycles on the tested Mac. Clean-user
activation, downloaded-app approval, the System Settings UI path and full removal
remain unverified.
See the [release notes](release-notes.md#known-limits) for the beta's limits.
