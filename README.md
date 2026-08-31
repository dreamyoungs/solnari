# Solnari

**An open-source database client for humans and agents, built for macOS.**

Solnari explores a native SwiftUI experience for working with local, cloud, and private databases. The project is currently a frontend-first interactive prototype: the application runs and its local UI features work, while database, tunnel, and Codex backends are represented by mock state.

## Current features

- Native macOS workspace with connection and schema navigation
- Multi-tab SQL editor and resizable editor/results layout
- AppKit-backed result table with resizable columns and multiple-row selection
- Result copy and export as CSV, TSV, JSON, JSON Lines, Markdown, and SQL `INSERT`
- Connection flows for Direct TCP, Google Cloud SQL, SSH, and Kubernetes
- Engine-aware character-set and collation options for PostgreSQL, MySQL, and SQLite
- Embedded Codex assistant experience with SQL proposals and explicit editor handoff
- Runtime language switching between English and Korean
- Light and dark appearance through macOS semantic colors

## Prototype boundaries

The following interactions are intentionally mocked in this milestone:

- database connections, schema introspection, and query execution;
- Cloud SQL Proxy, SSH, and Kubernetes tunnel processes;
- Keychain persistence and credential lifecycle;
- Codex App Server communication;
- character-set, collation, and permission audits.

Keeping these boundaries visible lets contributors evaluate the product flow before backend contracts are fixed.

## Architecture direction

Solnari keeps database engines separate from network transports. A PostgreSQL adapter should work with Direct TCP, Cloud SQL, SSH, or Kubernetes without duplicating query and schema behavior.

Results will cross the backend boundary as typed values rather than preformatted strings. Temporal values in particular must preserve database type, precision, source offset, and zone semantics; see [Time zone handling](docs/timezone-design.md).

Codex conversations will use ephemeral App Server threads and will not be persisted by Solnari. Prompts, responses, SQL, schema data, and result values are also excluded from application logs and telemetry; see [Codex conversation privacy](docs/codex-privacy.md).

## Requirements

- macOS 14 or newer
- Swift 6.1 or newer, or a compatible Xcode toolchain

No third-party package dependencies are required for the current prototype.

## Run

```bash
swift run Solnari
```

You can also open `Package.swift` in Xcode and run the `Solnari` executable target.

## Verify

```bash
swift build
git diff --check
```

## Roadmap

The first backend milestone will provide a complete Direct PostgreSQL path:

1. test and establish a connection;
2. introspect databases, schemas, tables, and columns;
3. execute and cancel typed queries;
4. apply display-time-zone rules without changing source values;
5. feed real result data into the existing grid and export pipeline.

Cloud SQL, SSH, Kubernetes, MySQL, SQLite, and Codex integration will follow behind the same adapter and transport boundaries.

## Contributing

Contributions and design feedback are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the current development workflow and review expectations.

## License

Solnari is available under the [Apache License 2.0](LICENSE).
