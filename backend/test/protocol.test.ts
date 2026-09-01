import { describe, expect, it } from "vitest";
import { requestSchema } from "../src/protocol.js";

describe("JSON-RPC protocol", () => {
  it("accepts a bounded request with an explicit id", () => {
    expect(
      requestSchema.parse({
        jsonrpc: "2.0",
        id: 1,
        method: "system.ping",
        params: {},
      }),
    ).toMatchObject({ method: "system.ping" });
  });

  it("rejects notifications and unbounded method names", () => {
    expect(() =>
      requestSchema.parse({ jsonrpc: "2.0", method: "system.ping" }),
    ).toThrow();
    expect(() =>
      requestSchema.parse({ jsonrpc: "2.0", id: 1, method: "x".repeat(129) }),
    ).toThrow();
  });
});
