import {
  AuthTypes,
  Connector,
  IpAddressTypes,
} from "@google-cloud/cloud-sql-connector";
import { GoogleAuth } from "google-auth-library";
import mysql from "mysql2/promise";
import pg from "pg";
import { z } from "zod";
import { RPCError } from "./protocol.js";

const connectionSchema = z.object({
  profileID: z.string().uuid(),
  engine: z.enum(["PostgreSQL", "MySQL"]),
  instanceConnectionName: z
    .string()
    .regex(/^[a-z][a-z0-9-]{4,28}[a-z0-9]:[a-z0-9-]+:[a-zA-Z0-9_-]+$/),
  user: z.string().min(1).max(256),
  database: z.string().min(1).max(256),
  password: z.string().max(4096).optional(),
  useIAM: z.boolean(),
  ipType: z.enum(["PUBLIC", "PRIVATE", "PSC"]).default("PUBLIC"),
  readOnly: z.boolean().default(false),
});

const profileSchema = z.object({ profileID: z.string().uuid() });
const executeSchema = profileSchema.extend({
  sql: z.string().min(1).max(1_048_576),
});
const objectSchema = profileSchema.extend({
  object: z.object({
    schema: z.string().min(1).max(256),
    name: z.string().min(1).max(256),
    kind: z.enum(["table", "view", "materializedView", "function"]),
    columnCount: z.number().int().nonnegative(),
  }),
});

type PostgresSession = {
  engine: "PostgreSQL";
  connector: Connector;
  client: pg.Client;
};

type MySQLSession = {
  engine: "MySQL";
  connector: Connector;
  client: mysql.Connection;
};

type Session = PostgresSession | MySQLSession;
type ConnectionTestAttempt = {
  cancelled: boolean;
  connector?: Connector;
  closeDatabase?: () => Promise<unknown>;
};
const maximumResultRows = 10_000;
const maximumResultColumns = 1_000;
const maximumCellBytes = 1_048_576;

const postgresTypes = new pg.TypeOverrides();
for (const type of [20, 1082, 1114, 1700]) {
  postgresTypes.setTypeParser(type, (value) => value);
}

export class DatabaseSessions {
  private readonly sessions = new Map<string, Session>();
  private readonly connectionTests = new Map<string, ConnectionTestAttempt>();

  async testConnection(raw: unknown): Promise<unknown> {
    const input = connectionSchema.parse(raw);
    await this.cancelTestConnection({ profileID: input.profileID });
    const attempt: ConnectionTestAttempt = { cancelled: false };
    this.connectionTests.set(input.profileID, attempt);
    try {
      const { session, metadata } = await this.open(input, attempt);
      await closeSession(session);
      if (attempt.cancelled) throw connectionTestCancelled();
      return metadata;
    } finally {
      if (this.connectionTests.get(input.profileID) === attempt) {
        this.connectionTests.delete(input.profileID);
      }
    }
  }

  async cancelTestConnection(raw: unknown): Promise<{ disconnected: true }> {
    const { profileID } = profileSchema.parse(raw);
    const attempt = this.connectionTests.get(profileID);
    if (attempt !== undefined) {
      attempt.cancelled = true;
      attempt.connector?.close();
      try {
        await attempt.closeDatabase?.();
      } catch {
        // The in-flight connection attempt owns final cleanup.
      }
    }
    return { disconnected: true };
  }

  async connect(raw: unknown): Promise<unknown> {
    const input = connectionSchema.parse(raw);
    await this.disconnect({ profileID: input.profileID });
    const { session, metadata } = await this.open(input);
    this.sessions.set(input.profileID, session);
    return metadata;
  }

  async disconnect(raw: unknown): Promise<{ disconnected: true }> {
    const { profileID } = profileSchema.parse(raw);
    const session = this.sessions.get(profileID);
    if (session !== undefined) {
      this.sessions.delete(profileID);
      await closeSession(session);
    }
    return { disconnected: true };
  }

  async disconnectAll(): Promise<{ disconnected: true }> {
    await Promise.all(
      [...this.connectionTests.keys()].map((profileID) =>
        this.cancelTestConnection({ profileID }),
      ),
    );
    const sessions = [...this.sessions.values()];
    this.sessions.clear();
    await Promise.all(sessions.map(closeSession));
    return { disconnected: true };
  }

  async schema(raw: unknown): Promise<unknown> {
    const session = this.requiredSession(raw);
    if (session.engine === "PostgreSQL") {
      const schemaResult = await session.client.query<{ schema: string }>(
        `SELECT namespace.nspname AS schema
           FROM pg_catalog.pg_namespace AS namespace
          WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
            AND namespace.nspname NOT LIKE 'pg_toast%'
          ORDER BY namespace.nspname`,
      );
      const result = await session.client.query<{
        schema: string;
        name: string;
        kind: "table" | "view" | "materializedView";
        column_count: number | string;
      }>(`SELECT namespace.nspname AS schema,
                relation.relname AS name,
                CASE relation.relkind
                  WHEN 'r' THEN 'table'
                  WHEN 'p' THEN 'table'
                  WHEN 'v' THEN 'view'
                  WHEN 'm' THEN 'materializedView'
                END AS kind,
                COUNT(attribute.attnum)::integer AS column_count
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         LEFT JOIN pg_catalog.pg_attribute AS attribute
           ON attribute.attrelid = relation.oid
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
         WHERE relation.relkind IN ('r', 'p', 'v', 'm')
           AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
           AND namespace.nspname NOT LIKE 'pg_toast%'
         GROUP BY namespace.nspname, relation.relname, relation.relkind
         ORDER BY namespace.nspname, relation.relname`);
      return {
        schemas: schemaResult.rows.map((row) => row.schema),
        objects: result.rows.map((row) => ({
          schema: row.schema,
          name: row.name,
          kind: row.kind,
          columnCount: Number(row.column_count),
        })),
      };
    }

    const [schemaRows] = await session.client.query<mysql.RowDataPacket[]>(
      "SELECT DATABASE() AS schema_name",
    );
    const [rows] = await session.client.query<mysql.RowDataPacket[]>(
      `SELECT table_schema AS \`schema\`,
              table_name AS name,
              CASE table_type WHEN 'VIEW' THEN 'view' ELSE 'table' END AS kind,
              (SELECT COUNT(*)
                 FROM information_schema.columns AS column_record
                WHERE column_record.table_schema = table_record.table_schema
                  AND column_record.table_name = table_record.table_name) AS column_count
         FROM information_schema.tables AS table_record
        WHERE table_schema = DATABASE()
        ORDER BY table_name`,
    );
    return {
      schemas: schemaRows
        .map((row) => row.schema_name)
        .filter((schema): schema is string => typeof schema === "string"),
      objects: rows.map((row) => ({
        schema: String(row.schema),
        name: String(row.name),
        kind: String(row.kind),
        columnCount: Number(row.column_count),
      })),
    };
  }

  async details(raw: unknown): Promise<unknown> {
    const { profileID, object } = objectSchema.parse(raw);
    const session = this.sessions.get(profileID);
    if (session === undefined) throw notConnected();
    if (session.engine === "PostgreSQL") {
      return this.postgresDetails(session.client, object);
    }
    return this.mysqlDetails(session.client, object);
  }

  async execute(raw: unknown): Promise<unknown> {
    const { profileID, sql } = executeSchema.parse(raw);
    const session = this.sessions.get(profileID);
    if (session === undefined) throw notConnected();
    const startedAt = performance.now();
    try {
      if (session.engine === "PostgreSQL") {
        const result = await session.client.query<unknown[]>({
          text: sql,
          rowMode: "array",
        });
        assertResultDimensions(result.rows.length, result.fields.length);
        return {
          columns: result.fields.map((field) => field.name),
          rows: result.rows.map((row) =>
            row.map((value, index) =>
              encodePostgresCell(value, result.fields[index]?.dataTypeID),
            ),
          ),
          durationMilliseconds: Math.max(
            0,
            Math.round(performance.now() - startedAt),
          ),
        };
      }
      const [rawRows, fields] = await session.client.query({
        sql,
        rowsAsArray: true,
      });
      const columns = Array.isArray(fields)
        ? fields.map((field) => field.name)
        : [];
      const rows = Array.isArray(rawRows) ? (rawRows as unknown[][]) : [];
      assertResultDimensions(rows.length, columns.length);
      return {
        columns,
        rows: rows.map((row) =>
          row.map((value, index) => encodeMySQLCell(value, fields?.[index])),
        ),
        durationMilliseconds: Math.max(
          0,
          Math.round(performance.now() - startedAt),
        ),
      };
    } catch (error) {
      if (error instanceof RPCError) throw error;
      const diagnostic = databaseDiagnostic("QUERY", error);
      throw new RPCError(-32041, queryFailureMessage(diagnostic), diagnostic);
    }
  }

  private requiredSession(raw: unknown): Session {
    const { profileID } = profileSchema.parse(raw);
    const session = this.sessions.get(profileID);
    if (session === undefined) throw notConnected();
    return session;
  }

  private async open(
    input: z.infer<typeof connectionSchema>,
    testAttempt?: ConnectionTestAttempt,
  ): Promise<{
    session: Session;
    metadata: unknown;
  }> {
    const project = input.instanceConnectionName.split(":", 1)[0];
    if (project === undefined) {
      throw new RPCError(-32602, "Invalid parameters.", "INVALID_PARAMETERS");
    }
    const connector = new Connector({
      auth: new GoogleAuth({
        projectId: project,
        scopes: ["https://www.googleapis.com/auth/cloud-platform"],
      }),
    });
    if (testAttempt !== undefined) testAttempt.connector = connector;
    const startedAt = performance.now();
    let closeDatabase: (() => Promise<unknown>) | undefined;
    try {
      const options = await connector.getOptions({
        instanceConnectionName: input.instanceConnectionName,
        authType: input.useIAM ? AuthTypes.IAM : AuthTypes.PASSWORD,
        ipType: IpAddressTypes[input.ipType],
      });
      if (connectionTestWasCancelled(testAttempt))
        throw connectionTestCancelled();
      if (input.engine === "PostgreSQL") {
        const client = new pg.Client({
          ...options,
          types: postgresTypes,
          user: input.user,
          database: input.database,
          ...(input.password === undefined ? {} : { password: input.password }),
          connectionTimeoutMillis: 15_000,
        });
        closeDatabase = () => client.end();
        if (testAttempt !== undefined)
          testAttempt.closeDatabase = closeDatabase;
        await client.connect();
        if (connectionTestWasCancelled(testAttempt))
          throw connectionTestCancelled();
        if (input.readOnly)
          await client.query("SET default_transaction_read_only = on");
        const result = await client.query<{
          database: string;
          server_version: string;
          server_encoding: string;
          server_timezone: string;
        }>(`SELECT current_database() AS database,
                  current_setting('server_version') AS server_version,
                  current_setting('server_encoding') AS server_encoding,
                  current_setting('TimeZone') AS server_timezone`);
        const metadata = result.rows[0];
        return {
          session: { engine: "PostgreSQL", connector, client },
          metadata: {
            latencyMilliseconds: Math.max(
              0,
              Math.round(performance.now() - startedAt),
            ),
            serverVersion: metadata?.server_version ?? "",
            serverEncoding: metadata?.server_encoding ?? "",
            serverTimeZone: metadata?.server_timezone ?? "",
            database: metadata?.database ?? input.database,
          },
        };
      }

      const client = await mysql.createConnection({
        ...options,
        dateStrings: true,
        supportBigNumbers: true,
        bigNumberStrings: true,
        user: input.user,
        database: input.database,
        ...(input.password === undefined ? {} : { password: input.password }),
        connectTimeout: 15_000,
      });
      closeDatabase = () => client.end();
      if (testAttempt !== undefined) testAttempt.closeDatabase = closeDatabase;
      if (connectionTestWasCancelled(testAttempt))
        throw connectionTestCancelled();
      await client.query("SET time_zone = '+00:00'");
      if (input.readOnly)
        await client.query("SET SESSION TRANSACTION READ ONLY");
      const [rows] = await client.query<mysql.RowDataPacket[]>(
        `SELECT DATABASE() AS database,
                VERSION() AS server_version,
                @@character_set_server AS server_encoding,
                @@session.time_zone AS server_timezone`,
      );
      const metadata = rows[0];
      return {
        session: { engine: "MySQL", connector, client },
        metadata: {
          latencyMilliseconds: Math.max(
            0,
            Math.round(performance.now() - startedAt),
          ),
          serverVersion: String(metadata?.server_version ?? ""),
          serverEncoding: String(metadata?.server_encoding ?? ""),
          serverTimeZone: String(metadata?.server_timezone ?? ""),
          database: String(metadata?.database ?? input.database),
        },
      };
    } catch (error) {
      try {
        await closeDatabase?.();
      } catch {
        // Preserve the original connection failure.
      }
      connector.close();
      if (connectionTestWasCancelled(testAttempt))
        throw connectionTestCancelled();
      const diagnostic = databaseDiagnostic("CLOUD_SQL_CONNECTION", error);
      throw new RPCError(
        -32020,
        connectionFailureMessage(diagnostic),
        diagnostic,
      );
    }
  }

  private async postgresDetails(
    client: pg.Client,
    object: z.infer<typeof objectSchema>["object"],
  ): Promise<unknown> {
    const columns = await metadataQuery("COLUMNS", () =>
      client.query<{
        ordinal_position: number;
        name: string;
        data_type: string;
        is_nullable: boolean;
        default_value: string | null;
        collation: string | null;
        comment: string | null;
        is_primary_key: boolean;
      }>(
        `SELECT attribute.attnum::integer AS ordinal_position,
              attribute.attname AS name,
              pg_catalog.format_type(attribute.atttypid, attribute.atttypmod) AS data_type,
              NOT attribute.attnotnull AS is_nullable,
              pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid) AS default_value,
              column_collation.collname AS collation,
              pg_catalog.col_description(relation.oid, attribute.attnum) AS comment,
              EXISTS (
                SELECT 1 FROM pg_catalog.pg_constraint AS primary_constraint
                 WHERE primary_constraint.conrelid = relation.oid
                   AND primary_constraint.contype = 'p'
                   AND attribute.attnum = ANY(primary_constraint.conkey)
              ) AS is_primary_key
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = relation.oid
         LEFT JOIN pg_catalog.pg_attrdef AS default_value
           ON default_value.adrelid = relation.oid AND default_value.adnum = attribute.attnum
         LEFT JOIN pg_catalog.pg_collation AS column_collation
           ON column_collation.oid = attribute.attcollation
        WHERE namespace.nspname = $1 AND relation.relname = $2
          AND attribute.attnum > 0 AND NOT attribute.attisdropped
        ORDER BY attribute.attnum`,
        [object.schema, object.name],
      ),
    );

    const indexRows = await metadataQuery("INDEXES", () =>
      client.query<{
        index_name: string;
        is_unique: boolean;
        is_primary: boolean;
        index_method: string | null;
        column_name: string | null;
      }>(
        `SELECT index_relation.relname AS index_name,
              index_record.indisunique AS is_unique,
              index_record.indisprimary AS is_primary,
              access_method.amname AS index_method,
              COALESCE(
                attribute.attname,
                pg_catalog.pg_get_indexdef(
                  index_record.indexrelid,
                  index_key.ordinal_position::integer,
                  TRUE
                )
              ) AS column_name
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         JOIN pg_catalog.pg_index AS index_record ON index_record.indrelid = relation.oid
         JOIN pg_catalog.pg_class AS index_relation
           ON index_relation.oid = index_record.indexrelid
         JOIN pg_catalog.pg_am AS access_method ON access_method.oid = index_relation.relam
         LEFT JOIN LATERAL unnest(index_record.indkey) WITH ORDINALITY
           AS index_key(attribute_number, ordinal_position) ON TRUE
         LEFT JOIN pg_catalog.pg_attribute AS attribute
           ON attribute.attrelid = relation.oid
          AND attribute.attnum = index_key.attribute_number
        WHERE namespace.nspname = $1 AND relation.relname = $2
        ORDER BY index_relation.relname, index_key.ordinal_position`,
        [object.schema, object.name],
      ),
    );

    const constraintRows = await metadataQuery("CONSTRAINTS", () =>
      client.query<{
        constraint_name: string;
        constraint_type: string;
        column_name: string | null;
        referenced_schema: string | null;
        referenced_table: string | null;
        referenced_column: string | null;
        definition: string | null;
      }>(
        `SELECT constraint_record.conname AS constraint_name,
              constraint_record.contype::text AS constraint_type,
              attribute.attname AS column_name,
              referenced_namespace.nspname AS referenced_schema,
              referenced_relation.relname AS referenced_table,
              referenced_attribute.attname AS referenced_column,
              pg_catalog.pg_get_constraintdef(constraint_record.oid, TRUE) AS definition
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         JOIN pg_catalog.pg_constraint AS constraint_record
           ON constraint_record.conrelid = relation.oid
         LEFT JOIN LATERAL unnest(constraint_record.conkey) WITH ORDINALITY
           AS constraint_key(attribute_number, ordinal_position) ON TRUE
         LEFT JOIN pg_catalog.pg_attribute AS attribute
           ON attribute.attrelid = relation.oid
          AND attribute.attnum = constraint_key.attribute_number
         LEFT JOIN pg_catalog.pg_class AS referenced_relation
           ON referenced_relation.oid = constraint_record.confrelid
         LEFT JOIN pg_catalog.pg_namespace AS referenced_namespace
           ON referenced_namespace.oid = referenced_relation.relnamespace
         LEFT JOIN LATERAL unnest(constraint_record.confkey) WITH ORDINALITY
           AS referenced_key(attribute_number, ordinal_position)
           ON referenced_key.ordinal_position = constraint_key.ordinal_position
         LEFT JOIN pg_catalog.pg_attribute AS referenced_attribute
           ON referenced_attribute.attrelid = referenced_relation.oid
          AND referenced_attribute.attnum = referenced_key.attribute_number
        WHERE namespace.nspname = $1 AND relation.relname = $2
        ORDER BY constraint_record.conname, constraint_key.ordinal_position`,
        [object.schema, object.name],
      ),
    );

    const indexes = groupRows(indexRows.rows, (row) => row.index_name).map(
      (group) => ({
        name: group.key,
        columns: group.rows.flatMap((row) =>
          row.column_name === null ? [] : [row.column_name],
        ),
        isUnique: group.rows[0]?.is_unique ?? false,
        isPrimary: group.rows[0]?.is_primary ?? false,
        method: group.rows[0]?.index_method ?? null,
      }),
    );
    const constraints = groupRows(
      constraintRows.rows,
      (row) => row.constraint_name,
    ).map((group) => {
      const first = group.rows[0];
      return {
        name: group.key,
        kind: constraintKind(first?.constraint_type),
        columns: group.rows.flatMap((row) =>
          row.column_name === null ? [] : [row.column_name],
        ),
        referencedSchema: first?.referenced_schema ?? null,
        referencedTable: first?.referenced_table ?? null,
        referencedColumns: group.rows.flatMap((row) =>
          row.referenced_column === null ? [] : [row.referenced_column],
        ),
        definition: first?.definition ?? null,
      };
    });

    let definition: string | null = null;
    if (object.kind === "view" || object.kind === "materializedView") {
      const definitionResult = await metadataQuery("DEFINITION", () =>
        client.query<{
          definition: string | null;
        }>(
          `SELECT pg_catalog.pg_get_viewdef(relation.oid, TRUE) AS definition
           FROM pg_catalog.pg_class AS relation
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = $1 AND relation.relname = $2`,
          [object.schema, object.name],
        ),
      );
      definition = definitionResult.rows[0]?.definition ?? null;
    }

    return {
      object,
      columns: columns.rows.map((row) => ({
        ordinalPosition: row.ordinal_position,
        name: row.name,
        dataType: row.data_type,
        isNullable: row.is_nullable,
        defaultValue: row.default_value,
        characterSet: null,
        collation: row.collation,
        comment: row.comment,
        isPrimaryKey: row.is_primary_key,
      })),
      indexes,
      constraints,
      definition,
    };
  }

  private async mysqlDetails(
    client: mysql.Connection,
    object: z.infer<typeof objectSchema>["object"],
  ): Promise<unknown> {
    const [columns] = await metadataQuery("COLUMNS", () =>
      client.execute<mysql.RowDataPacket[]>(
        `SELECT ordinal_position, column_name AS name, column_type AS data_type,
              is_nullable = 'YES' AS is_nullable, column_default AS default_value,
              character_set_name AS character_set, collation_name AS collation,
              column_comment AS comment, column_key = 'PRI' AS is_primary_key
         FROM information_schema.columns
        WHERE table_schema = ? AND table_name = ?
        ORDER BY ordinal_position`,
        [object.schema, object.name],
      ),
    );

    const [indexRows] = await metadataQuery("INDEXES", () =>
      client.execute<mysql.RowDataPacket[]>(
        `SELECT index_name, non_unique, index_type, column_name
           FROM information_schema.statistics
          WHERE table_schema = ? AND table_name = ?
          ORDER BY index_name, seq_in_index`,
        [object.schema, object.name],
      ),
    );
    const indexes = groupRows(indexRows, (row) => String(row.index_name)).map(
      (group) => ({
        name: group.key,
        columns: group.rows.flatMap((row) =>
          optionalList(nullableString(row.column_name)),
        ),
        isUnique: Number(group.rows[0]?.non_unique ?? 1) === 0,
        isPrimary: group.key === "PRIMARY",
        method: nullableString(group.rows[0]?.index_type),
      }),
    );

    const [constraintRows] = await metadataQuery("CONSTRAINTS", () =>
      client.execute<mysql.RowDataPacket[]>(
        `SELECT table_constraint.constraint_name,
                table_constraint.constraint_type,
                key_column.column_name,
                key_column.referenced_table_schema,
                key_column.referenced_table_name,
                key_column.referenced_column_name
           FROM information_schema.table_constraints AS table_constraint
           LEFT JOIN information_schema.key_column_usage AS key_column
             ON key_column.constraint_schema = table_constraint.constraint_schema
            AND key_column.table_schema = table_constraint.table_schema
            AND key_column.table_name = table_constraint.table_name
            AND key_column.constraint_name = table_constraint.constraint_name
          WHERE table_constraint.table_schema = ? AND table_constraint.table_name = ?
          ORDER BY table_constraint.constraint_name, key_column.ordinal_position`,
        [object.schema, object.name],
      ),
    );
    const constraints = groupRows(constraintRows, (row) =>
      String(row.constraint_name),
    ).map((group) => {
      const first = group.rows[0];
      return {
        name: group.key,
        kind: constraintKind(nullableString(first?.constraint_type)),
        columns: group.rows.flatMap((row) =>
          optionalList(nullableString(row.column_name)),
        ),
        referencedSchema: nullableString(first?.referenced_table_schema),
        referencedTable: nullableString(first?.referenced_table_name),
        referencedColumns: group.rows.flatMap((row) =>
          optionalList(nullableString(row.referenced_column_name)),
        ),
        definition: null,
      };
    });

    let definition: string | null = null;
    if (object.kind === "view") {
      const [definitionRows] = await metadataQuery("DEFINITION", () =>
        client.execute<mysql.RowDataPacket[]>(
          `SELECT view_definition
             FROM information_schema.views
            WHERE table_schema = ? AND table_name = ?`,
          [object.schema, object.name],
        ),
      );
      definition = nullableString(definitionRows[0]?.view_definition);
    }

    return {
      object,
      columns: columns.map((row) => ({
        ordinalPosition: Number(row.ordinal_position),
        name: String(row.name),
        dataType: String(row.data_type),
        isNullable: Boolean(row.is_nullable),
        defaultValue: nullableString(row.default_value),
        characterSet: nullableString(row.character_set),
        collation: nullableString(row.collation),
        comment: nullableString(row.comment),
        isPrimaryKey: Boolean(row.is_primary_key),
      })),
      indexes,
      constraints,
      definition,
    };
  }
}

type Group<Row> = { key: string; rows: Row[] };

const groupRows = <Row>(
  rows: Row[],
  keyForRow: (row: Row) => string,
): Group<Row>[] => {
  const ordered: Group<Row>[] = [];
  const byKey = new Map<string, Group<Row>>();
  for (const row of rows) {
    const key = keyForRow(row);
    let group = byKey.get(key);
    if (group === undefined) {
      group = { key, rows: [] };
      byKey.set(key, group);
      ordered.push(group);
    }
    group.rows.push(row);
  }
  return ordered;
};

const constraintKind = (value: string | null | undefined): string => {
  switch (value) {
    case "p":
    case "PRIMARY KEY":
      return "Primary key";
    case "f":
    case "FOREIGN KEY":
      return "Foreign key";
    case "u":
    case "UNIQUE":
      return "Unique";
    case "c":
    case "CHECK":
      return "Check";
    case "x":
      return "Exclusion";
    default:
      return "Other";
  }
};

const nullableString = (value: unknown): string | null =>
  value === null || value === undefined ? null : String(value);

const optionalList = <Value>(value: Value | null): Value[] =>
  value === null ? [] : [value];

const metadataQuery = async <Result>(
  stage: "COLUMNS" | "INDEXES" | "CONSTRAINTS" | "DEFINITION",
  operation: () => Promise<Result>,
): Promise<Result> => {
  try {
    return await operation();
  } catch (error) {
    throw new RPCError(
      -32040,
      "The database rejected the schema metadata query.",
      databaseDiagnostic(`SCHEMA_${stage}`, error),
    );
  }
};

const databaseDiagnostic = (scope: string, error: unknown): string => {
  if (typeof error !== "object" || error === null) return `${scope}_FAILED`;
  const record = error as Record<string, unknown>;
  const sqlState = sanitizedCode(
    record.sqlState ?? record.code,
    /^[0-9A-Z]{5}$/,
  );
  if (sqlState !== null) return `${scope}_SQLSTATE_${sqlState}`;
  const mysqlCode = sanitizedCode(record.code, /^ER_[A-Z0-9_]+$/);
  if (mysqlCode !== null) return `${scope}_${mysqlCode}`;
  const status =
    record.status ??
    (record.response as Record<string, unknown> | undefined)?.status;
  if (status === 401 || status === 403) return `${scope}_HTTP_${status}`;
  return `${scope}_FAILED`;
};

const sanitizedCode = (value: unknown, pattern: RegExp): string | null => {
  const code = typeof value === "string" ? value : "";
  return pattern.test(code) ? code : null;
};

const connectionFailureMessage = (diagnostic: string): string => {
  if (
    diagnostic.endsWith("_SQLSTATE_28000") ||
    diagnostic.endsWith("_SQLSTATE_28P01") ||
    diagnostic.endsWith("_ER_ACCESS_DENIED_ERROR") ||
    diagnostic.endsWith("_HTTP_401") ||
    diagnostic.endsWith("_HTTP_403")
  ) {
    return "Cloud SQL or database authentication was rejected.";
  }
  if (
    diagnostic.endsWith("_SQLSTATE_3D000") ||
    diagnostic.endsWith("_ER_BAD_DB_ERROR")
  ) {
    return "The selected database does not exist or is unavailable.";
  }
  return "Cloud SQL secure connection failed.";
};

const queryFailureMessage = (diagnostic: string): string => {
  if (
    diagnostic.endsWith("_SQLSTATE_42601") ||
    diagnostic.endsWith("_ER_PARSE_ERROR") ||
    diagnostic.endsWith("_ER_SYNTAX_ERROR")
  ) {
    return "The database reported a SQL syntax error.";
  }
  if (
    diagnostic.endsWith("_SQLSTATE_42501") ||
    diagnostic.endsWith("_ER_DBACCESS_DENIED_ERROR") ||
    diagnostic.endsWith("_ER_TABLEACCESS_DENIED_ERROR")
  ) {
    return "The database account is not allowed to run this query.";
  }
  if (diagnostic.endsWith("_SQLSTATE_57014")) {
    return "The database cancelled the query.";
  }
  if (
    diagnostic.endsWith("_SQLSTATE_42P01") ||
    diagnostic.endsWith("_SQLSTATE_42703") ||
    diagnostic.endsWith("_ER_NO_SUCH_TABLE") ||
    diagnostic.endsWith("_ER_BAD_FIELD_ERROR")
  ) {
    return "The query references a table or column that does not exist.";
  }
  return "The database rejected the query.";
};

const closeSession = async (session: Session): Promise<void> => {
  try {
    await session.client.end();
  } finally {
    session.connector.close();
  }
};

const notConnected = (): RPCError =>
  new RPCError(
    -32030,
    "Connect to the database first.",
    "DATABASE_NOT_CONNECTED",
  );

const connectionTestCancelled = (): RPCError =>
  new RPCError(
    -32800,
    "The connection test was cancelled.",
    "CONNECTION_TEST_CANCELLED",
  );

const connectionTestWasCancelled = (
  attempt: ConnectionTestAttempt | undefined,
): boolean => attempt?.cancelled === true;

const encodeCell = (value: unknown): unknown => {
  if (value === null || value === undefined) return { kind: "null" };
  if (typeof value === "boolean")
    return { kind: "boolean", value: String(value) };
  if (typeof value === "number" && Number.isSafeInteger(value)) {
    return { kind: "integer", value: String(value) };
  }
  if (typeof value === "number" || typeof value === "bigint") {
    return { kind: "decimal", value: String(value) };
  }
  if (value instanceof Date)
    return { kind: "instant", value: value.toISOString() };
  if (Buffer.isBuffer(value))
    return { kind: "binary", byteCount: value.byteLength };
  const text = textCellValue(value);
  if (Buffer.byteLength(text, "utf8") > maximumCellBytes) {
    throw new RPCError(
      -32051,
      "A query result cell is too large to display safely.",
      "QUERY_CELL_TOO_LARGE",
    );
  }
  return { kind: "text", value: text };
};

const textCellValue = (value: unknown): string => {
  if (typeof value === "object") {
    try {
      const json = JSON.stringify(value, (_key, nestedValue: unknown) =>
        typeof nestedValue === "bigint" ? String(nestedValue) : nestedValue,
      );
      if (json !== undefined) return json;
    } catch {
      // Fall through for driver-specific values that cannot be represented as JSON.
    }
  }
  return String(value);
};

const assertResultDimensions = (
  rowCount: number,
  columnCount: number,
): void => {
  if (rowCount > maximumResultRows || columnCount > maximumResultColumns) {
    throw new RPCError(
      -32050,
      "The query result is too large to display safely.",
      "QUERY_RESULT_TOO_LARGE",
    );
  }
};

export const encodePostgresCell = (
  value: unknown,
  dataTypeID: number | undefined,
): unknown => {
  if (value === null || value === undefined) return { kind: "null" };
  switch (dataTypeID) {
    case 16:
      return { kind: "boolean", value: String(value) };
    case 20:
    case 21:
    case 23:
      return { kind: "integer", value: String(value) };
    case 700:
    case 701:
    case 790:
    case 1700:
      return { kind: "decimal", value: String(value) };
    case 1082:
      return { kind: "date", value: String(value) };
    case 1114:
      return { kind: "localTimestamp", value: String(value) };
    case 1184:
      return value instanceof Date
        ? { kind: "instant", value: value.toISOString() }
        : { kind: "instant", value: String(value) };
    case 17:
      return Buffer.isBuffer(value)
        ? { kind: "binary", byteCount: value.byteLength }
        : encodeCell(value);
    default:
      return encodeCell(value);
  }
};

const mysqlType = {
  decimal: 0,
  tiny: 1,
  short: 2,
  long: 3,
  float: 4,
  double: 5,
  timestamp: 7,
  longLong: 8,
  int24: 9,
  date: 10,
  datetime: 12,
  year: 13,
  newDate: 14,
  bit: 16,
  newDecimal: 246,
} as const;

export const encodeMySQLCell = (
  value: unknown,
  field: mysql.FieldPacket | undefined,
): unknown => {
  if (value === null || value === undefined) return { kind: "null" };
  switch (field?.type) {
    case mysqlType.tiny:
      if (field.columnLength === 1) {
        return {
          kind: "boolean",
          value: Number(value) === 0 ? "false" : "true",
        };
      }
      return { kind: "integer", value: String(value) };
    case mysqlType.short:
    case mysqlType.long:
    case mysqlType.longLong:
    case mysqlType.int24:
    case mysqlType.year:
      return { kind: "integer", value: String(value) };
    case mysqlType.decimal:
    case mysqlType.float:
    case mysqlType.double:
    case mysqlType.newDecimal:
      return { kind: "decimal", value: String(value) };
    case mysqlType.timestamp: {
      const iso = mysqlUTCString(value);
      return iso === null ? encodeCell(value) : { kind: "instant", value: iso };
    }
    case mysqlType.datetime:
      return { kind: "localTimestamp", value: String(value) };
    case mysqlType.date:
    case mysqlType.newDate:
      return { kind: "date", value: String(value) };
    case mysqlType.bit:
      return Buffer.isBuffer(value) && value.byteLength === 1
        ? { kind: "boolean", value: value[0] === 0 ? "false" : "true" }
        : encodeCell(value);
    default:
      return encodeCell(value);
  }
};

const mysqlUTCString = (value: unknown): string | null => {
  const text = String(value);
  if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,6})?$/.test(text))
    return null;
  return `${text.replace(" ", "T")}Z`;
};
