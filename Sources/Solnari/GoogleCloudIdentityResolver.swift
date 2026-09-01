import Foundation

struct GoogleCloudIdentity: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case applicationDefaultCredentials
  }

  let email: String
  let source: Source

  init(email: String, source: Source = .applicationDefaultCredentials) {
    self.email = email
    self.source = source
  }

  var isServiceAccount: Bool {
    email.lowercased().hasSuffix(".gserviceaccount.com")
  }

  func databaseUsername(for engine: DatabaseEngine) -> String {
    let normalized = email.lowercased()
    switch engine {
    case .postgresql:
      return isServiceAccount
        ? String(normalized.dropLast(".gserviceaccount.com".count)) : normalized
    case .mysql:
      return normalized.split(separator: "@", maxSplits: 1).first.map(String.init) ?? normalized
    case .sqlite:
      return ""
    }
  }
}

actor GoogleCloudIdentityResolver {
  private struct ProjectParameters: Codable, Sendable {
    let project: String
  }

  private struct IdentityResponse: Decodable, Sendable {
    let email: String?
  }

  private struct CredentialMetadata: Decodable {
    let type: String?
    let account: String?
    let clientEmail: String?
    let serviceAccountImpersonationURL: String?

    enum CodingKeys: String, CodingKey {
      case type
      case account
      case clientEmail = "client_email"
      case serviceAccountImpersonationURL = "service_account_impersonation_url"
    }
  }

  func resolve(project: String? = nil) async -> GoogleCloudIdentity? {
    if let project,
      project.range(
        of: "^[a-z][a-z0-9-]{4,28}[a-z0-9]$",
        options: .regularExpression
      ) != nil,
      let response: IdentityResponse = try? await NodeBackendClient.shared.call(
        method: "cloud.identity",
        params: ProjectParameters(project: project)
      ),
      let email = response.email,
      !email.isEmpty
    {
      return GoogleCloudIdentity(email: email)
    }
    return identityFromCredentialConfiguration()
  }

  private func identityFromCredentialConfiguration() -> GoogleCloudIdentity? {
    guard let url = credentialConfigurationURL(),
      let data = try? Data(contentsOf: url),
      let metadata = try? JSONDecoder().decode(CredentialMetadata.self, from: data)
    else { return nil }

    if let email = metadata.clientEmail, !email.isEmpty {
      return GoogleCloudIdentity(email: email)
    }
    if let account = metadata.account, account.contains("@") {
      return GoogleCloudIdentity(email: account)
    }
    guard let rawURL = metadata.serviceAccountImpersonationURL,
      let url = URL(string: rawURL),
      var component = url.pathComponents.last?.removingPercentEncoding
    else { return nil }
    if component.hasSuffix(":generateAccessToken") {
      component.removeLast(":generateAccessToken".count)
    }
    return component.contains("@") ? GoogleCloudIdentity(email: component) : nil
  }

  private func credentialConfigurationURL() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let configuredPath = environment["GOOGLE_APPLICATION_CREDENTIALS"],
      !configuredPath.isEmpty
    {
      return URL(fileURLWithPath: configuredPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/gcloud/application_default_credentials.json")
  }

}
