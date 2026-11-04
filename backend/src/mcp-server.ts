import { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import packageInfo from "../package.json" with { type: "json" };
import {
  SolnariAppBridge,
  SolnariBridgeError,
  type SolnariBridge,
} from "./mcp-app-bridge.js";

const mcpServerVersion = packageInfo.version;
const versionContent = {
  type: "text" as const,
  text: `Solnari MCP server v${mcpServerVersion}`,
};

const readOnlyAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
} as const;

const connectionID = z
  .uuid()
  .describe(
    "ID of the target database from solnari_list_connections. Multiple IDs may be used concurrently without switching the app selection.",
  );

const result = async (operation: Promise<unknown>) => {
  try {
    const data = await operation;
    return {
      content: [
        { type: "text" as const, text: JSON.stringify(data, null, 2) },
        versionContent,
      ],
      structuredContent: { data, mcpServerVersion },
    };
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Solnari rejected the MCP request.";
    return {
      content: [{ type: "text" as const, text: message }, versionContent],
      isError: true,
      structuredContent: {
        mcpServerVersion,
        ...(error instanceof SolnariBridgeError && error.details
          ? { error: error.details }
          : {}),
      },
    };
  }
};

export const createSolnariMCPServer = (
  bridge: SolnariBridge = new SolnariAppBridge(),
): McpServer => {
  const server = new McpServer(
    {
      name: "solnari",
      title: "Solnari Database Tools",
      version: mcpServerVersion,
      description:
        "Access multiple already connected databases by connectionID, independently of the Solnari app selection.",
      websiteUrl: "https://github.com/dreamyoungs/solnari",
    },
    {
      instructions:
        "Solnari supports multiple connected databases at the same time. There is no global active MCP connection. " +
        "Do not ask the user to switch the selected database in Solnari or disconnect another database. " +
        "Call solnari_list_connections, match the requested database by name/database, and pass its connectionID " +
        "on each request. Use different connectionIDs concurrently when working with multiple databases. " +
        "Ask the user to connect a database in Solnari only if it is absent from the connected list. " +
        "If the intended target is ambiguous, ask which listed database to use; do not ask for a UI switch. " +
        "Never request credentials, hosts, usernames, or cloud project identifiers. Call " +
        "solnari_list_connections and choose the intended database before querying. On Read-only profiles use " +
        "solnari_execute_read_query. On Read / Write profiles use solnari_execute_query with the " +
        "returned connectionID on every database request. UI selection does not change the target. Solnari checks live session " +
        "permissions before execution. Each database request uses a fresh session that closes afterward; " +
        "temporary objects and session state do not persist. Complete transactions within one request; " +
        "uncommitted transactions roll back on close. Per-connection concurrency defaults to 3 and is " +
        "configurable in Solnari connection settings; requests over the limit are rejected without queuing. " +
        "Writes execute immediately; never automatically retry " +
        "after timeouts or transport errors. Use small LIMIT values for result queries.",
    },
  );

  server.registerTool(
    "solnari_status",
    {
      title: "Check Solnari MCP status",
      description:
        `Solnari MCP server v${mcpServerVersion}. Check the running app version/build and whether its MCP bridge is available. ` +
        "Compare mcpServerVersion with appVersion to diagnose an outdated MCP process or app.",
      inputSchema: z.object({}),
      annotations: { ...readOnlyAnnotations, openWorldHint: false },
    },
    async () => result(bridge.call("status")),
  );

  server.registerTool(
    "solnari_list_connections",
    {
      title: "List connected Solnari databases",
      description:
        "List ALL already connected databases available to MCP simultaneously. Start here to identify each requested " +
        "database by name/database and pass its connectionID to schema/query tools. Multiple listed databases can be " +
        "used concurrently without switching the app selection or disconnecting another connection. " +
        "Only ask the user to connect a database if it is absent. Disconnected profiles are excluded.",
      inputSchema: z.object({}),
      annotations: { ...readOnlyAnnotations, openWorldHint: false },
    },
    async () => result(bridge.call("connections")),
  );

  server.registerTool(
    "solnari_list_schema",
    {
      title: "List database schema",
      description:
        "List tables, views, materialized views, and functions from the specified connected database. " +
        "Use its connectionID from solnari_list_connections without switching the app selection. " +
        "You can request schemas from different connected databases concurrently.",
      inputSchema: z.object({ connectionID }),
      annotations: readOnlyAnnotations,
    },
    async (params) => result(bridge.call("schema", params)),
  );

  server.registerTool(
    "solnari_describe_object",
    {
      title: "Describe a database object",
      description:
        "Return columns, indexes, constraints, comments, text rules, and definition metadata for " +
        "one schema object in the specified connected database. Use its connectionID from " +
        "solnari_list_connections without switching the app selection; other connected databases remain available.",
      inputSchema: z.object({
        connectionID,
        schema: z
          .string()
          .min(1)
          .max(256)
          .describe("Schema containing the object."),
        name: z.string().min(1).max(256).describe("Object name."),
        kind: z
          .enum(["table", "view", "materializedView", "function"])
          .optional()
          .describe("Optional object kind when the name is ambiguous."),
      }),
      annotations: readOnlyAnnotations,
    },
    async (params) => result(bridge.call("describeObject", params)),
  );

  server.registerTool(
    "solnari_execute_query",
    {
      title: "Execute SQL on a write-enabled connection",
      description:
        "Execute SQL, including reads, INSERT, UPDATE, DELETE, and DDL, only when the specified " +
        "Solnari connection is already connected with Read / Write access. Pass connectionID " +
        "from solnari_list_connections without switching the app selection. Other connected databases can be used " +
        "concurrently. An unavailable or read-only session is rejected. " +
        "Changes execute immediately under the database role's permissions. An empty result " +
        "can mean a successful write; returnedRowCount is not an affected-row count. " +
        "Do not automatically retry after a timeout or transport error.",
      inputSchema: z.object({
        connectionID,
        sql: z.string().trim().min(1).max(200_000).describe("SQL to execute."),
        maxRows: z
          .number()
          .int()
          .min(1)
          .max(200)
          .optional()
          .describe(
            "Maximum result rows returned, not a limit on rows changed. Defaults to 50.",
          ),
      }),
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (params) => result(bridge.call("executeQuery", params)),
  );

  server.registerTool(
    "solnari_execute_read_query",
    {
      title: "Execute a read-only query",
      description:
        "Execute one read-only SQL statement on the specified connected database. The Solnari " +
        "profile must already be connected and configured as Read-only. Use its connectionID from " +
        "solnari_list_connections without switching the app selection; other databases remain available concurrently. " +
        "Solnari enforces both " +
        "SQL preflight and database-session read-only mode. Use an explicit small LIMIT.",
      inputSchema: z.object({
        connectionID,
        sql: z
          .string()
          .min(1)
          .max(200_000)
          .describe("One read-only SQL statement."),
        maxRows: z
          .number()
          .int()
          .min(1)
          .max(200)
          .optional()
          .describe("Maximum rows returned to the MCP client. Defaults to 50."),
      }),
      annotations: readOnlyAnnotations,
    },
    async (params) => result(bridge.call("executeReadQuery", params)),
  );

  return server;
};
