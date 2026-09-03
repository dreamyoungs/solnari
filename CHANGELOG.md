# Changelog

All notable changes to Solnari are documented here. The project follows
[Semantic Versioning](https://semver.org/) from the first tagged public release.

## [Unreleased]

## [0.2.1 source preview] - 2026-09-03

### Fixed

- Clicking the Dock icon now recreates the main window after all Solnari windows have been closed.

## [0.2.0 source preview] - 2026-09-01

### Added

- Double-click fitting on result-column dividers.
- In-app About screen with bundled Solnari and third-party license viewers.
- Opt-in local MCP access for external Codex clients, limited to the active read-only connection.
- Public repository documentation, contribution guidance, CI, and release preparation.
- Per-connection workspaces that preserve schema, query tabs, and results when switching databases.
- Apple Silicon local DMG creation and a prepared Developer ID signing, notarization, stapling, and
  checksum workflow for use after Apple Developer Program enrollment.
- Semantic app version and build-number files with a controlled bump script.

### Fixed

- Empty PostgreSQL schemas such as `public` now remain visible in the explorer.
- Multi-line clipboard content is reduced to one line in connection text fields.
- IAM database-user guidance no longer looks like a Google Cloud authentication failure.
- Switching between already-connected databases no longer leaves another database's schema visible.

## [0.1.0 source preview] - 2026-09-01

### Added

- Native SwiftUI workspace with resizable editor, result grid, and Korean/English localization.
- PostgreSQL, MySQL, and SQLite sessions, schema discovery, metadata inspection, and typed results.
- CSV, TSV, JSON, JSON Lines, Markdown, and SQL `INSERT` copy/export formats.
- Direct, SSH, Cloud SQL, and Kubernetes connection paths.
- Bundled Node 24 Core using Google Auth Library and the official Cloud SQL Connector.
- Passwordless Cloud SQL IAM authentication and project, instance, database, and IAM-user discovery.
- Local AES-GCM credential vault and lifecycle cleanup on quit, lock, sleep, and user switching.
- Read-only SQL preflight and database-session write protection.

### Known limitations

- Local DMGs are ad-hoc signed and not notarized until Apple Developer Program enrollment.
- The first downloadable DMG supports Apple Silicon only; Intel builds remain future work.
- Codex is a local UI prototype and is not connected to an App Server.
- Table data editing, query cancellation, organization-managed policies, and full orphan recovery
  remain in progress.

[Unreleased]: https://github.com/dreamyoungs/solnari/compare/v0.2.1...HEAD
[0.2.1 source preview]: https://github.com/dreamyoungs/solnari/releases/tag/v0.2.1
[0.2.0 source preview]: https://github.com/dreamyoungs/solnari/releases/tag/v0.2.0
[0.1.0 source preview]: https://github.com/dreamyoungs/solnari/commit/58d29f68ec57cbb2bffcc1c2685f27a9b21a8a72
