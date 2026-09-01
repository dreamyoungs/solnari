# Backend architecture

Solnari uses a native SwiftUI frontend and a bundled Node.js core connected over newline-delimited
JSON-RPC on private stdio. PostgreSQL, MySQL, and SQLite share the same workspace contract while
their wire protocols and schema queries remain isolated.

## Components

- `WorkspaceModel` coordinates user actions and publishes UI state on the main actor.
- `NodeBackendClient` owns one bundled Node process and correlates bounded JSON-RPC requests by ID.
- `backend/` uses Google Auth Library, the Cloud SQL Node.js Connector, `pg`, and `mysql2` for
  Cloud SQL discovery, IAM authentication, sessions, metadata, and queries.
- `ConnectionProfileStore` stores disconnected connection definitions in local app preferences.
- `LocalEncryptedPasswordStore` encrypts database passwords with AES-GCM using a separate 256-bit
  local key and restricts its directory and files to the current macOS user.
- `DatabaseBackend` routes Cloud SQL operations to Node and retains the native adapters during the
  staged migration of Direct, SSH, Kubernetes, and SQLite paths.
- `ConnectionTransportManager` currently starts SSH forwarding or Kubernetes port-forward processes
  and tears them down with the database session.
- `QuerySafetyPolicy` rejects non-read statements before they reach a read-only session; each
  engine also configures its database connection to reject writes.
- `QueryTableData` crosses the backend/UI boundary with typed cells and arbitrary columns.
- `MCPAccessController` owns an opt-in, user-only local socket. The bundled Node STDIO MCP server
  forwards bounded tool calls to the running app without reading profile or credential storage.

Passwords never appear in `ConnectionProfile`, serialized preferences, diagnostics, or query
results. Passwords are never passed as helper-process arguments or environment variables.
The Node child receives a sanitized environment, uses an Application Support working directory,
and preloads a guard that disables every `node:child_process` execution API. Therefore Google
library fallbacks cannot launch `gcloud` or any other CLI.
The MCP entrypoint uses the official TypeScript MCP SDK, publishes read-only tool annotations, and
can access only the profile visibly selected in the running app. Query calls additionally require
that profile to be connected with the read-only access level.
The source and CI pin the bundled runtime through `.node-version`; release builds reject a different
Node version. App packaging includes the Solnari license and the license texts found in the bundled
Node runtime, production npm dependency tree, and resolved Swift package checkouts.

## Connection lifecycle

Saving a connection follows a fail-closed sequence:

1. validate the draft and create an in-memory profile;
2. establish the selected network path and connect the selected database engine;
3. fetch server version, encoding, database, and session time zone;
4. discover user tables and views;
5. encrypt the password in the local credential vault;
6. persist the disconnected connection definition and publish it in the sidebar.

If any step fails, the live client is cancelled, the provisional encrypted credential is rolled
back, and the profile is not retained. Profiles loaded after relaunch begin disconnected and
reconnect with their local encrypted credential when selected or when a query is run.

The application owns one `AppEnvironment` and one `WorkspaceModel` per process. A process lock
prevents a second launch from owning duplicate database sessions or helper processes; the second
launch asks the existing app to bring its main window forward. Quit waits for the Node core,
database clients, SSH forwarding processes, and Kubernetes relay cleanup to finish. Screen lock,
sleep, screen sleep, and user-session deactivation perform the same cleanup and leave profiles
disconnected after the Mac becomes active again.
The same lifecycle closes the MCP socket. A Codex-started STDIO MCP process cannot reconnect until
Solnari is active and the user has enabled local MCP access again.

## Typed results

The PostgreSQL and MySQL adapters decode booleans, signed integers, floating-point values, arbitrary
precision numerics, UUIDs, binary values, dates, timestamps, and timestamps with time zone.
Unknown or extension types use a textual representation when PostgresNIO supports one and a
bounded hexadecimal representation otherwise.

`timestamp with time zone` values remain absolute `Date` instances and are formatted in the
selected display time zone. Zone-less `timestamp` values use UTC calendar components as a
transport representation so their displayed wall-clock fields are not silently shifted.
Copy and export use canonical values by default. See [Time zone handling](timezone-design.md).

## Current support matrix

| Engine | Direct | Cloud SQL | SSH | Kubernetes |
| --- | --- | --- | --- | --- |
| PostgreSQL | Available | Available | Available | Available |
| MySQL | Available | Available | Available | Available |
| SQLite | Available | Not applicable | Not applicable | Not applicable |

SQLite's unavailable network paths remain visible but disabled so the support boundary is explicit.
Kubernetes offers a preferred existing Service/Pod port-forward that creates no cluster resource,
plus a separately labeled experimental temporary relay for environments that explicitly allow it.

## Integration verification

The default test suite exercises profile persistence, validation, typed time export, numeric
JSON output, and duplicate-column handling. A read-only live PostgreSQL test is enabled by
setting environment variables:

```bash
SOLNARI_TEST_POSTGRES_HOST=127.0.0.1 \
SOLNARI_TEST_POSTGRES_PORT=5432 \
SOLNARI_TEST_POSTGRES_USER=solnari \
SOLNARI_TEST_POSTGRES_PASSWORD=secret \
SOLNARI_TEST_POSTGRES_DATABASE=solnari_test \
swift test --filter PostgreSQLBackendIntegrationTests
```

Set `SOLNARI_TEST_POSTGRES_TLS=true` when the test server requires TLS. The integration test
connects, reads server metadata and schema information, executes a typed `SELECT`, and then
closes the client. It does not create, modify, or delete database objects.

The MySQL test uses the equivalent variables:

```bash
SOLNARI_TEST_MYSQL_HOST=127.0.0.1 \
SOLNARI_TEST_MYSQL_PORT=3306 \
SOLNARI_TEST_MYSQL_USER=solnari \
SOLNARI_TEST_MYSQL_PASSWORD=secret \
SOLNARI_TEST_MYSQL_DATABASE=solnari_test \
swift test --filter MySQLBackendIntegrationTests
```

Set `SOLNARI_TEST_MYSQL_TLS=true` when required. The SQLite test creates an isolated temporary
database. Transport tests use local fake executables to verify arguments, readiness detection,
process termination, and Kubernetes relay deletion without contacting external infrastructure.

The Node core also has an opt-in, passwordless Cloud SQL integration test. It uses ADC and automatic
IAM database authentication, sets the session read-only, reads schema metadata, verifies zoned and
zone-less timestamp types, and closes every session. Configure
`SOLNARI_TEST_CLOUD_SQL_PROJECT`, `SOLNARI_TEST_CLOUD_SQL_REGION`,
`SOLNARI_TEST_CLOUD_SQL_INSTANCE`, `SOLNARI_TEST_CLOUD_SQL_DATABASE`,
`SOLNARI_TEST_CLOUD_SQL_USER`, and `SOLNARI_TEST_CLOUD_SQL_ENGINE`, then run:

```bash
npm --prefix backend test -- cloud-sql.integration.test.ts
```

MCP tests use the official in-memory client transport to verify tool schemas and annotations, a
temporary user-only Unix socket for the Swift/Node bridge, and an isolated read-only SQLite database
to verify schema access, typed result limits, and write rejection.
