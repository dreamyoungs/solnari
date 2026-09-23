import { describe, expect, it, vi } from "vitest";
import { DatabaseSessions } from "../src/database-sessions.js";

const profileID = "00000000-0000-4000-8000-000000000001";
const command = (name: string) => ({
  command: name,
  rowCount: null,
  fields: [],
  rows: [],
});

function sessionWith(query: ReturnType<typeof vi.fn>) {
  const sessions = new DatabaseSessions();
  // 실제 실행 경로를 검사하되 Cloud 인증이나 운영 DB에 접속하지 않는다.
  const state = sessions as unknown as {
    sessions: Map<string, unknown>;
  };
  state.sessions.set(profileID, {
    engine: "PostgreSQL",
    client: {
      query,
      getTransactionStatus: () => "I",
      on: vi.fn(),
      removeListener: vi.fn(),
    },
  });
  return sessions;
}

describe("PostgreSQL multi-statement execution", () => {
  it("keeps success when individually small cells exceed the transport budget together", async () => {
    const query = vi.fn().mockResolvedValue({
      command: "SELECT",
      rowCount: 10,
      fields: [{ name: "text", dataTypeID: 25 }],
      rows: Array.from({ length: 10 }, () => ["x".repeat(800_000)]),
    });
    expect(
      await sessionWith(query).execute({
        profileID,
        sql: "SELECT large_values",
      }),
    ).toMatchObject({
      columns: [],
      rows: [],
      report: { resultNotice: expect.stringContaining("Do not rerun") },
    });
    expect(query).toHaveBeenCalledTimes(1);
  });
  it("does not report a committed DDL transaction as a database failure", async () => {
    const query = vi
      .fn()
      .mockResolvedValue([
        command("BEGIN"),
        command("CREATE"),
        command("ALTER"),
        command("COMMIT"),
      ]);
    const result = await sessionWith(query).execute({
      profileID,
      sql: "BEGIN; CREATE TABLE example(id int); ALTER TABLE example ADD COLUMN title text; COMMIT;",
    });
    expect(result).toMatchObject({
      columns: [],
      rows: [],
      report: {
        transactionState: "committed",
        commands: [
          { tag: "BEGIN" },
          { tag: "CREATE" },
          { tag: "ALTER" },
          { tag: "COMMIT" },
        ],
      },
    });
    expect(query).toHaveBeenCalledTimes(1);
  });

  it("keeps the last row result when COMMIT follows SELECT", async () => {
    const query = vi.fn().mockResolvedValue([
      command("BEGIN"),
      {
        command: "SELECT",
        rowCount: 1,
        fields: [{ name: "value", dataTypeID: 23 }],
        rows: [[42]],
      },
      command("COMMIT"),
    ]);
    expect(
      await sessionWith(query).execute({
        profileID,
        sql: "BEGIN; SELECT 42 AS value; COMMIT;",
      }),
    ).toMatchObject({
      columns: ["value"],
      rows: [[{ kind: "integer", value: "42" }]],
    });
  });

  it("accepts an explicit rollback response", async () => {
    const query = vi
      .fn()
      .mockResolvedValue([command("BEGIN"), command("ROLLBACK")]);
    expect(
      await sessionWith(query).execute({ profileID, sql: "BEGIN; ROLLBACK;" }),
    ).toMatchObject({
      columns: [],
      rows: [],
      report: { transactionState: "rolledBack" },
    });
  });

  it("preserves a real database failure without exposing raw SQL in the RPC error", async () => {
    const query = vi
      .fn()
      .mockRejectedValue(
        Object.assign(new Error("private SQL"), { code: "42601" }),
      );
    await expect(
      sessionWith(query).execute({ profileID, sql: "invalid" }),
    ).rejects.toMatchObject({
      diagnosticCode: "QUERY_SQLSTATE_42601",
      message: "The database reported a SQL syntax error.",
    });
  });

  it("does not turn a post-execution display limit into a database failure", async () => {
    const query = vi.fn().mockResolvedValue({
      command: "INSERT",
      rowCount: 10001,
      fields: [{ name: "id", dataTypeID: 23 }],
      rows: Array.from({ length: 10001 }, () => [1]),
    });
    const result = await sessionWith(query).execute({
      profileID,
      sql: "INSERT INTO example SELECT 1 RETURNING id",
    });
    expect(result).toMatchObject({
      columns: [],
      rows: [],
      report: {
        commands: [{ tag: "INSERT", affectedRows: 10001 }],
        resultNotice: expect.stringContaining("Do not rerun"),
      },
    });
    expect(query).toHaveBeenCalledTimes(1);
  });
});
