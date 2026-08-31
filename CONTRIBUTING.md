# Contributing to Solnari

Thank you for helping make Solnari a thoughtful, approachable database client.

The project is in an early backend-integration phase. Small, focused changes are easier to review than broad rewrites while database and transport contracts continue to evolve.

## Development setup

You need macOS 14 or newer and a Swift 6.1-compatible toolchain.

```bash
swift build
swift test
swift run Solnari
```

Swift Package Manager resolves PostgresNIO and the test-only Swift Testing package.

## Before opening a pull request

Please:

1. run `swift build`;
2. run `swift test`;
3. run `git diff --check`;
4. exercise affected UI in both English and Korean when text changes;
5. check light and dark appearances when colors or surfaces change;
6. include screenshots for visible UI changes;
7. keep credentials, tokens, private hostnames, and production data out of code and fixtures.

If a change affects temporal values or export behavior, review [docs/timezone-design.md](docs/timezone-design.md) and describe how canonical and displayed values are preserved.

If a change affects the assistant, App Server transport, diagnostics, analytics, or crash reporting, review [docs/codex-privacy.md](docs/codex-privacy.md) and verify that conversation content cannot be persisted or logged.

## Design boundaries

- Keep database adapters independent from connection transports.
- Keep connection-profile persistence separate from Keychain-backed secrets.
- Do not flatten typed result values into display strings at the backend boundary.
- Treat credentials as local secrets and never expose them to Codex context.
- Keep Codex threads ephemeral and fail closed if the App Server does not confirm an in-memory, pathless thread.
- Never record prompts, responses, SQL, schema data, or result values in logs or telemetry.
- Prefer native SwiftUI patterns, with focused AppKit bridges where macOS behavior or large-data performance requires them.
- Keep mocked behavior clearly distinguishable from completed backend integration.

## Commits and pull requests

Use a concise, imperative commit subject that explains the user-facing change. A pull request should describe:

- the problem being solved;
- the chosen approach and important tradeoffs;
- how the change was verified;
- any intentionally deferred work.

Constructive discussion is welcome. Please optimize for clarity, technical evidence, and respect for future maintainers.
