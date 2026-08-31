# Backend architecture

Solnari separates UI state, non-secret profile persistence, credentials, database engines,
and network paths. PostgreSQL, MySQL, and SQLite use the same workspace contract while their
wire protocols and schema queries remain isolated.

## Components

- `WorkspaceModel` coordinates user actions and publishes UI state on the main actor.
- `ConnectionProfileStore` persists named, non-secret connection profiles in `UserDefaults`.
- `KeychainPasswordStore` stores passwords as generic-password items keyed by profile UUID.
- `DatabaseBackend` routes workspace operations to the selected engine and coordinates transport cleanup.
- `PostgreSQLBackend`, `MySQLBackend`, and `SQLiteBackend` own driver sessions, metadata queries,
  schema discovery, and dynamic result decoding.
- `ConnectionTransportManager` starts local Cloud SQL Proxy, SSH forwarding, or Kubernetes
  port-forward processes and tears them down with the database session.
- `QueryTableData` crosses the backend/UI boundary with typed cells and arbitrary columns.

Passwords never appear in `ConnectionProfile`, serialized preferences, diagnostics, or query
results. Passwords are never passed as helper-process arguments or environment variables.

## Connection lifecycle

Saving a connection follows a fail-closed sequence:

1. validate the draft and create an in-memory profile;
2. establish the selected network path and connect the selected database engine;
3. fetch server version, encoding, database, and session time zone;
4. discover user tables and views;
5. store the password in Keychain;
6. persist the non-secret profile and publish it in the sidebar.

If any step fails, the live client is cancelled, the Keychain item is removed, and the profile
is not retained. Profiles loaded after relaunch begin disconnected and reconnect with their
Keychain credential when selected or when a query is run.

The application owns one `AppEnvironment` and one `WorkspaceModel` per process. A process lock
prevents a second launch from owning duplicate database sessions or helper processes; the second
launch asks the existing app to bring its main window forward. Quit waits for all database clients,
Cloud SQL Proxy and SSH forwarding processes, and Kubernetes relay cleanup to finish. Screen lock,
sleep, screen sleep, and user-session deactivation perform the same cleanup and leave profiles
disconnected after the Mac becomes active again.

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
