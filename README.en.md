<p align="right"><a href="README.md">한국어</a></p>

# Solnari

**A native, open-source macOS database tool that I am building for daily use.**

Solnari began when my one-year DataGrip subscription ended and I needed a database tool I could
keep using myself. Building it made me appreciate how much depth and polish established database
tools contain. The project is therefore growing beyond a quick replacement into an open-source
database workspace that feels at home on macOS and is built to last.

It starts with comfortable local database work, while treating private Cloud SQL, SSH, and
Kubernetes connections—and the execution boundary between humans and agents—as first-class design
problems.

> [!IMPORTANT]
> Solnari is under active early development. This document separates what works today from the
> direction being implemented. It does not claim full DataGrip feature parity or a finished
> organization policy engine.

## Why Solnari exists

The first goal was straightforward: retain the everyday workflow of writing queries, exploring
tables, and copying results in useful formats after an existing tool subscription ended. Working
through connection paths, result types, time zones, character sets, and tunnel lifecycles revealed
how deep a dependable database tool needs to be.

Solnari now aims to be:

- useful for real, everyday database work;
- explicit about how it reaches local, cloud, and private databases;
- careful with credentials and session lifecycles; and
- human-controlled when an agent proposes SQL.

## Available today

- Live PostgreSQL, MySQL, and SQLite connection testing and sessions
- Schema, table, and view discovery with dynamic query execution
- Table and view metadata for columns, defaults, nullability, charset/collation, comments, indexes,
  and constraints
- Safely quoted `SELECT` generation, read-only data opening, and qualified-name copying
- Direct TCP, Google's official Cloud SQL Connector, SSH tunnel, and existing-resource or relay Kubernetes paths
- ADC-based Cloud SQL automatic IAM authentication, engine-aware user suggestions, and project discovery
- Saved-connection editing and reconnecting, with confirmation before deletion
- Local connection definitions and a user-only AES-GCM credential vault
- Multi-tab SQL editor and resizable editor/result layout
- AppKit result grid with resizable columns and multi-row selection
- Copy and export to CSV, TSV, JSON, JSON Lines, Markdown, and SQL `INSERT`
- Character-set and collation configuration UI
- Display time zones that preserve zoned and zone-less timestamp semantics
- Runtime Korean/English switching and native light/dark appearance
- Single-instance lifecycle with session cleanup on quit, screen lock, sleep, and user switching
- Conservative SQL preflight and database-session write protection for read-only profiles
- A Codex UI prototype with explicit proposal-to-editor handoff

### Connection matrix

| Database | Direct | Cloud SQL | SSH | Kubernetes |
| --- | --- | --- | --- | --- |
| PostgreSQL | Available | Available | Available | Existing resource · relay |
| MySQL | Available | Available | Available | Existing resource · relay |
| SQLite | File | Not applicable | Not applicable | Not applicable |

Kubernetes prefers a pre-existing Service or Pod using minimum `pods/portforward` access. The
temporary relay is an explicitly selected experimental mode and additionally requires Pod lifecycle
permissions.

## Product direction

Solnari will preserve general-purpose database usability while allowing organizations to enforce
approved targets and execution policies when required.

1. **Explicit private connectivity** without silent public or direct fallback.
2. **Short-lived sessions** whose tunnels, connections, and temporary credentials are cleaned up.
3. **Inspectable organization policy** that separates transport, security posture, and DB access.
4. **Human-controlled agent execution** where proposals never become automatic SQL execution.
5. **A privacy-preserving desktop workflow** that does not log or telemeter credentials, SQL,
   schema, results, or agent conversations.

See the [backend architecture](docs/backend-architecture.md),
[connection paths](docs/connection-paths.md),
[security-first connection architecture](docs/security-first-connection-architecture.ko.md), and
[threat model](docs/threat-model.ko.md).

## In progress

- Versioned and eventually signed organization policy profiles
- Idle/max session lifetime and orphan recovery after forced termination
- A dialect-aware SQL parser, consistent timeouts, query cancellation, and result/export limits
- Production write approval and one-time write capabilities
- Codex App Server and policy-limited MCP capabilities
- Developer ID signing, notarization, and GitHub Release automation
- Table data editing and broader object exploration

## Build and run

Requirements: macOS 14 or newer, a Swift 6.1-compatible toolchain, and Node.js 24 with npm for
source builds. The built app bundles its Node runtime.

The bundled Node backend uses Google's official Auth Library and Cloud SQL Connector for discovery,
IAM authentication, and Cloud SQL sessions. Solnari never executes `gcloud` or an external
`cloud-sql-proxy`. The current SSH and Kubernetes paths still require OpenSSH and `kubectl`.

```bash
git clone https://github.com/dreamyoungs/solnari.git
cd solnari
./Scripts/run-app.sh
```

Build a local Release configuration app:

```bash
./Scripts/build-app.sh release
```

`run-app.sh` installs the development bundle at `~/Applications/Solnari Development.app` before
launching it, avoiding macOS Documents-folder access prompts caused by running a bundle inside a
repository. The bundle uses the [Solnari flower icon](Sources/Solnari/Resources/SolnariIcon.png) and
a certificate-free local development signature. Public releases will require Developer ID signing
and Apple notarization.

## Verify

```bash
swift format lint --recursive --strict Sources Tests
swift test
npm --prefix backend run typecheck
npm --prefix backend test
npm --prefix backend audit --audit-level=low
./Scripts/build-app.sh release
git diff --check
```

Live PostgreSQL and MySQL tests run only when their test-server environment variables are present.
SQLite and isolated fake-CLI transport tests run by default.

## Security and privacy

Connection definitions stay in local app storage. Database passwords use a local AES-GCM vault with
a separate 256-bit key and user-only directory/file permissions. Automatic unlock keeps that key in
the same macOS user domain, so this protects against plaintext and accidental disclosure but not a
malicious process already running as the same user. Automatic IAM authentication neither requests
a database password nor passes one to helper arguments. Helper commands use executable and argument
arrays, and private connection failures never trigger an automatic transport fallback.

See [SECURITY.md](SECURITY.md) for current limitations and private vulnerability reporting. Never
put credentials, private endpoints, production SQL, or customer data in a public issue.

## Contributing

Bug fixes, database-specific verification, UX proposals, and security reviews are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before preparing a change.

## License

Solnari is available under the [Apache License 2.0](LICENSE).
