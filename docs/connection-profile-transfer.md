# Connection profile transfer format

Solnari exports connection definitions as UTF-8 JSON. The format is intended for backup and transfer,
not for credential migration.

## Security boundary

Version 1 never contains passwords, credential-vault references, encryption keys, OAuth/IAM tokens,
internal profile UUIDs, live connection state, latency, or server session metadata. There is no option
to include those values.

An export can still reveal sensitive infrastructure information, including hosts, ports, usernames,
database names, Cloud project/region/instance identifiers, SSH bastions, and Kubernetes contexts. Treat
the file as sensitive configuration and share it only through an appropriate secure channel.

Every imported connection receives a new internal UUID and starts disconnected. Credential-based
connections require password entry or IAM reauthentication before they can connect; SQLite file
connections do not use a database credential.

## Version 1 envelope

```json
{
  "format": "com.dreamyoungs.solnari.connection-profiles",
  "version": 1,
  "connections": [
    {
      "name": "Local example",
      "database": "example",
      "engine": "PostgreSQL",
      "transport": "Direct",
      "host": "localhost",
      "port": 5432,
      "username": "developer",
      "requiresTLS": false,
      "clientEncoding": "Automatic",
      "securityPolicy": "Local development",
      "accessLevel": "Read / Write"
    }
  ]
}
```

Connection fields are explicit and transport-specific configuration is nested under `cloudSQL`, `ssh`,
or `kubernetes`. Optional text/collation settings may be omitted. Unknown fields, unsupported versions,
invalid transport combinations, and invalid connection settings cause the complete import to fail; no
subset is applied.
