import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { DatabaseSessions } from "../src/database-sessions.js";

const environment = process.env;
const liveConfiguration = {
  project: environment.SOLNARI_TEST_CLOUD_SQL_PROJECT,
  region: environment.SOLNARI_TEST_CLOUD_SQL_REGION,
  instance: environment.SOLNARI_TEST_CLOUD_SQL_INSTANCE,
  database: environment.SOLNARI_TEST_CLOUD_SQL_DATABASE,
  user: environment.SOLNARI_TEST_CLOUD_SQL_USER,
  engine: environment.SOLNARI_TEST_CLOUD_SQL_ENGINE,
};
const isConfigured =
  Object.values(liveConfiguration).every(
    (value) => value !== undefined && value !== "",
  ) &&
  (liveConfiguration.engine === "PostgreSQL" ||
    liveConfiguration.engine === "MySQL");

describe.skipIf(!isConfigured)("Cloud SQL IAM integration", () => {
  it("connects, discovers schema metadata, and executes typed reads without a password", async () => {
    const sessions = new DatabaseSessions();
    const profileID = randomUUID();
    try {
      const metadata = await sessions.connect({
        profileID,
        engine: liveConfiguration.engine,
        instanceConnectionName:
          `${liveConfiguration.project}:${liveConfiguration.region}:` +
          liveConfiguration.instance,
        user: liveConfiguration.user,
        database: liveConfiguration.database,
        useIAM: true,
        ipType: "PUBLIC",
        readOnly: true,
      });
      expect(metadata).toBeTruthy();

      const schema = (await sessions.schema({ profileID })) as {
        schemas: string[];
        objects: Array<{
          schema: string;
          name: string;
          kind: "table" | "view" | "materializedView";
          columnCount: number;
        }>;
      };
      expect(schema.schemas.length).toBeGreaterThan(0);
      expect(schema.objects.length).toBeGreaterThan(0);

      const object =
        schema.objects.find((item) => item.kind === "table") ??
        schema.objects[0];
      expect(object).toBeDefined();
      if (object !== undefined) {
        const details = (await sessions.details({ profileID, object })) as {
          columns: unknown[];
          indexes: unknown[];
          constraints: unknown[];
        };
        expect(details.columns.length).toBeGreaterThan(0);
      }

      const result = (await sessions.execute({
        profileID,
        sql:
          liveConfiguration.engine === "PostgreSQL"
            ? "SELECT now() AS server_time, TIMESTAMP '2026-08-31 12:34:56.123456' AS local_time"
            : "SELECT CURRENT_TIMESTAMP(6) AS server_time, CAST('2026-08-31 12:34:56.123456' AS DATETIME(6)) AS local_time",
      })) as { rows: Array<Array<{ kind: string }>> };
      expect(result.rows[0]?.map((cell) => cell.kind)).toEqual([
        "instant",
        "localTimestamp",
      ]);
    } finally {
      await sessions.disconnectAll();
    }
  }, 60_000);
});
