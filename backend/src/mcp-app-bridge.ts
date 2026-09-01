import { createConnection } from "node:net";
import { homedir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { z } from "zod";

const bridgeResponseSchema = z.object({
  id: z.string(),
  ok: z.boolean(),
  resultJSON: z.string().nullable().optional(),
  error: z.string().nullable().optional(),
});

export interface SolnariBridge {
  call(method: string, params?: unknown): Promise<unknown>;
}

export class SolnariAppBridge implements SolnariBridge {
  constructor(
    private readonly socketPath = process.env.SOLNARI_MCP_SOCKET ??
      path.join(
        homedir(),
        "Library",
        "Application Support",
        "Solnari",
        "mcp.sock",
      ),
  ) {}

  call(method: string, params: unknown = {}): Promise<unknown> {
    const id = randomUUID();
    const request = JSON.stringify({
      id,
      method,
      paramsJSON: JSON.stringify(params),
    });

    return new Promise<unknown>((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      let received = Buffer.alloc(0);
      let settled = false;

      const fail = (message: string): void => {
        if (settled) return;
        settled = true;
        socket.destroy();
        reject(new Error(message));
      };

      socket.setTimeout(45_000, () => {
        fail("Solnari did not complete the MCP request in time.");
      });

      socket.once("connect", () => {
        socket.write(`${request}\n`);
      });

      socket.on("data", (chunk) => {
        received = Buffer.concat([received, chunk]);
        if (received.byteLength > 2_500_000) {
          fail("Solnari returned an MCP response that is too large.");
          return;
        }
        const newline = received.indexOf(0x0a);
        if (newline < 0) return;

        try {
          const response = bridgeResponseSchema.parse(
            JSON.parse(received.subarray(0, newline).toString("utf8")),
          );
          if (response.id !== id) {
            fail("Solnari returned a mismatched MCP response.");
            return;
          }
          if (!response.ok || response.resultJSON == null) {
            fail(response.error ?? "Solnari rejected the MCP request.");
            return;
          }
          const result: unknown = JSON.parse(response.resultJSON);
          settled = true;
          socket.end();
          resolve(result);
        } catch {
          fail("Solnari returned an invalid MCP response.");
        }
      });

      socket.once("error", () => {
        fail("Open Solnari and enable local MCP access in Settings.");
      });
    });
  }
}
