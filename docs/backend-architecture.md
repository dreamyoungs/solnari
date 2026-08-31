# Backend architecture

Solnari's first production backend slice is Direct PostgreSQL. The implementation keeps UI
state, non-secret profile persistence, credentials, and live database sessions in separate
components so later transports and engines can reuse the same boundaries.

## Components

- `WorkspaceModel` coordinates user actions and publishes UI state on the main actor.
- `ConnectionProfileStore` persists named, non-secret connection profiles in `UserDefaults`.
- `KeychainPasswordStore` stores passwords as generic-password items keyed by profile UUID.
- `PostgreSQLBackend` owns PostgresNIO clients, connection lifecycles, metadata queries,
  schema discovery, and dynamic result decoding.
- `QueryTableData` crosses the backend/UI boundary with typed cells and arbitrary columns.

Passwords never appear in `ConnectionProfile`, serialized preferences, diagnostics, or query
results. PostgresNIO's no-op logger initializer is used, so SQL and connection data are not
emitted through the driver's background logger.

## Connection lifecycle

Saving a connection follows a fail-closed sequence:

1. validate the draft and create an in-memory profile;
2. connect to PostgreSQL and fetch server version, encoding, database, and session time zone;
3. discover user tables and views;
4. store the password in Keychain;
5. persist the non-secret profile and publish it in the sidebar.

If any step fails, the live client is cancelled, the Keychain item is removed, and the profile
is not retained. Profiles loaded after relaunch begin disconnected and reconnect with their
Keychain credential when selected or when a query is run.

## Typed results

The PostgreSQL adapter decodes booleans, signed integers, floating-point values, arbitrary
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
| PostgreSQL | Available | Planned | Planned | Planned |
| MySQL | Planned | Planned | Planned | Planned |
| SQLite | Planned | Not applicable | Not applicable | Not applicable |

Unsupported combinations remain visible for product-design feedback, but their test and save
actions are disabled and identified as unavailable.

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
