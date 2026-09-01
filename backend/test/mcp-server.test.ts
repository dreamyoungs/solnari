import { Client, InMemoryTransport } from "@modelcontextprotocol/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SolnariBridge } from "../src/mcp-app-bridge.js";
import { createSolnariMCPServer } from "../src/mcp-server.js";

describe("Solnari MCP server", () => {
  const closeOperations: Array<() => Promise<void>> = [];

  afterEach(async () => {
    while (closeOperations.length > 0) await closeOperations.pop()?.();
  });

  it("publishes only read-only tools with explicit annotations", async () => {
    const bridge: SolnariBridge = {
      call: vi.fn(async () => ({ status: "ready" })),
    };
    const server = createSolnariMCPServer(bridge);
    const client = new Client({ name: "solnari-test", version: "1.0.0" });
    const [clientTransport, serverTransport] =
      InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    closeOperations.push(
      () => client.close(),
      () => server.close(),
    );

    const tools = await client.listTools();
    expect(tools.tools.map((tool) => tool.name)).toEqual([
      "solnari_status",
      "solnari_get_active_connection",
      "solnari_list_schema",
      "solnari_describe_object",
      "solnari_execute_read_query",
    ]);
    for (const tool of tools.tools) {
      expect(tool.annotations?.readOnlyHint).toBe(true);
      expect(tool.annotations?.destructiveHint).toBe(false);
    }
  });

  it("forwards validated tool parameters to the local app bridge", async () => {
    const call = vi.fn(async () => ({
      name: "Development",
      status: "Connected",
    }));
    const server = createSolnariMCPServer({ call });
    const client = new Client({ name: "solnari-test", version: "1.0.0" });
    const [clientTransport, serverTransport] =
      InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    closeOperations.push(
      () => client.close(),
      () => server.close(),
    );

    const response = await client.callTool({
      name: "solnari_describe_object",
      arguments: { schema: "public", name: "users", kind: "table" },
    });

    expect(call).toHaveBeenCalledWith("describeObject", {
      schema: "public",
      name: "users",
      kind: "table",
    });
    expect(response.isError).not.toBe(true);
    expect(response.structuredContent).toEqual({
      data: { name: "Development", status: "Connected" },
    });
  });

  it("rejects invalid arguments before they reach Solnari", async () => {
    const call = vi.fn(async () => ({}));
    const server = createSolnariMCPServer({ call });
    const client = new Client({ name: "solnari-test", version: "1.0.0" });
    const [clientTransport, serverTransport] =
      InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    closeOperations.push(
      () => client.close(),
      () => server.close(),
    );

    const response = await client.callTool({
      name: "solnari_execute_read_query",
      arguments: { sql: "", maxRows: 10_000 },
    });
    expect(response.isError).toBe(true);
    expect(call).not.toHaveBeenCalled();
  });
});
