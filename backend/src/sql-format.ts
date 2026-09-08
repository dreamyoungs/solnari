import { format } from "sql-formatter";
import { z } from "zod";
import { RPCError } from "./protocol.js";

const schema = z.object({
  sql: z.string().max(100_000),
  engine: z.enum(["PostgreSQL", "MySQL", "SQLite"]),
  offsets: z.array(z.number().int().nonnegative()).max(256).default([]),
});
type Engine = z.infer<typeof schema>["engine"];
interface Token {
  value: string;
  start: number;
  end: number;
  string: boolean;
}
const unsafe = () =>
  new RPCError(
    -32602,
    "SQL could not be formatted safely. Check incomplete or unsupported syntax; the original SQL was preserved.",
    "SQL_FORMAT_UNSAFE",
  );

// 포매터와 독립적으로 문자열/주석/연산자의 보존 여부를 검사합니다.
function tokens(sql: string, engine: Engine): Token[] {
  const result: Token[] = [];
  let i = 0;
  while (i < sql.length) {
    if (/\s/u.test(sql[i]!)) {
      i++;
      continue;
    }
    const start = i;
    let string = false;
    const rest = sql.slice(i);
    if (
      /^--(?:\s|$)/u.test(rest) ||
      (engine !== "MySQL" && rest.startsWith("--")) ||
      (engine === "MySQL" && rest.startsWith("#"))
    ) {
      while (i < sql.length && !/[\r\n]/u.test(sql[i]!)) i++;
    } else if (rest.startsWith("/*")) {
      if (/^\/\*[!+]/u.test(rest)) throw unsafe();
      i += 2;
      let depth = 1;
      while (i < sql.length && depth) {
        if (sql.startsWith("/*", i)) {
          if (engine !== "PostgreSQL") throw unsafe();
          depth++;
          i += 2;
        } else if (sql.startsWith("*/", i)) {
          depth--;
          i += 2;
        } else i++;
      }
      if (depth) throw unsafe();
    } else {
      const dollar =
        engine === "PostgreSQL"
          ? /^\$(?:[\p{L}_][\p{L}\p{N}_]*)?\$/u.exec(rest)?.[0]
          : undefined;
      const quote = /^(?:[eEnNbBxX]|[uU]&)?(['"])/u.exec(rest);
      if (dollar) {
        const end = sql.indexOf(dollar, i + dollar.length);
        if (end < 0) throw unsafe();
        i = end + dollar.length;
        string = true;
      } else if (
        quote ||
        rest.startsWith("`") ||
        (engine === "SQLite" && rest.startsWith("["))
      ) {
        const opener = quote?.[1] ?? rest[0]!;
        const closer = opener === "[" ? "]" : opener;
        string = opener === "'";
        i += quote?.[0].length ?? 1;
        let closed = false;
        while (i < sql.length) {
          // PostgreSQL standard_conforming_strings / MySQL NO_BACKSLASH_ESCAPES가 불명확합니다.
          if (sql[i] === "\\") throw unsafe();
          if (sql[i] === closer) {
            if (closer !== "]" && sql[i + 1] === closer) {
              i += 2;
              continue;
            }
            i++;
            closed = true;
            break;
          }
          i++;
        }
        if (!closed) throw unsafe();
      } else {
        const token =
          /^(?:[\p{L}_][\p{L}\p{N}_$]*|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|\$\d+|[?:@$][\p{L}\p{N}_]+|[+\-*\/%<>=!~^|&:#?@]+|.)/u.exec(
            rest,
          )?.[0];
        if (!token) throw unsafe();
        i += token.length;
      }
    }
    result.push({ value: sql.slice(start, i), start, end: i, string });
  }
  return result;
}

export function formatSQL(raw: unknown): { sql: string; offsets: number[] } {
  const input = schema.parse(raw);
  try {
    const before = tokens(input.sql, input.engine);
    const output = format(input.sql, {
      language: { PostgreSQL: "postgresql", MySQL: "mysql", SQLite: "sqlite" }[
        input.engine
      ] as "postgresql" | "mysql" | "sqlite",
      keywordCase: "preserve",
      dataTypeCase: "preserve",
      functionCase: "preserve",
      tabWidth: 2,
    });
    const after = tokens(output, input.engine);
    if (
      before.length !== after.length ||
      before.some((token, i) => token.value !== after[i]!.value)
    )
      throw unsafe();
    if (input.engine === "PostgreSQL") {
      for (let i = 1; i < before.length; i++) {
        if (before[i - 1]!.string && before[i]!.string) {
          const originalNewline = /[\r\n]/u.test(
            input.sql.slice(before[i - 1]!.end, before[i]!.start),
          );
          const formattedNewline = /[\r\n]/u.test(
            output.slice(after[i - 1]!.end, after[i]!.start),
          );
          if (originalNewline !== formattedNewline) throw unsafe();
        }
      }
    }
    const offsets = input.offsets.map((offset) => {
      if (offset >= input.sql.length) return output.length;
      const index = before.findIndex((token) => token.end >= offset);
      if (index < 0) return output.length;
      return after[index]!.start + Math.max(0, offset - before[index]!.start);
    });
    return { sql: output, offsets };
  } catch {
    throw unsafe();
  }
}
