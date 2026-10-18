# Contributing

Read the [build guide](docs/building.md) and keep changes focused on one problem.
Include a short explanation and the relevant verification. Reuse existing checks;
run the checks affected by the change. Hardware validation is separate.

For bug reports, include the version, macOS version, operating mode and relevant
diagnostics. Remove personal paths and private configuration before sharing.
Audio-engine buffer/underrun issues belong to CamillaDSP.

Do not commit local settings, runtime state, logs, backups, build products or
release binaries. Preserve external DSP/GUI installations and user audio policy.
The project uses [GPL-3.0-only](LICENSE).
