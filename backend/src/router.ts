import { z } from "zod";
import { DatabaseSessions } from "./database-sessions.js";
import { GoogleCloudService } from "./google-cloud.js";
import { RPCError, type RPCRequest } from "./protocol.js";

export class Router {
  constructor(
    private readonly googleCloud = new GoogleCloudService(),
    private readonly databaseSessions = new DatabaseSessions(),
  ) {}

  async dispatch(request: RPCRequest): Promise<unknown> {
    switch (request.method) {
      case "system.ping":
        return { name: "solnari-backend", protocolVersion: 1 };
      case "cloud.identity":
        return this.googleCloud.identity(request.params);
      case "cloudSql.instances":
        return this.googleCloud.instances(
          z.object({ project: z.unknown() }).parse(request.params).project,
        );
      case "cloudSql.databases":
        return this.googleCloud.databases(request.params);
      case "cloudSql.users":
        return this.googleCloud.users(request.params);
      case "cloudSql.testConnection":
        return this.databaseSessions.testConnection(request.params);
      case "cloudSql.cancelTestConnection":
        return this.databaseSessions.cancelTestConnection(request.params);
      case "database.connect":
        return this.databaseSessions.connect(request.params);
      case "database.disconnect":
        return this.databaseSessions.disconnect(request.params);
      case "database.disconnectAll":
        return this.databaseSessions.disconnectAll();
      case "database.schema":
        return this.databaseSessions.schema(request.params);
      case "database.details":
        return this.databaseSessions.details(request.params);
      case "database.execute":
        return this.databaseSessions.execute(request.params);
      default:
        throw new RPCError(-32601, "Method not found.", "METHOD_NOT_FOUND");
    }
  }

  async shutdown(): Promise<void> {
    await this.databaseSessions.disconnectAll();
  }
}
