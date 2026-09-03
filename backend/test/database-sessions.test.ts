import { describe, expect, it } from "vitest";
import {
  DatabaseSessions,
  encodeMySQLCell,
  encodePostgresCell,
} from "../src/database-sessions.js";

describe("database result encoding", () => {
  it("treats cancelling an absent connection test as idempotent", async () => {
    const sessions = new DatabaseSessions();

    await expect(
      sessions.cancelTestConnection({
        profileID: "00000000-0000-4000-8000-000000000001",
      }),
    ).resolves.toEqual({ disconnected: true });
  });

  it("keeps PostgreSQL zoned and zone-less timestamps distinct", () => {
    const instant = new Date("2026-08-31T12:34:56.123Z");

    expect(encodePostgresCell(instant, 1184)).toEqual({
      kind: "instant",
      value: "2026-08-31T12:34:56.123Z",
    });
    expect(encodePostgresCell("2026-08-31 12:34:56.123456", 1114)).toEqual({
      kind: "localTimestamp",
      value: "2026-08-31 12:34:56.123456",
    });
    expect(encodePostgresCell("2026-08-31", 1082)).toEqual({
      kind: "date",
      value: "2026-08-31",
    });
  });

  it("encodes MySQL TIMESTAMP as UTC and DATETIME without a zone", () => {
    expect(
      encodeMySQLCell("2026-08-31 12:34:56.123456", { type: 7 } as never),
    ).toEqual({ kind: "instant", value: "2026-08-31T12:34:56.123456Z" });
    expect(
      encodeMySQLCell("2026-08-31 12:34:56.123456", { type: 12 } as never),
    ).toEqual({ kind: "localTimestamp", value: "2026-08-31 12:34:56.123456" });
  });

  it("preserves 64-bit integers as decimal text across JSON-RPC", () => {
    expect(encodePostgresCell("9223372036854775807", 20)).toEqual({
      kind: "integer",
      value: "9223372036854775807",
    });
    expect(
      encodeMySQLCell("9223372036854775807", { type: 8 } as never),
    ).toEqual({ kind: "integer", value: "9223372036854775807" });
  });

  it("serializes structured JSON cells instead of displaying object Object", () => {
    const value = { title: "Solnari", nested: { enabled: true } };

    expect(encodePostgresCell(value, 3802)).toEqual({
      kind: "text",
      value: '{"title":"Solnari","nested":{"enabled":true}}',
    });
    expect(encodeMySQLCell(value, undefined)).toEqual({
      kind: "text",
      value: '{"title":"Solnari","nested":{"enabled":true}}',
    });
  });
});
