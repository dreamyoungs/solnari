import pg from "pg";
import { describe, expect, it } from "vitest";
import { DatabaseSessions } from "../src/database-sessions.js";

// 별도로 만든 폐기 가능한 로컬 DB에서만 활성화한다. 임시 테이블만 생성한다.
describe.skipIf(!process.env.SOLNARI_TEST_POSTGRES_LOCAL_URL)(
  "PostgreSQL execution protocol",
  () => {
    it("reports commit, notices, failed transaction and rollback from a real server", async () => {
      const client = new pg.Client({
        connectionString: process.env.SOLNARI_TEST_POSTGRES_LOCAL_URL!,
      });
      await client.connect();
      const sessions = new DatabaseSessions();
      const profileID = "00000000-0000-4000-8000-000000000001";
      (sessions as unknown as { sessions: Map<string, unknown> }).sessions.set(
        profileID,
        {
          engine: "PostgreSQL",
          client,
        },
      );
      try {
        const committed = await sessions.execute({
          profileID,
          sql: "BEGIN; CREATE TEMP TABLE solnari_regression(id integer); INSERT INTO solnari_regression VALUES (7); SELECT * FROM solnari_regression; COMMIT;",
        });
        expect(committed).toMatchObject({
          columns: ["id"],
          rows: [[{ kind: "integer", value: "7" }]],
          report: { transactionState: "committed" },
        });
        const notice = await sessions.execute({
          profileID,
          sql: "DO $$ BEGIN RAISE NOTICE 'synthetic notice'; END $$;",
        });
        expect(notice).toMatchObject({
          report: {
            notices: [{ severity: "NOTICE", message: "synthetic notice" }],
          },
        });
        await expect(
          sessions.execute({
            profileID,
            sql: "BEGIN; INSERT INTO solnari_regression VALUES (8); SELECT * FROM solnari_missing_table; COMMIT;",
          }),
        ).rejects.toMatchObject({
          diagnosticCode: "QUERY_SQLSTATE_42P01",
          queryDetails: {
            sqlState: "42P01",
            transactionState: "failedTransaction",
            position: expect.any(Number),
            statementIndex: 3,
          },
        });
        const rolledBack = await sessions.execute({
          profileID,
          sql: "ROLLBACK;",
        });
        expect(rolledBack).toMatchObject({
          report: { transactionState: "rolledBack" },
        });
        const count = await client.query(
          "SELECT count(*)::int AS count FROM solnari_regression",
        );
        expect(count.rows).toEqual([{ count: 1 }]);
      } finally {
        await client.end();
      }
    });
  },
);
