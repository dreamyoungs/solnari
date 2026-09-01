"use strict";

const childProcess = require("node:child_process");
const blocked = () => {
  const error = new Error(
    "External subprocess execution is disabled in the Solnari backend.",
  );
  error.code = "SOLNARI_SUBPROCESS_DISABLED";
  throw error;
};

for (const name of [
  "exec",
  "execFile",
  "execFileSync",
  "execSync",
  "fork",
  "spawn",
  "spawnSync",
]) {
  Object.defineProperty(childProcess, name, {
    configurable: false,
    enumerable: true,
    writable: false,
    value: blocked,
  });
}
