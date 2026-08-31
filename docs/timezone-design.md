# Time zone handling

Time zone support is a core result-model requirement, not a presentation-only formatter.

## Product behavior

Solnari should let users select a display time zone at four levels, with the more specific setting taking precedence:

1. column override;
2. connection profile;
3. workspace;
4. system time zone.

The result grid should support absolute local time, ISO 8601, UTC, and relative-time presentations without changing the stored query value. The active display time zone must be visible near the result grid whenever it differs from the database or system time zone.

## Typed result contract

Database adapters must not flatten temporal values into untyped display strings. A temporal cell should preserve at least:

- the database type;
- the original value returned by the driver;
- a canonical instant when the source type identifies one;
- the source offset or named time zone when available;
- fractional-second precision;
- whether the value is date-only, time-only, zoned, or zone-less.

The Swift frontend performs display formatting from this typed value and the selected IANA time-zone identifier, such as `Asia/Seoul` or `America/Los_Angeles`.

## Zoned and zone-less timestamps

`timestamp with time zone`/`timestamptz` values identify an instant and can be safely rendered in another time zone.

A zone-less `timestamp`, `datetime`, or similar value must not be converted automatically because it does not identify an instant. Solnari should display it as stored unless one of the following supplies an assumed source time zone:

- adapter metadata with unambiguous database semantics;
- a connection-level assumption;
- a column rule in `.solnari/catalog.yml`;
- an explicit user choice.

When Solnari applies an assumed time zone, the grid should show that fact in the column metadata instead of silently converting the value.

## Database sessions

Adapters may expose session-time-zone controls where the database supports them, but the display setting and session setting remain separate concepts. Changing how a value is displayed must not unexpectedly alter query semantics.

- PostgreSQL: inspect `TimeZone` and distinguish `timestamp` from `timestamptz`.
- MySQL: Solnari sets the wire session to `+00:00` so `TIMESTAMP` values decode as canonical
  instants without depending on installed named-zone tables. `DATETIME` remains a zone-less wall
  clock value. The user's display time zone is applied only after typed decoding.
- SQLite: treat stored text/numeric date values according to the expression and catalog metadata; SQLite has no intrinsic per-value time-zone type.

## Export and copy

Copy/export must offer two explicit policies:

- **Canonical** (default): ISO 8601 with offset or `Z` for instants; zone-less values remain zone-less.
- **As displayed**: export values formatted in the currently selected display time zone.

JSON and JSON Lines should preserve `null` and numeric types and emit temporal values as ISO 8601 strings. CSV, TSV, Markdown, and SQL export must never discard the offset from a zoned value without an explicit user selection.

## Safety and verification

Tests must cover:

- daylight-saving gaps and overlaps;
- fractional seconds;
- date-only and time-only values;
- system time-zone changes while the app is running;
- mixed temporal types in one result set;
- canonical and displayed export modes;
- ambiguous zone-less timestamps with and without a configured assumption.

This design also applies to schema previews, data editors, query history, Codex context, and generated SQL parameters.
