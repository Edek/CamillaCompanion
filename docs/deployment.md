# Local deployment procedure

Use this procedure to replace the installed local beta with an already verified
release. Deployment is a short installation step after source verification.
Run only for a user-authorized deployment. The automatic-deployment preference
is unresolved; do not infer authorization for a future replacement from an earlier
deployment request. Building or testing source alone does not authorize live replacement.

## Prepare once, before live writes

1. Finish the release build and full portable/native checks for the final source.
   Retain native Main/meter startup validation and the default GUI policy.
2. Record the source commit, release binary SHA-256, and passing check evidence.
   Reuse that exact verified artifact within the current task. Do not rebuild or
   rerun checks during deployment unless source/artifact changes or a failure
   creates a concrete reason to repeat them.
3. Confirm authorization and review the intended replacement and recovery scope.
   Configuration, profiles, Aux/UI/fallback preferences, and user policy must be preserved.

`tools/deploy.py` consumes this evidence; it does not build, run the full checks,
or certify that an artifact passed them. A matching hash proves artifact identity.

## Install once

From the repository root, use the verified commit and full SHA-256:

```sh
python3 tools/deploy.py --source-commit COMMIT --expected-sha SHA256
```

Use `--dry-run` for a read-only preflight. The helper is for a standalone `camillacompanion` executable under
`Application Support/CamillaCompanion`, with `org.camillacompanion.login`. It
supports the current single-profile, settled DSP Auto, managed-routing, GUI Auto session. It rejects session overrides,
suspension, recovery, and a LaunchAgent startup mode override before changing
services. For those cases, capture and preserve the requested policy using the
manual procedure below; do not reset it just to use the shortcut. The helper does
not claim a successful rollback merely because launchd accepted the old job.

The deployment sequence is:

1. Take one preflight status/settings capture, including DSP mode, profile,
   routing/bypass intent, GUI policy, and configuration/preference identities.
2. Create one timestamped rollback backup. Stop the login controller cleanly and
   wait for its exit before replacement. The newly started controller verifies
   the single-instance lock; readiness failure must not be reported as success.
3. Replace the binary atomically, then start the existing login controller with
   its existing menu bar setting. The shortcut retains default policy. A manual
   deployment must restore captured session overrides and bypass intent.
4. Use one finite readiness deadline. Confirm one controller, installed artifact
   hash, preserved settings, and DSP/routing/GUI state appropriate to the captured
   policy. GUI Off or DSP Off must not be changed merely to produce readiness.
5. Stop observations on success or deadline expiry. Add no recurring watchers,
   background status reads, log followers, or continuing readiness probes.

Keep verification focused on changed installation state. An unchanged verified
artifact needs no second compilation or full regression run. A transient startup
state can settle inside the same deadline; repeated observations do not extend it.

## Retained packaged app updates

For a single-profile app already using the current executable and startup names,
the packaging helper has an explicit
`--update-installed-app` mode. Its default invocation remains read-only:

```sh
python3 tools/packaging/migrate_install.py \
  --update-installed-app \
  --app /path/to/retained/CamillaCompanion.app \
  --expected-sha VERIFIED_INPUT_SHA256 \
  --preserve-gui-off
```

Use `--preserve-gui-off` only for a captured, settled GUI Off session; omit it for
GUI Auto. Review preflight, then add `--apply` for an authorized update. The helper
requires the existing target's exact executable and bundle identity, preserves
startup enablement and data paths, backs up once, and restores the prior bundle
on normal replacement/readiness failure. Later external bundle edits are retained
and reported for manual recovery rather than executed as the supposed old app.
This narrow maintainer procedure is not a general updater or a transition tool
for the older AutoAudioSwitcher installation. Stop that controller and review a
separate settings/startup cutover before installing the renamed build. Other session policies
still require the manual procedure below.

## Session overrides: manual path

1. Capture DSP mode/profile, bypass/suspension, and every GUI policy before stopping.
   Record the current LaunchAgent arguments as well as its file backup.
2. Use the same backup, clean stop, atomic replacement, and exit verification.
3. Carry captured DSP mode into startup arguments (`--mode auto`, `force-on`, or
   `force-off`; `force-on` needs `--profile ID`). Preserve the original login
   arguments after launch if the override was intended for this session only.
4. Restore GUI overrides through `gui start|stop|auto --profile ID` and explicit
   bypass through `release`. GUI policy restoration must not change DSP routing.
   Account for the expected interruption of a controller replacement.
5. Check captured policy and appropriate readiness within one finite window.
   Suspension or an unsettled transition requires an explicit implementation of
   preservation before replacement; the shortcut does not approximate it with On.

## Failure and recovery

On stop, replacement, startup, or readiness failure, report the failed phase and
retain the backup and original binary on a stop failure. For a replacement,
startup, or readiness failure, restore the previous binary and login-controller state.
Stop the replacement controller before rollback; never run two controllers.
Preserve configuration and preferences. The menu controller uses Interactive process
classification, required for reliable finite user DSP commands on the tested macOS
version. Deployment migrates its prior Background/Standard policy while retaining
all other LaunchAgent fields. Dry-run reports this change without writing. Atomic
migration and rollback check plist identity so later external edits are preserved.
Do not change the separate legacy watcher or DSP/GUI jobs as part of this migration.
Restore a saved settings file only when
the deployment itself changed or damaged it, and do not overwrite later user edits.
Apply the same finite startup/readiness scope to recovery and report unresolved
failure rather than adding a retry loop. Do not change DSP clocks, buffers,
pipeline filters, hardware selectors, or unrelated services as a deployment fix.

## Record the result

After success, retain a brief installation record: time,
source commit, installed SHA-256 match, backup path, settings preservation, and
final DSP/routing/GUI policy and readiness. Record failure/rollback honestly.
Do not write a successful deployment entry before the final observations pass.

Workflow verification establishes installation and service readiness. It does
not establish audio quality, live Main/meter interaction, native appearance,
physical reconnect, wake behavior, or user acceptance. Keep those outstanding
checks in separate acceptance records. The public [release notes](release-notes.md#known-limits)
summarize the remaining beta limits.
