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
proxy's `--auto-iam-authn` flag. In automatic IAM mode, Solnari derives the engine-specific database
username from the ADC principal when possible and never asks for, passes, or stores a database
password. PostgreSQL uses the full user email (or a service-account email without the
`.gserviceaccount.com` suffix); MySQL uses the portion before `@`. If an older user ADC file does
not expose its principal, Solnari suggests the active gcloud account and asks the user to verify
that it matches ADC. Built-in database authentication keeps the password in Keychain.

After a project ID is entered, Solnari can use an ADC access token in memory to query the Cloud SQL
Admin API for supported PostgreSQL and MySQL instances and their databases. The token is sent only
in the authorization header, is never added to a URL or persisted, and manual region, instance, and
database entry remains available when discovery is unavailable or intentionally not permitted.
Discovery currently obtains the in-memory ADC access token through the installed `gcloud` CLI.

Install `cloud-sql-proxy` and authenticate Application Default Credentials before connecting. Use
`SOLNARI_CLOUD_SQL_PROXY` to point Solnari at a nonstandard binary location.

## SSH tunnel

Solnari runs the system OpenSSH client in batch mode with `ExitOnForwardFailure=yes`. Database and
SSH usernames are separate profile fields. Authentication uses `~/.ssh`, SSH configuration, and
the system agent; Solnari does not copy or persist private keys. Set `SOLNARI_SSH` only when a
nonstandard SSH executable is required.

## Kubernetes

The preferred Kubernetes mode opens `kubectl port-forward` to an explicitly selected, existing
Service or Pod. Solnari passes the context, namespace, resource kind, resource name, remote port,
and `--address=127.0.0.1` as separate arguments. It creates, changes, and deletes no cluster
resource in this mode. The kubeconfig identity needs resource discovery access and
`pods/portforward` for the selected target.

### Experimental temporary relay

For databases reachable from a Kubernetes cluster but not from the Mac, Solnari:

1. creates a uniquely named, non-restarting relay Pod in the explicitly selected context and namespace;
2. waits for the Pod to become ready;
3. runs `kubectl port-forward` on a random loopback port;
4. connects the database driver through that endpoint;
5. terminates port-forward and deletes the relay Pod on test completion, disconnect, or failure.

The temporary relay is explicitly labeled experimental. Its image is visible and editable in the
connection form. The kubeconfig identity must be
allowed to create, watch, port-forward, and delete Pods in the namespace. Set `SOLNARI_KUBECTL` for
a nonstandard binary path.

## Failure and cleanup rules

Helper processes belong to one connection UUID. A failed readiness check stops the process and
removes any Kubernetes relay. Saving remains fail-closed: Solnari persists the profile only after
the path, database metadata query, and schema discovery have all succeeded. Helper stderr is
bounded before it is shown as an error, and credentials are excluded from commands and logs.
