import Foundation
import Testing

@testable import Solnari

struct KubernetesIAMTests {
  @Test func legacyProfilesKeepPasswordAuthentication() throws {
    let data = Data(
      #"{"context":"test","namespace":"db","relayImage":"relay","connectionMode":"Existing resource"}"#
        .utf8)
    let config = try JSONDecoder().decode(KubernetesConfiguration.self, from: data)
    #expect(config.usePersonalIAM == nil)
  }

  @Test func personalIAMRoundTripExcludesPassword() throws {
    var draft = ConnectionDraft()
    draft.name = "Personal IAM"
    draft.engine = .postgresql
    draft.transport = .kubernetes
    draft.kubeContext = "test"
    draft.namespace = "db"
    draft.kubernetesResourceName = "proxy"
    draft.database = "app"
    draft.user = "person@example.com"
    draft.usePersonalIAM = true
    draft.password = "stale-password"
    #expect(draft.connectionPassword.isEmpty)
    let profile = try draft.makeProfile()
    #expect(profile.usesPersonalIAM)
    let data = try ConnectionProfileTransferService.encode([profile])
    #expect(!String(decoding: data, as: UTF8.self).contains("stale-password"))
    let restored = try #require(ConnectionProfileTransferService.decode(data).first)
    #expect(restored.usesPersonalIAM)
    #expect(ConnectionDraft(profile: restored).usesEphemeralCredentials)
    draft.engine = .mysql
    #expect(!draft.usesPersonalIAM)
    #expect(draft.connectionPassword == "stale-password")
  }
}
