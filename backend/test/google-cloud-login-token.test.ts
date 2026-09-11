import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  getClient: vi.fn(),
  getAccessToken: vi.fn(),
  options: vi.fn(),
}));
vi.mock("google-auth-library", () => ({
  GoogleAuth: class {
    constructor(options: unknown) {
      mocks.options(options);
    }
    getClient = mocks.getClient;
  },
  OAuth2Client: class {},
}));
import { GoogleCloudService } from "../src/google-cloud.js";

describe("personal IAM login credentials", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mocks.getClient.mockResolvedValue({ getAccessToken: mocks.getAccessToken });
  });
  it("requests a login-scoped token for every call without retaining a previous credential", async () => {
    mocks.getAccessToken
      .mockResolvedValueOnce({ token: "first" })
      .mockResolvedValueOnce({ token: "second" });
    const service = new GoogleCloudService();
    expect(await service.loginToken()).toEqual({ token: "first" });
    expect(await service.loginToken()).toEqual({ token: "second" });
    expect(mocks.options).toHaveBeenCalledWith({
      scopes: ["https://www.googleapis.com/auth/sqlservice.login"],
    });
  });
  it("does not expose credentials embedded in authentication errors", async () => {
    mocks.getAccessToken.mockRejectedValue(new Error("secret-refresh-token"));
    await expect(new GoogleCloudService().loginToken()).rejects.toMatchObject({
      message: "Application Default Credentials are unavailable.",
      diagnosticCode: "GOOGLE_AUTHENTICATION_UNAVAILABLE",
    });
  });
  it("fails closed when ADC returns no token", async () => {
    mocks.getAccessToken.mockResolvedValue({ token: null });
    await expect(new GoogleCloudService().loginToken()).rejects.toThrow(
      "Application Default Credentials are unavailable.",
    );
  });
});
