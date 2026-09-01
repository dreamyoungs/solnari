import { createInterface } from "node:readline";
import { ZodError } from "zod";
import {
  requestSchema,
  RPCError,
  type RPCFailure,
  type RPCResponse,
} from "./protocol.js";
import { Router } from "./router.js";

const router = new Router();
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const maximumResponseBytes = 8_388_608;

const write = (response: RPCResponse): void => {
  let encoded = JSON.stringify(response);
  if (Buffer.byteLength(encoded, "utf8") > maximumResponseBytes) {
    encoded = JSON.stringify(
      failure(
        response.id,
        -32050,
        "The query result is too large to display safely.",
        "QUERY_RESULT_TOO_LARGE",
      ),
    );
  }
  process.stdout.write(`${encoded}\n`);
};

input.on("line", (line) => {
  void handleLine(line);
});

const handleLine = async (line: string): Promise<void> => {
  if (Buffer.byteLength(line, "utf8") > 1_048_576) {
    write(failure(null, -32600, "Request is too large.", "REQUEST_TOO_LARGE"));
    return;
  }
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    write(failure(null, -32700, "Parse error.", "PARSE_ERROR"));
    return;
  }
  const parsed = requestSchema.safeParse(raw);
  if (!parsed.success) {
    write(failure(null, -32600, "Invalid request.", "INVALID_REQUEST"));
    return;
  }
  try {
    const result = await router.dispatch(parsed.data);
    write({ jsonrpc: "2.0", id: parsed.data.id, result });
  } catch (error) {
    if (error instanceof RPCError) {
      write(
        failure(
          parsed.data.id,
          error.code,
          error.message,
          error.diagnosticCode,
        ),
      );
      return;
    }
    if (error instanceof ZodError) {
      write(
        failure(
          parsed.data.id,
          -32602,
          "Invalid parameters.",
          "INVALID_PARAMETERS",
        ),
      );
      return;
    }
    write(failure(parsed.data.id, -32603, "Internal error.", "INTERNAL_ERROR"));
  }
};

const failure = (
  id: string | number | null,
  code: number,
  message: string,
  diagnosticCode: string,
): RPCFailure => ({
  jsonrpc: "2.0",
  id,
  error: { code, message, data: { diagnosticCode } },
});

let isShuttingDown = false;

const shutdown = async (): Promise<void> => {
  if (isShuttingDown) return;
  isShuttingDown = true;
  input.close();
  await router.shutdown();
  process.exitCode = 0;
};

input.on("close", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
process.on("SIGINT", () => void shutdown());
