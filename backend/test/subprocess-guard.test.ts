import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const guardPath = fileURLToPath(
  new URL("../src/subprocess-guard.cjs", import.meta.url),
);

describe("subprocess guard", () => {
  it("blocks child_process execution before the backend is loaded", () => {
    const output = execFileSync(
      process.execPath,
      [
        "--require",
        guardPath,
        "--eval",
        `try {
          require('node:child_process').execFileSync('/usr/bin/true');
          process.stdout.write('NOT_BLOCKED');
        } catch (error) {
          process.stdout.write(String(error.code));
        }`,
      ],
      { encoding: "utf8" },
    );

    expect(output).toBe("SOLNARI_SUBPROCESS_DISABLED");
  });
});
