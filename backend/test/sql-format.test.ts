import { describe, expect, it } from "vitest";
import { formatSQL } from "../src/sql-format.js";

describe("local SQL formatting", () => {
  const corpus = [
    "select 'select from where' as label from items where id = 1",
    'SELECT "from", "MixedCase" FROM "Table"',
    "WITH t AS (SELECT id FROM items) SELECT t.id FROM t LEFT JOIN items i ON i.id=t.id",
    "INSERT INTO items (id,name) VALUES (1,'한글 🍀')",
    "UPDATE items SET name='from' WHERE id=1",
    "DELETE FROM items WHERE id=1",
    "SELECT CASE WHEN id > 1 THEN 'yes' ELSE 'no' END FROM items",
    "CREATE TABLE items (id INTEGER PRIMARY KEY, name VARCHAR(100))",
    "SELECT id -- SELECT in comment\nFROM items /* WHERE in comment */",
  ];
  for (const engine of ["PostgreSQL", "MySQL", "SQLite"] as const) {
    it.each(corpus)(`${engine}: %s`, (sql) => {
      const output = formatSQL({ sql, engine });
      expect(output.sql.length).toBeGreaterThan(0);
      expect(formatSQL({ sql: output.sql, engine }).sql).toBe(output.sql);
    });
  }
  it.each([
    ["PostgreSQL", "SELECT $tag$select; from 🍀$tag$, $1::jsonb ->> 'key'"],
    ["PostgreSQL", "SELECT payload #>> '{a,b}' FROM items"],
    [
      "MySQL",
      "SELECT `from`, ? FROM items WHERE a <=> ? # comment\nORDER BY a",
    ],
    ["SQLite", "SELECT [select], :name, @id FROM items WHERE id = ?1"],
  ])("preserves dialect tokens in %s", (engine, sql) => {
    const result = formatSQL({ engine, sql });
    expect(formatSQL({ engine, sql: result.sql }).sql).toBe(result.sql);
  });
  it.each([
    "SELECT 'unfinished",
    "SELECT (id FROM items",
    "SELECT 1 /* unfinished",
    "SELECT 'a\\b'",
    "SELECT 1 /*!80000 + 1 */",
  ])("rejects ambiguous input: %s", (sql) => {
    expect(() => formatSQL({ sql, engine: "PostgreSQL" })).toThrow(
      "original SQL was preserved",
    );
  });
  it("maps UTF-16 selections without changing the selected identifier", () => {
    const sql = "select '🍀' as name from items where id=1";
    const start = sql.indexOf("items");
    const output = formatSQL({
      sql,
      engine: "SQLite",
      offsets: [start, start + 5],
    });
    expect(output.sql.slice(output.offsets[0], output.offsets[1])).toBe(
      "items",
    );
  });
  it("bounds input size and accepts blank input", () => {
    expect(() =>
      formatSQL({ sql: "x".repeat(100001), engine: "SQLite" }),
    ).toThrow();
    expect(formatSQL({ sql: "", engine: "SQLite" }).sql).toBe("");
  });
});
