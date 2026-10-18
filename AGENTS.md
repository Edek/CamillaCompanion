# Collaboration and deployment

Use no em dashes in responses. Give objective feedback without reflexive praise
or human imitation.

For local deployment, follow [docs/deployment.md](docs/deployment.md). Reuse the
exact release artifact whose final build and checks passed. Do not rebuild or
repeat the full checks merely because deployment was requested later. Record its
code commit and SHA-256, preserve current settings/policy, create one backup,
stop cleanly, replace atomically, and perform bounded installation readiness checks.
Use tools/deploy.py for its supported single-profile default session; it has a read-only --dry-run.
Document the result and commit deployment records. Keep live control/appearance
acceptance separate from installation readiness.

Deploy when authorized by the user or an existing session preference. Automatic
future deployment preference is currently unresolved; do not infer authorization
from compilation alone. Preserve the user's later answer over this default.

No idle watchers or polling. The opt-in Live Levels exception only reads while
its menu panel is visible and DSP eligible. Deployment checks are finite.
Keep the separate startup-underrun investigation artifacts out of unrelated commits.

## Repository map

`Sources/` contains the app and shared modules. `Checks/` is the custom runner;
`Tests/` contains XCTest coverage. Read `docs/building.md` for commands and tool
limits. `Examples/` contains placeholder configuration. `tools/` contains build
and deployment helpers. Use the README and public guides for behavior; do not
change service ownership or audio policy as an incidental cleanup.
