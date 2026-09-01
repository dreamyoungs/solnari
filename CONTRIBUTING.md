# Contributing to Solnari

Thank you for helping make Solnari a dependable, approachable database client. The project welcomes
small bug fixes, database-specific verification, focused UX improvements, documentation, and
security reviews.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through the private
channel described in [SECURITY.md](SECURITY.md), not through a public issue.

## Before starting

- Search existing issues and pull requests before opening a duplicate.
- Use an issue to discuss broad architecture, new connection methods, security-policy changes, or
  work that significantly changes the UI.
- Keep pull requests focused. Separate unrelated refactoring from behavior changes.
- Never add real credentials, project IDs, private hostnames, database names, production SQL,
  schemas, query results, or screenshots containing them.

## Development setup

You need:

- macOS 14 or newer;
- a Swift 6.1-compatible Xcode toolchain; and
- the Node.js 24 LTS version pinned in `.node-version`, with npm.

```bash
nvm use # when using nvm
npm --prefix backend ci
npm --prefix backend run build
swift build
swift test
./Scripts/run-app.sh
```

The built development app includes a Node runtime and is installed at
`~/Applications/Solnari Development.app`. Cloud SQL uses the bundled Node Core; Direct, SSH,
Kubernetes, and SQLite currently retain their native Swift adapters.

## Design boundaries

- Keep SwiftUI presentation, persisted connection definitions, credentials, network transports,
  and database sessions as separate boundaries.
- Cloud SQL must use the official Google Auth Library and Cloud SQL Connector. Do not add a
  `gcloud` or external proxy fallback.
- The Node Core communicates only through bounded private stdio JSON-RPC and must not spawn external
  processes.
- The external-agent MCP server must remain opt-in, local-only, credential-free, and scoped to the
  connection visibly selected in Solnari. New tools need accurate MCP annotations and failure tests.
- General database passwords belong only in the local AES-GCM credential vault. Do not put secrets
  in connection definitions, logs, process arguments, environment variables, fixtures, or Codex
  context.
- Preserve typed result values. Do not flatten timestamps, numerics, nulls, or binary values into
  display strings at the backend boundary.
- Treat client-side SQL checks as a safety layer, not as a replacement for IAM, database roles,
  Kubernetes RBAC, TLS, or network policy.
- Keep mocked and planned Codex behavior visibly distinct from a working backend integration. Follow
  [docs/codex-privacy.md](docs/codex-privacy.md) for future assistant work.

## Verification

Run the full local verification before opening a pull request:

```bash
swift format --in-place --recursive Sources Tests
swift format lint --recursive --strict Sources Tests
swift test
npm --prefix backend run format:check
npm --prefix backend run typecheck
npm --prefix backend test
npm --prefix backend audit --audit-level=low
./Scripts/build-app.sh release
git diff --check
```

Live PostgreSQL, MySQL, and Cloud SQL integration tests are opt-in because they require an explicitly
configured test database. See [docs/backend-architecture.md](docs/backend-architecture.md) for their
environment variables. Tests must not create, modify, or delete remote resources unless the test
documents that behavior and uses an isolated disposable environment.

For visible UI changes:

- check Korean and English;
- check light and dark appearance;
- verify keyboard focus and pointer behavior; and
- attach sanitized screenshots that contain no private infrastructure or data.

For temporal or export changes, review [docs/timezone-design.md](docs/timezone-design.md). For
connection or credential changes, review [docs/threat-model.ko.md](docs/threat-model.ko.md).

## Commits and pull requests

Use a concise Conventional Commit subject. Korean or English is acceptable; keep one language
consistent within a commit.

Examples:

```text
feat: 결과 컬럼 자동 맞춤을 추가
fix: preserve zone-less PostgreSQL timestamps
docs: 공개 릴리스 절차를 정리
```

A pull request should explain:

- the user-visible problem;
- the chosen approach and important tradeoffs;
- how it was verified;
- security or privacy impact; and
- intentionally deferred work.

By submitting a contribution, you agree that it is licensed under the repository's
[Apache License 2.0](LICENSE), as described by section 5 of that license.
