# Changelog

All notable changes to Solnari are documented here. The project follows
[Semantic Versioning](https://semver.org/) from the first tagged public release.

## [Unreleased]

### Added

- Double-click fitting on result-column dividers.
- In-app About screen with bundled Solnari and third-party license viewers.
- Opt-in local MCP access for external Codex clients, limited to the active read-only connection.
- Public repository documentation, contribution guidance, CI, and release preparation.

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

- No Developer ID-signed and notarized downloadable build yet.
- Codex is a local UI prototype and is not connected to an App Server.
- Table data editing, query cancellation, organization-managed policies, and full orphan recovery
  remain in progress.

[Unreleased]: https://github.com/dreamyoungs/solnari/compare/58d29f6...HEAD
[0.1.0 source preview]: https://github.com/dreamyoungs/solnari/commit/58d29f68ec57cbb2bffcc1c2685f27a9b21a8a72
