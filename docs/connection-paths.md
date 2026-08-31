# Connection paths

Database engines and network paths are independent in Solnari. PostgreSQL and MySQL support all
network paths below. SQLite opens a local file directly and does not use a network transport.

## Direct

Solnari connects to the configured host and port with the selected native SwiftNIO driver. TLS is
optional in the profile. SQLite instead opens the selected absolute file path through SQLiteNIO.

## Google Cloud SQL

Solnari runs Cloud SQL Auth Proxy v2 on a random loopback port and connects the database driver to
that endpoint. The instance is addressed as `project:region:instance`. Application Default
Credentials are resolved by the proxy; optional automatic IAM database authentication adds the
proxy's `--auto-iam-authn` flag. The database password, when used, stays in Keychain and is never
passed to the proxy.

Install `cloud-sql-proxy` and authenticate Application Default Credentials before connecting. Use
`SOLNARI_CLOUD_SQL_PROXY` to point Solnari at a nonstandard binary location.

## SSH tunnel

Solnari runs the system OpenSSH client in batch mode with `ExitOnForwardFailure=yes`. Database and
SSH usernames are separate profile fields. Authentication uses `~/.ssh`, SSH configuration, and
the system agent; Solnari does not copy or persist private keys. Set `SOLNARI_SSH` only when a
nonstandard SSH executable is required.

## Kubernetes relay

For databases reachable from a Kubernetes cluster but not from the Mac, Solnari:

1. creates a uniquely named, non-restarting relay Pod in the explicitly selected context and namespace;
2. waits for the Pod to become ready;
3. runs `kubectl port-forward` on a random loopback port;
4. connects the database driver through that endpoint;
5. terminates port-forward and deletes the relay Pod on test completion, disconnect, or failure.

The relay image is visible and editable in the connection form. The kubeconfig identity must be
allowed to create, watch, port-forward, and delete Pods in the namespace. Set `SOLNARI_KUBECTL` for
a nonstandard binary path.

## Failure and cleanup rules

Helper processes belong to one connection UUID. A failed readiness check stops the process and
removes any Kubernetes relay. Saving remains fail-closed: Solnari persists the profile only after
the path, database metadata query, and schema discovery have all succeeded. Helper stderr is
bounded before it is shown as an error, and credentials are excluded from commands and logs.
