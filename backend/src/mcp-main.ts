import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { createSolnariMCPServer } from "./mcp-server.js";

serveStdio(() => createSolnariMCPServer());
