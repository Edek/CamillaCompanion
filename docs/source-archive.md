# Source archive

The corresponding-source archive includes the application, checks, tests,
examples, build and packaging tools, public guides and licenses. It contains the
complete pinned Yams source, including CYaml, under `Dependencies/Yams/`.
`SOURCE-IDENTITY.json` records the application commit, selected paths and dependency
revision. The original dependency licenses remain included.

Private configurations, runtime state, Git history, local verification records
and investigation files are excluded. The public guides are the committed release
snapshot; newer documentation may be supplied separately without changing that
source identity.

See [Build and verify](building.md) for commands and tool requirements. The package
still declares its pinned upstream dependency, so a normal first build may need
network access even though the dependency source is included. Build and temporary
check fixtures do not establish hardware or installation acceptance; see the
[release notes](release-notes.md#known-limits).

The project uses [GPL-3.0-only](../LICENSE). See the
[third-party notices](../THIRD_PARTY_NOTICES.md) for dependency licenses.
