import { Client, InMemoryTransport } from "@modelcontextprotocol/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  SolnariBridgeError,
  type SolnariBridge,
} from "../src/mcp-app-bridge.js";
import { createSolnariMCPServer } from "../src/mcp-server.js";
import packageInfo from "../package.json" with { type: "json" };

describe("Solnari MCP server", () => {
  const closeOperations: Array<() => Promise<void>> = [];

  afterEach(async () => {
    while (closeOperations.length > 0) await closeOperations.pop()?.();
  });

  it("identifies the server release even when the app bridge is unavailable", async () => {
    const call = vi.fn(async () => {
      throw new Error("Open Solnari and enable local MCP access in Settings.");
    });
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

    expect(client.getServerVersion()?.version).toBe(packageInfo.version);
    const tools = await client.listTools();
    expect(
      tools.tools.find((tool) => tool.name === "solnari_status")?.description,
    ).toContain(`v${packageInfo.version}`);
    const response = await client.callTool({
      name: "solnari_status",
      arguments: {},
    });
    expect(response.isError).toBe(true);
    expect(response.structuredContent).toEqual({
      mcpServerVersion: packageInfo.version,
    });
    expect(JSON.stringify(response.content)).toContain(packageInfo.version);
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
      "solnari_list_connections",
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
      arguments: {
        connectionID: "00000000-0000-4000-8000-000000000001",
        schema: "public",
        name: "users",
        kind: "table",
      },
    });

    expect(call).toHaveBeenCalledWith("describeObject", {
      connectionID: "00000000-0000-4000-8000-000000000001",
      schema: "public",
      name: "users",
      kind: "table",
    });
    expect(response.isError).not.toBe(true);
    expect(response.structuredContent).toEqual({
      mcpServerVersion: packageInfo.version,
      data: { name: "Development", status: "Connected" },
    });

    await client.callTool({ name: "solnari_list_connections", arguments: {} });
    expect(call).toHaveBeenCalledWith("connections");
    const target = { connectionID: "00000000-0000-4000-8000-000000000002" };
    await client.callTool({ name: "solnari_list_schema", arguments: target });
    expect(call).toHaveBeenCalledWith("schema", target);
    const read = { ...target, sql: "SELECT 1" };
    await client.callTool({
      name: "solnari_execute_read_query",
      arguments: read,
    });
    expect(call).toHaveBeenCalledWith("executeReadQuery", read);

    const query = {
      connectionID: "00000000-0000-4000-8000-000000000001",
      sql: "UPDATE notes SET title = 'example' WHERE id = 1",
      maxRows: 10,
    };
    await client.callTool({ name: "solnari_execute_query", arguments: query });
    expect(call).toHaveBeenCalledWith("executeQuery", query);
    const details = {
      code: "MCP_ACCESS_LEVEL_MISMATCH",
      accessLevel: "Read-only",
      requestedOperation: "executeQuery",
      nextStep: "Review SQL in Solnari.",
      verification: "Use read-only catalog queries.",
    };
    call.mockRejectedValueOnce(
      new SolnariBridgeError("Read / Write access is required.", details),
    );
    const denied = await client.callTool({
      name: "solnari_execute_query",
      arguments: query,
    });
    expect(denied.isError).toBe(true);
    expect(denied.structuredContent).toEqual({
      mcpServerVersion: packageInfo.version,
      error: details,
    });
    expect(JSON.stringify(denied)).not.toContain(query.sql);
  });

  it("routes two listed databases concurrently without an active-connection switch", async () => {
    const databases = [
      {
        connectionID: "00000000-0000-4000-8000-000000000001",
        name: "Development",
      },
      {
        connectionID: "00000000-0000-4000-8000-000000000002",
        name: "Production",
      },
    ];
    const call = vi.fn(async (method: string, params?: unknown) =>
      method === "connections" ? databases : params,
    );
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

    const listed = await client.callTool({
      name: "solnari_list_connections",
      arguments: {},
    });
    expect(listed.structuredContent).toEqual({
      mcpServerVersion: packageInfo.version,
      data: databases,
    });
    const results = await Promise.all(
      databases.map(({ connectionID }) =>
        client.callTool({
          name: "solnari_list_schema",
          arguments: { connectionID },
        }),
      ),
    );
    expect(results.map((item) => item.structuredContent)).toEqual(
      databases.map(({ connectionID }) => ({
        mcpServerVersion: packageInfo.version,
        data: { connectionID },
      })),
    );
    expect(call.mock.calls.map(([method]) => method)).toEqual([
      "connections",
      "schema",
      "schema",
    ]);
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
    for (const name of [
      "solnari_list_schema",
      "solnari_describe_object",
      "solnari_execute_read_query",
    ]) {
      const missingTarget = await client.callTool({
        name,
        arguments: { schema: "public", name: "notes", sql: "SELECT 1" },
      });
      expect(missingTarget.isError).toBe(true);
    }
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
