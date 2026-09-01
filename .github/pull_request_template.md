## What changed

Describe the user-visible problem and the chosen approach.

## Verification

- [ ] swift format lint --recursive --strict Sources Tests
- [ ] swift test
- [ ] npm --prefix backend run format:check
- [ ] npm --prefix backend run typecheck
- [ ] npm --prefix backend test
- [ ] npm --prefix backend audit --audit-level=low
- [ ] git diff --check

Add focused manual checks or sanitized screenshots where relevant.

## Security and privacy

- [ ] No credentials, private infrastructure identifiers, production SQL, schema, results, or customer data are included.
- [ ] Connection, credential, logging, or Codex boundary changes are explained below.
- [ ] New external processes, network calls, permissions, or fallback paths are documented.

Security/privacy impact:

## Deferred work

List intentionally deferred follow-ups or write None.
