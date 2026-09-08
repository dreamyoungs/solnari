import { Client, InMemoryTransport } from "@modelcontextprotocol/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SolnariBridge } from "../src/mcp-app-bridge.js";
import { createSolnariMCPServer } from "../src/mcp-server.js";

describe("Solnari MCP server", () => {
  const closeOperations: Array<() => Promise<void>> = [];

  afterEach(async () => {
    while (closeOperations.length > 0) await closeOperations.pop()?.();
  });

  it("marks write-capable execution as destructive and non-idempotent", async () => {
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
      "solnari_execute_query",
      "solnari_execute_read_query",
    ]);
    for (const tool of tools.tools) {
      const canWrite = tool.name === "solnari_execute_query";
      expect(tool.annotations?.readOnlyHint).toBe(!canWrite);
      expect(tool.annotations?.destructiveHint).toBe(canWrite);
      expect(tool.annotations?.idempotentHint).toBe(!canWrite);
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

    const query = {
      connectionID: "00000000-0000-4000-8000-000000000001",
      sql: "UPDATE notes SET title = 'example' WHERE id = 1",
      maxRows: 10,
    };
    await client.callTool({ name: "solnari_execute_query", arguments: query });
    expect(call).toHaveBeenCalledWith("executeQuery", query);
    call.mockRejectedValueOnce(new Error("Read / Write access is required."));
    const denied = await client.callTool({
      name: "solnari_execute_query",
      arguments: query,
    });
    expect(denied.isError).toBe(true);
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
    for (const args of [
      { sql: "DELETE FROM notes" },
      { connectionID: "not-a-uuid", sql: "DELETE FROM notes" },
      { connectionID: "00000000-0000-4000-8000-000000000001", sql: "   " },
    ]) {
      const invalid = await client.callTool({
        name: "solnari_execute_query",
        arguments: args,
      });
      expect(invalid.isError).toBe(true);
    }
    expect(call).not.toHaveBeenCalled();
  });
});
