import { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import { SolnariAppBridge, type SolnariBridge } from "./mcp-app-bridge.js";

const readOnlyAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
} as const;

const result = async (operation: Promise<unknown>) => {
  try {
    const data = await operation;
    return {
      content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
      structuredContent: { data },
    };
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Solnari rejected the MCP request.";
    return {
      content: [{ type: "text" as const, text: message }],
      isError: true,
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
      version: "0.1.0",
      description:
        "Database access governed by the connection permissions selected in Solnari.",
      websiteUrl: "https://github.com/dreamyoungs/solnari",
    },
    {
      instructions:
        "Solnari exposes only the database connection currently selected in its macOS app. " +
        "Never request credentials, hosts, usernames, or cloud project identifiers. Call " +
        "solnari_get_active_connection before querying. On Read-only profiles use " +
        "solnari_execute_read_query. On Read / Write profiles use solnari_execute_query with the " +
        "returned connectionID. Solnari checks the selected connection and its live session " +
        "permissions before execution. Writes execute immediately; never automatically retry " +
        "after timeouts or transport errors. Use small LIMIT values for result queries.",
    },
  );

  server.registerTool(
    "solnari_status",
    {
      title: "Check Solnari MCP status",
      description:
        "Check whether the local Solnari app MCP bridge is available.",
      inputSchema: z.object({}),
      annotations: { ...readOnlyAnnotations, openWorldHint: false },
    },
    async () => result(bridge.call("status")),
  );

  server.registerTool(
    "solnari_get_active_connection",
    {
      title: "Get active Solnari connection",
      description:
        "Return sanitized metadata for the connection currently selected in Solnari. " +
        "This never returns credentials, hosts, usernames, SSH details, or cloud project IDs.",
      inputSchema: z.object({}),
      annotations: { ...readOnlyAnnotations, openWorldHint: false },
    },
    async () => result(bridge.call("activeConnection")),
  );

  server.registerTool(
    "solnari_list_schema",
    {
      title: "List active database schema",
      description:
        "List tables, views, materialized views, and functions from the currently selected and " +
        "already connected Solnari profile.",
      inputSchema: z.object({}),
      annotations: readOnlyAnnotations,
    },
    async () => result(bridge.call("schema")),
  );

  server.registerTool(
    "solnari_describe_object",
    {
      title: "Describe a database object",
      description:
        "Return columns, indexes, constraints, comments, text rules, and definition metadata for " +
        "one schema object in the active Solnari connection.",
      inputSchema: z.object({
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
        "Execute SQL, including reads, INSERT, UPDATE, DELETE, and DDL, only when the selected " +
        "Solnari connection is already connected with Read / Write access. Pass connectionID " +
        "from solnari_get_active_connection; a changed selection or read-only session is rejected. " +
        "Changes execute immediately under the database role's permissions. An empty result " +
        "can mean a successful write; returnedRowCount is not an affected-row count. " +
        "Do not automatically retry after a timeout or transport error.",
      inputSchema: z.object({
        connectionID: z
          .uuid()
          .describe("ID returned by solnari_get_active_connection."),
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
        "Execute one read-only SQL statement on the active Solnari connection. The Solnari " +
        "profile must already be connected and configured as Read-only. Solnari enforces both " +
        "SQL preflight and database-session read-only mode. Use an explicit small LIMIT.",
      inputSchema: z.object({
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
