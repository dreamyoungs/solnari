import { GoogleAuth, OAuth2Client } from "google-auth-library";
import { z } from "zod";
import { RPCError } from "./protocol.js";

const projectSchema = z.string().regex(/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/);
const instanceSchema = z
  .string()
  .min(1)
  .max(98)
  .regex(/^[a-zA-Z0-9_-]+$/);

interface InstancesResponse {
  items?: Array<{
    name: string;
    region?: string;
    databaseVersion: string;
    state?: string;
  }>;
}

interface DatabasesResponse {
  items?: Array<{ name: string }>;
}

interface IdentityResponse {
  email?: string;
  email_verified?: boolean;
}

interface UsersResponse {
  items?: Array<{ name?: string; type?: string }>;
}

export class GoogleCloudService {
  async identity(raw: unknown): Promise<{ email: string | null }> {
    const { project } = z.object({ project: projectSchema }).parse(raw);
    try {
      const client = await googleAuth(project).getClient();
      if (client instanceof OAuth2Client) {
        const accessToken = await client.getAccessToken();
        if (accessToken.token !== null && accessToken.token !== undefined) {
          const tokenInfo = await client.getTokenInfo(accessToken.token);
          const email = tokenInfo.email?.trim().toLowerCase();
          if (email !== undefined && isEmail(email)) return { email };
        }
      }
      const response = await client.request<IdentityResponse>({
        url: "https://www.googleapis.com/oauth2/v2/userinfo",
        method: "GET",
      });
      const email = response.data.email?.trim().toLowerCase();
      return { email: email !== undefined && isEmail(email) ? email : null };
    } catch (error) {
      if (googleAPIStatus(error) === 403) return { email: null };
      throw googleAPIError(error);
    }
  }

  async instances(rawProject: unknown): Promise<unknown> {
    const project = projectSchema.parse(rawProject);
    try {
      const client = await googleAuth(project).getClient();
      const url = new URL(
        `https://sqladmin.googleapis.com/v1/projects/${encodeURIComponent(project)}/instances`,
      );
      url.searchParams.set("filter", "instanceType:CLOUD_SQL_INSTANCE");
      url.searchParams.set("maxResults", "1000");
      const response = await client.request<InstancesResponse>({
        url: url.toString(),
        method: "GET",
        headers: { "X-Goog-User-Project": project },
      });
      return (response.data.items ?? [])
        .flatMap((instance) => {
          const engine = instance.databaseVersion.startsWith("POSTGRES_")
            ? "PostgreSQL"
            : instance.databaseVersion.startsWith("MYSQL_")
              ? "MySQL"
              : null;
          return engine === null
            ? []
            : [
                {
                  name: instance.name,
                  region: instance.region ?? "",
                  engine,
                  state: instance.state ?? "UNKNOWN",
                },
              ];
        })
        .sort((left, right) => left.name.localeCompare(right.name));
    } catch (error) {
      throw googleAPIError(error);
    }
  }

  async databases(raw: unknown): Promise<string[]> {
    const { project, instance } = z
      .object({ project: projectSchema, instance: instanceSchema })
      .parse(raw);
    try {
      const client = await googleAuth(project).getClient();
      const url =
        `https://sqladmin.googleapis.com/v1/projects/${encodeURIComponent(project)}` +
        `/instances/${encodeURIComponent(instance)}/databases`;
      const response = await client.request<DatabasesResponse>({
        url,
        method: "GET",
        headers: { "X-Goog-User-Project": project },
      });
      return (response.data.items ?? []).map((item) => item.name).sort();
    } catch (error) {
      throw googleAPIError(error);
    }
  }

  async users(raw: unknown): Promise<unknown> {
    const { project, instance } = z
      .object({ project: projectSchema, instance: instanceSchema })
      .parse(raw);
    try {
      const client = await googleAuth(project).getClient();
      const url =
        `https://sqladmin.googleapis.com/v1/projects/${encodeURIComponent(project)}` +
        `/instances/${encodeURIComponent(instance)}/users`;
      const response = await client.request<UsersResponse>({
        url,
        method: "GET",
        headers: { "X-Goog-User-Project": project },
      });
      return (response.data.items ?? [])
        .flatMap((user) => {
          const name = user.name?.trim();
          const type = user.type?.trim();
          return name === undefined || type === undefined
            ? []
            : [{ name, type }];
        })
        .sort((left, right) => left.name.localeCompare(right.name));
    } catch (error) {
      throw googleAPIError(error);
    }
  }
}

const googleAuth = (project: string): GoogleAuth =>
  new GoogleAuth({
    projectId: project,
    scopes: ["https://www.googleapis.com/auth/cloud-platform"],
  });

const isEmail = (value: string): boolean =>
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) && value.length <= 320;

const googleAPIError = (error: unknown): RPCError => {
  const status = googleAPIStatus(error);
  if (status === 401) {
    return new RPCError(
      -32010,
      "Application Default Credentials are unavailable.",
      "GOOGLE_AUTHENTICATION_UNAVAILABLE",
    );
  }
  if (status === 403) {
    return new RPCError(
      -32011,
      "The ADC account cannot access this Google Cloud resource.",
      "GOOGLE_PERMISSION_DENIED",
    );
  }
  if (status === 404) {
    return new RPCError(
      -32012,
      "The Google Cloud API or requested resource is unavailable.",
      "GOOGLE_API_UNAVAILABLE",
    );
  }
  return new RPCError(
    -32013,
    "Google Cloud request failed.",
    "GOOGLE_REQUEST_FAILED",
  );
};

const googleAPIStatus = (error: unknown): number | undefined =>
  typeof error === "object" && error !== null && "response" in error
    ? (error as { response?: { status?: number } }).response?.status
    : undefined;
