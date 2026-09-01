import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SolnariAppBridge } from "../src/mcp-app-bridge.js";

describe("SolnariAppBridge", () => {
  let server: Server | undefined;
  let directory: string | undefined;

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve) => server?.close(() => resolve()));
      server = undefined;
    }
    if (directory) {
      await rm(directory, { recursive: true, force: true });
      directory = undefined;
    }
  });

  it("exchanges one bounded request with the running Solnari app", async () => {
    directory = await mkdtemp(path.join(tmpdir(), "solnari-mcp-test-"));
    const socketPath = path.join(directory, "bridge.sock");
    server = createServer((socket) => {
      let input = "";
      socket.setEncoding("utf8");
      socket.on("data", (chunk) => {
        input += chunk;
        const newline = input.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(input.slice(0, newline)) as {
          id: string;
          method: string;
          paramsJSON: string;
        };
        expect(request.method).toBe("activeConnection");
        expect(JSON.parse(request.paramsJSON)).toEqual({});
        socket.end(
          `${JSON.stringify({
            id: request.id,
            ok: true,
            resultJSON: JSON.stringify({ name: "Local test" }),
            error: null,
          })}\n`,
        );
      });
    });
    await new Promise<void>((resolve, reject) => {
      server?.once("error", reject);
      server?.listen(socketPath, resolve);
    });

    const bridge = new SolnariAppBridge(socketPath);
    await expect(bridge.call("activeConnection")).resolves.toEqual({
      name: "Local test",
    });
  });

  it("returns a useful error without exposing a local socket path", async () => {
    directory = await mkdtemp(path.join(tmpdir(), "solnari-mcp-test-"));
    const bridge = new SolnariAppBridge(path.join(directory, "missing.sock"));

    await expect(bridge.call("status")).rejects.toThrow(
      "Open Solnari and enable local MCP access in Settings.",
    );
  });
});
