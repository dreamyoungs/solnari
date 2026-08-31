import Testing

@testable import Solnari

struct GoogleCloudIdentityResolverTests {
  @Test("Cloud SQL IAM 사용자명을 엔진과 principal 종류에 맞게 변환한다")
  func databaseUsernameNormalization() {
    let user = GoogleCloudIdentity(email: "Developer.User@Example.COM")
    #expect(user.databaseUsername(for: .postgresql) == "developer.user@example.com")
    #expect(user.databaseUsername(for: .mysql) == "developer.user")

    let serviceAccount = GoogleCloudIdentity(
      email: "solnari-db@sample-project.iam.gserviceaccount.com"
    )
    #expect(serviceAccount.databaseUsername(for: .postgresql) == "solnari-db@sample-project.iam")
    #expect(serviceAccount.databaseUsername(for: .mysql) == "solnari-db")
  }

  @Test("자동 IAM 인증에서는 사용자가 입력했던 비밀번호도 연결에 전달하지 않는다")
  func automaticIAMNeverUsesPassword() {
    var draft = ConnectionDraft()
    draft.transport = .cloudSQL
    draft.useIAM = true
    draft.password = "must-not-be-used"
    #expect(draft.connectionPassword.isEmpty)

    draft.useIAM = false
    #expect(draft.connectionPassword == "must-not-be-used")
  }
}
