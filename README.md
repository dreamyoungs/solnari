# Solnari

**An open-source database client for humans and agents, built for macOS.**

Solnari explores a native SwiftUI experience for working with local, cloud, and private databases. Direct PostgreSQL connections now run end to end; the remaining engines, network transports, and Codex integration are still being developed behind explicit boundaries.

## Current features

- Direct PostgreSQL connection testing, schema discovery, and query execution
- Persistent named connection profiles with passwords stored separately in macOS Keychain
- Native macOS workspace with live connection status and schema navigation
- Multi-tab SQL editor and resizable editor/results layout
- Dynamic AppKit-backed result table with resizable columns and multiple-row selection
- Result copy and export as CSV, TSV, JSON, JSON Lines, Markdown, and SQL `INSERT`
- Guided connection flows for Direct TCP, Google Cloud SQL, SSH, and Kubernetes
- Engine-aware character-set and collation options for PostgreSQL, MySQL, and SQLite
- Embedded Codex assistant experience with SQL proposals and explicit editor handoff
- Runtime language switching between English and Korean
- Configurable result display time zone with typed zoned and zone-less timestamps
- Light and dark appearance through macOS semantic colors

## Prototype boundaries

The following interactions are intentionally unavailable or mocked in this milestone:

- Cloud SQL Proxy, SSH, and Kubernetes tunnel processes;
- MySQL and SQLite backends;
- Codex App Server communication;
- character-set, collation, and permission audits;
- query cancellation, transaction controls, and data editing.

Keeping these boundaries visible lets contributors evaluate the product flow before backend contracts are fixed.

## Architecture direction

Solnari keeps database engines separate from network transports. The current PostgreSQL backend owns connection pools, metadata discovery, and typed query decoding without coupling those responsibilities to SwiftUI. See [Backend architecture](docs/backend-architecture.md).

Results will cross the backend boundary as typed values rather than preformatted strings. Temporal values in particular must preserve database type, precision, source offset, and zone semantics; see [Time zone handling](docs/timezone-design.md).

Codex conversations will use ephemeral App Server threads and will not be persisted by Solnari. Prompts, responses, SQL, schema data, and result values are also excluded from application logs and telemetry; see [Codex conversation privacy](docs/codex-privacy.md).

## Requirements

- macOS 14 or newer
- Swift 6.1 or newer, or a compatible Xcode toolchain

Dependencies are resolved by Swift Package Manager. PostgreSQL access uses the open-source [PostgresNIO](https://github.com/vapor/postgres-nio) driver.

## Run

```bash
swift run Solnari
```

You can also open `Package.swift` in Xcode and run the `Solnari` executable target.

## Verify

```bash
swift build
swift test
git diff --check
```

The PostgreSQL integration test is skipped unless a test server is configured. Set `SOLNARI_TEST_POSTGRES_HOST` and, when needed, `SOLNARI_TEST_POSTGRES_PORT`, `SOLNARI_TEST_POSTGRES_USER`, `SOLNARI_TEST_POSTGRES_PASSWORD`, `SOLNARI_TEST_POSTGRES_DATABASE`, and `SOLNARI_TEST_POSTGRES_TLS`.

## Roadmap

The Direct PostgreSQL path currently supports:

1. test and establish a connection;
2. persist named profiles while keeping passwords in Keychain;
3. introspect user schemas, tables, views, and column counts;
4. execute typed queries and feed arbitrary result columns into the grid and export pipeline;
5. apply display-time-zone rules without changing canonical source values.

Query cancellation and transaction controls are next for PostgreSQL. Cloud SQL, SSH, Kubernetes, MySQL, SQLite, and Codex integration will follow behind the same adapter and transport boundaries.

## Contributing

Contributions and design feedback are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the current development workflow and review expectations.

## License

Solnari is available under the [Apache License 2.0](LICENSE).
