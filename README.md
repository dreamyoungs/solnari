# Solnari

**An open-source database client for humans and agents, built for macOS.**

Solnari explores a native SwiftUI experience for working with local, cloud, and private databases. PostgreSQL, MySQL, and SQLite now share one connection workflow, with direct, Cloud SQL, SSH, and Kubernetes paths where each engine supports them.

## Current features

- PostgreSQL, MySQL, and SQLite connection testing, schema discovery, and query execution
- Persistent named connection profiles with passwords stored separately in macOS Keychain
- Native macOS workspace with live connection status and schema navigation
- Multi-tab SQL editor and resizable editor/results layout
- Dynamic AppKit-backed result table with resizable columns and multiple-row selection
- Result copy and export as CSV, TSV, JSON, JSON Lines, Markdown, and SQL `INSERT`
- Working connection paths for Direct TCP, Google Cloud SQL Auth Proxy, SSH, and Kubernetes relay pods
- Engine-aware character-set and collation options for PostgreSQL, MySQL, and SQLite
- Embedded Codex assistant experience with SQL proposals and explicit editor handoff
- Runtime language switching between English and Korean
- Configurable result display time zone with typed zoned and zone-less timestamps
- Light and dark appearance through macOS semantic colors

## Prototype boundaries

The following interactions are intentionally unavailable or mocked in this milestone:

- Codex App Server communication;
- character-set, collation, and permission audits;
- query cancellation, transaction controls, and data editing.

Keeping these boundaries visible lets contributors evaluate the product flow before backend contracts are fixed.

## Architecture direction

Solnari keeps database engines separate from network transports. Engine adapters own live sessions, metadata discovery, schema inspection, and typed result decoding; a transport manager supplies local endpoints without coupling process lifecycles to SwiftUI. See [Backend architecture](docs/backend-architecture.md) and [Connection paths](docs/connection-paths.md).

Results will cross the backend boundary as typed values rather than preformatted strings. Temporal values in particular must preserve database type, precision, source offset, and zone semantics; see [Time zone handling](docs/timezone-design.md).

Codex conversations will use ephemeral App Server threads and will not be persisted by Solnari. Prompts, responses, SQL, schema data, and result values are also excluded from application logs and telemetry; see [Codex conversation privacy](docs/codex-privacy.md).

## Requirements

- macOS 14 or newer
- Swift 6.1 or newer, or a compatible Xcode toolchain

Dependencies are resolved by Swift Package Manager. Database access uses the open-source [PostgresNIO](https://github.com/vapor/postgres-nio), [MySQLNIO](https://github.com/vapor/mysql-nio), and [SQLiteNIO](https://github.com/vapor/sqlite-nio) drivers.

Cloud SQL, SSH, and Kubernetes paths use `cloud-sql-proxy`, OpenSSH, and `kubectl`, respectively. Solnari discovers them from its launch `PATH`, common macOS installation directories, or the `SOLNARI_CLOUD_SQL_PROXY`, `SOLNARI_SSH`, and `SOLNARI_KUBECTL` environment variables.

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

Live PostgreSQL and MySQL integration tests are skipped unless test servers are configured. Use the `SOLNARI_TEST_POSTGRES_*` or `SOLNARI_TEST_MYSQL_*` variables documented in [Backend architecture](docs/backend-architecture.md). SQLite and isolated fake-CLI transport tests run on every `swift test`.

## Roadmap

The current backend slice supports:

1. test and establish PostgreSQL, MySQL, and SQLite connections;
2. persist named profiles while keeping passwords in Keychain;
3. open Direct TCP, Cloud SQL Proxy, SSH forwarding, and temporary Kubernetes relay paths;
4. introspect user schemas, tables, views, and column counts;
5. execute typed queries and feed arbitrary result columns into the grid and export pipeline;
6. apply display-time-zone rules without changing canonical source values.

Query cancellation, transaction controls, schema text-setting audits, and Codex integration remain on the roadmap.

## Contributing

Contributions and design feedback are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the current development workflow and review expectations.

## License

Solnari is available under the [Apache License 2.0](LICENSE).
