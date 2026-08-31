import AppKit
import SwiftUI

struct NewConnectionView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ConnectionDraft()
  @State private var testState: TestState = .idle
  @State private var adcIdentityState: ADCIdentityState = .idle
  @State private var autoFilledIAMUsername: String?
  @FocusState private var focusedField: FocusedField?

  private static let googleCloudIdentityResolver = GoogleCloudIdentityResolver()

  private enum FocusedField: Hashable {
    case connectionName
  }

  enum TestState: Equatable {
    case idle
    case testing
    case success(ConnectionMetadata)
    case failure(String)
  }

  private enum ADCIdentityState: Equatable {
    case idle
    case resolving
    case resolved(GoogleCloudIdentity)
    case unavailable
  }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader

      ScrollView {
        VStack(alignment: .leading, spacing: 23) {
          identitySection
          transportSection
          connectionDetails
          safetySection
          textAndLocaleSection
          securityNote
        }
        .padding(25)
      }

      sheetFooter
    }
    .frame(width: 720, height: 680)
    .background(SolnariTheme.panel)
    .onChange(of: draft.engine) {
      switch draft.engine {
      case .postgresql:
        draft.port = "5432"
        draft.kubernetesRemotePort = "5432"
      case .mysql:
        draft.port = "3306"
        draft.kubernetesRemotePort = "3306"
      case .sqlite:
        draft.port = ""
        draft.transport = .direct
        draft.securityPolicy = .localDevelopment
      }
      draft.clientEncoding = "Automatic"
      draft.preferredCharacterSet = "Database default"
      draft.preferredCollation = "Database default"
      applyResolvedADCIdentity()
    }
    .onChange(of: draft.transport) {
      if draft.transport != .direct {
        draft.securityPolicy = .standard
      }
      Task { await resolveADCIdentityIfNeeded() }
    }
    .onChange(of: draft.useIAM) {
      if draft.useIAM {
        draft.password = ""
        Task { await resolveADCIdentityIfNeeded() }
      } else {
        adcIdentityState = .idle
      }
    }
    .onChange(of: draft) {
      guard !isTesting, testState != .idle else { return }
      testState = .idle
    }
    .onAppear {
      focusedField = .connectionName
    }
  }

  private var sheetHeader: some View {
    HStack(spacing: 12) {
      SolnariMark(size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(settings.text("New connection"))
          .font(.title3.weight(.semibold))
        Text(settings.text("Connect a database through the path that fits your environment."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 22)
    .frame(height: 68)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var identitySection: some View {
    formSection(number: "01", title: "Database") {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          fieldLabel("Connection name")
          TextField(settings.text("Production database"), text: $draft.name)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .connectionName)
        }

        VStack(alignment: .leading, spacing: 7) {
          fieldLabel("Engine")
          Picker("", selection: $draft.engine) {
            ForEach(DatabaseEngine.allCases) { engine in
              Label(settings.text(engine.rawValue), systemImage: engine.symbol).tag(engine)
            }
          }
          .labelsHidden()
          .frame(width: 190)
        }
      }
    }
  }

  private var transportSection: some View {
    formSection(number: "02", title: "Network path") {
      VStack(spacing: 12) {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10
        ) {
          ForEach(ConnectionTransport.allCases) { transport in
            transportCard(transport)
          }
        }
        transportGuide
      }
    }
  }

  @ViewBuilder
  private var connectionDetails: some View {
    formSection(number: "03", title: "Connection details") {
      switch draft.transport {
      case .direct:
        directFields
      case .cloudSQL:
        cloudSQLFields
      case .ssh:
        sshFields
      case .kubernetes:
        kubernetesFields
      }
    }
  }

  private var directFields: some View {
    Group {
      if draft.engine == .sqlite {
        VStack(alignment: .leading, spacing: 7) {
          fieldLabel("SQLite database file")
          HStack(spacing: 8) {
            TextField("/Users/me/data.sqlite", text: $draft.database)
              .textFieldStyle(.roundedBorder)
            Button(settings.text("Open…")) { chooseExistingSQLiteFile() }
            Button(settings.text("New…")) { chooseNewSQLiteFile() }
          }
          Text(settings.text("An existing file is opened; a new file is created when needed."))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else {
        VStack(spacing: 14) {
          HStack(spacing: 14) {
            labeledField("Host", placeholder: "localhost", text: $draft.host)
            labeledField("Port", placeholder: defaultPort, text: $draft.port, width: 110)
          }
          databaseCredentialFields
          HStack(spacing: 14) {
            passwordField
            Toggle(isOn: $draft.requiresTLS) {
              Text(settings.text("Require TLS"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  private var cloudSQLFields: some View {
    VStack(spacing: 14) {
      HStack {
        HStack(spacing: 8) {
          Image(systemName: "person.crop.circle.badge.checkmark")
            .foregroundStyle(SolnariTheme.indigo)
          VStack(alignment: .leading, spacing: 1) {
            Text(settings.text("Google Cloud authentication"))
              .font(.system(size: 12, weight: .medium))
            Text(settings.text("Application Default Credentials"))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        adcIdentityStatus
      }
      .padding(10)
      .background(
        SolnariTheme.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      HStack(spacing: 14) {
        labeledField("Project", placeholder: "project-id", text: $draft.cloudProject)
        labeledField("Region", placeholder: "asia-northeast3", text: $draft.cloudRegion)
        labeledField("Cloud SQL instance", placeholder: "instance", text: $draft.cloudInstance)
      }
      HStack(spacing: 14) {
        labeledField("Database", placeholder: "app_production", text: $draft.database)
        labeledField(
          draft.useIAM ? "IAM database user" : "Database user",
          placeholder: iamDatabaseUserPlaceholder,
          text: $draft.user
        )
      }
      Toggle(isOn: $draft.useIAM) {
        Text(settings.text("Use automatic IAM database authentication"))
      }
      .font(.system(size: 12))
      if draft.useIAM {
        Text(settings.text("Automatic IAM authentication does not use a database password."))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        passwordField
      }
    }
  }

  @ViewBuilder
  private var adcIdentityStatus: some View {
    switch adcIdentityState {
    case .idle:
      Text(settings.text("Uses current ADC account"))
        .foregroundStyle(.secondary)
    case .resolving:
      HStack(spacing: 5) {
        ProgressView().controlSize(.mini)
        Text(settings.text("Checking ADC account…"))
      }
      .foregroundStyle(.secondary)
    case .resolved(let identity):
      VStack(alignment: .trailing, spacing: 1) {
        Text(identity.email)
          .font(.caption)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
        Text(
          settings.text(
            identity.source == .applicationDefaultCredentials
              ? "IAM database user filled automatically"
              : "Active gcloud account suggested; verify that it matches ADC"
          )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    case .unavailable:
      Text(settings.text("Enter the IAM database user manually"))
        .font(.caption)
        .foregroundStyle(SolnariTheme.orange)
    }
  }

  private var sshFields: some View {
    VStack(spacing: 14) {
      HStack(spacing: 14) {
        labeledField("Database host", placeholder: "postgres.private", text: $draft.host)
        labeledField("Port", placeholder: defaultPort, text: $draft.port, width: 110)
      }
      HStack(spacing: 14) {
        labeledField("SSH host", placeholder: "bastion.example.com", text: $draft.sshHost)
        labeledField("SSH port", placeholder: "22", text: $draft.sshPort, width: 110)
        labeledField("SSH user", placeholder: "ubuntu", text: $draft.sshUser)
      }
      databaseCredentialFields
      passwordField
      HStack {
        Label(
          settings.text("Uses keys from ~/.ssh and the system SSH agent"),
          systemImage: "key.horizontal"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var kubernetesFields: some View {
    VStack(spacing: 14) {
      Picker("", selection: $draft.kubernetesMode) {
        ForEach(KubernetesConnectionMode.allCases) { mode in
          Text(settings.text(mode.rawValue)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      HStack(spacing: 14) {
        labeledField("Kubernetes context", placeholder: "nks-prod", text: $draft.kubeContext)
        labeledField("Namespace", placeholder: "db-access", text: $draft.namespace)
      }

      if draft.kubernetesMode == .existingResource {
        HStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Resource type")
            Picker("", selection: $draft.kubernetesResourceKind) {
              ForEach(KubernetesResourceKind.allCases) { kind in
                Text(settings.text(kind.rawValue)).tag(kind)
              }
            }
            .labelsHidden()
            .frame(width: 130)
          }
          labeledField(
            "Resource name", placeholder: "admin-db-proxy",
            text: $draft.kubernetesResourceName)
          labeledField(
            "Remote port", placeholder: defaultPort,
            text: $draft.kubernetesRemotePort, width: 110)
        }
        databaseCredentialFields
        passwordField
      } else {
        HStack(spacing: 14) {
          labeledField("Database host", placeholder: "postgres.private", text: $draft.host)
          labeledField("Port", placeholder: defaultPort, text: $draft.port, width: 110)
        }
        databaseCredentialFields
        passwordField
        labeledField("Relay image", placeholder: "alpine/socat:1.8.0.3", text: $draft.relayImage)
      }

      HStack(spacing: 10) {
        Image(
          systemName: draft.kubernetesMode == .existingResource
            ? "checkmark.shield.fill" : "shippingbox.fill"
        )
        .foregroundStyle(SolnariTheme.indigo)
        VStack(alignment: .leading, spacing: 2) {
          Text(
            settings.text(
              draft.kubernetesMode == .existingResource
                ? "Existing Kubernetes resource" : "Experimental Kubernetes relay"
            )
          )
          .font(.system(size: 12, weight: .medium))
          Text(
            settings.text(
              draft.kubernetesMode == .existingResource
                ? "Solnari only opens a port-forward and does not create or delete resources."
                : "Solnari creates and removes a temporary Pod. Additional RBAC is required."
            )
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        Spacer()
        PillLabel("pods/portforward", symbol: "checkmark", tint: SolnariTheme.mint)
      }
      .padding(10)
      .background(
        SolnariTheme.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
    }
  }

  private var securityNote: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(SolnariTheme.mint)
      VStack(alignment: .leading, spacing: 2) {
        Text(settings.text("Credentials stay on this Mac"))
          .font(.caption.weight(.semibold))
        Text(
          settings.text(
            "Passwords are stored in Keychain. Codex receives schema metadata and proposed SQL, never connection credentials."
          )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      SolnariTheme.mint.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var safetySection: some View {
    formSection(number: "04", title: "Safety & access") {
      VStack(spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Security policy")
            Picker("", selection: $draft.securityPolicy) {
              ForEach(ConnectionSecurityPolicy.userSelectable) { policy in
                Label(settings.text(policy.rawValue), systemImage: policy.symbol).tag(policy)
              }
            }
            .labelsHidden()
          }
          VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Database access")
            Picker("", selection: $draft.accessLevel) {
              ForEach(DatabaseAccessLevel.userSelectable) { level in
                Label(settings.text(level.rawValue), systemImage: level.symbol).tag(level)
              }
            }
            .labelsHidden()
          }
        }

        HStack(alignment: .top, spacing: 9) {
          Image(systemName: draft.accessLevel.symbol)
            .foregroundStyle(draft.accessLevel.tint)
          Text(settings.text(safetyExplanation))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
    }
  }

  private var textAndLocaleSection: some View {
    formSection(number: "05", title: "Text & collation") {
      VStack(spacing: 14) {
        HStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Client encoding")
            Picker("", selection: $draft.clientEncoding) {
              ForEach(clientEncodingOptions, id: \.self) { option in
                Text(settings.text(option)).tag(option)
              }
            }
            .labelsHidden()
          }

          VStack(alignment: .leading, spacing: 7) {
            fieldLabel(characterSetLabel)
            Picker("", selection: $draft.preferredCharacterSet) {
              ForEach(characterSetOptions, id: \.self) { option in
                Text(settings.text(option)).tag(option)
              }
            }
            .labelsHidden()
          }

          VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Collation")
            Picker("", selection: $draft.preferredCollation) {
              ForEach(collationOptions, id: \.self) { option in
                Text(settings.text(option)).tag(option)
              }
            }
            .labelsHidden()
          }
        }

        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "character.book.closed")
            .foregroundStyle(SolnariTheme.indigo)
          Text(settings.text(textScopeExplanation))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }

        Toggle(isOn: $draft.auditTextSettings) {
          VStack(alignment: .leading, spacing: 2) {
            Text(settings.text("Audit table and column text settings after connecting"))
              .font(.system(size: 12, weight: .medium))
            Text(
              settings.text(
                "Show warnings for mixed encodings or collations in the schema explorer.")
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var transportGuide: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 0) {
        ForEach(Array(transportGuideNodes.enumerated()), id: \.offset) { index, node in
          VStack(spacing: 6) {
            Image(systemName: node.symbol)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(SolnariTheme.indigo)
              .frame(width: 34, height: 34)
              .background(SolnariTheme.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            Text(settings.text(node.title))
              .font(.system(size: 10, weight: .medium))
              .multilineTextAlignment(.center)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity)

          if index < transportGuideNodes.count - 1 {
            Image(systemName: "arrow.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
        }
      }

      Divider()

      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(SolnariTheme.indigo)
        VStack(alignment: .leading, spacing: 3) {
          Text(settings.text(transportGuideTitle))
            .font(.system(size: 11, weight: .semibold))
          Text(settings.text(transportGuideDescription))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(12)
    .background(SolnariTheme.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SolnariTheme.border))
  }

  private var transportGuideNodes: [(symbol: String, title: String)] {
    switch draft.transport {
    case .direct:
      draft.engine == .sqlite
        ? [("laptopcomputer", "This Mac"), ("doc.badge.gearshape", "SQLite database file")]
        : [
          ("laptopcomputer", "This Mac"), ("network", "Private or public network"),
          (draft.engine.symbol, "Database"),
        ]
    case .cloudSQL:
      [
        ("laptopcomputer", "This Mac"), ("shield.lefthalf.filled", "Cloud SQL Proxy"),
        ("cloud.fill", "Cloud SQL instance"),
      ]
    case .ssh:
      [
        ("laptopcomputer", "This Mac"), ("lock.shield.fill", "SSH bastion"),
        (draft.engine.symbol, "Private database"),
      ]
    case .kubernetes:
      draft.kubernetesMode == .existingResource
        ? [
          ("laptopcomputer", "This Mac"), ("shippingbox.fill", "Kubernetes API"),
          ("checkmark.shield.fill", "Existing resource"),
        ]
        : [
          ("laptopcomputer", "This Mac"), ("shippingbox.fill", "Kubernetes API"),
          ("arrow.left.arrow.right.square", "Relay pod"),
          (draft.engine.symbol, "Private database"),
        ]
    }
  }

  private var transportGuideTitle: String {
    switch draft.transport {
    case .direct:
      draft.engine == .sqlite
        ? "Best for a local SQLite database file."
        : "Best for local development and databases already reachable from this Mac."
    case .cloudSQL: "Best for Google Cloud SQL with Application Default Credentials."
    case .ssh: "Best when only a bastion host can reach the database."
    case .kubernetes: "Best when a Kubernetes cluster can reach a private database."
    }
  }

  private var transportGuideDescription: String {
    switch draft.transport {
    case .direct:
      draft.engine == .sqlite
        ? "Solnari opens the local file directly without a network connection."
        : "Solnari connects to the host and port directly. TLS can still protect traffic."
    case .cloudSQL:
      "Cloud SQL Auth Proxy opens a local secure endpoint and refreshes short-lived credentials automatically."
    case .ssh:
      "Solnari forwards a local port through your SSH agent without exposing the database publicly."
    case .kubernetes:
      draft.kubernetesMode == .existingResource
        ? "Solnari port-forwards an existing Service or Pod without creating or deleting cluster resources."
        : "Solnari creates a temporary relay pod and port-forward, then removes the pod when the session closes."
    }
  }

  private var clientEncodingOptions: [String] {
    switch draft.engine {
    case .postgresql: ["Automatic", "UTF8"]
    case .mysql: ["Automatic", "utf8mb4", "euckr", "latin1"]
    case .sqlite: ["Automatic", "UTF-8", "UTF-16le", "UTF-16be"]
    }
  }

  private var characterSetLabel: String {
    draft.engine == .mysql ? "Table character set" : "Database encoding"
  }

  private var characterSetOptions: [String] {
    switch draft.engine {
    case .postgresql: ["Database default", "UTF8", "EUC_KR", "LATIN1"]
    case .mysql: ["Database default", "utf8mb4", "utf8mb3", "euckr", "latin1"]
    case .sqlite: ["Database default", "UTF-8", "UTF-16le", "UTF-16be"]
    }
  }

  private var collationOptions: [String] {
    switch draft.engine {
    case .postgresql: ["Database default", "ko-KR-x-icu", "en-US-x-icu", "C"]
    case .mysql: ["Database default", "utf8mb4_0900_ai_ci", "utf8mb4_unicode_ci", "utf8mb4_bin"]
    case .sqlite: ["Database default", "BINARY", "NOCASE", "RTRIM"]
    }
  }

  private var textScopeExplanation: String {
    switch draft.engine {
    case .postgresql:
      "PostgreSQL encoding is database-level; tables inherit it, while columns and expressions may use different collations."
    case .mysql:
      "MySQL can set character sets and collations per database, table, and column. Solnari will surface every override."
    case .sqlite:
      "SQLite stores database text as UTF-8 or UTF-16 and applies BINARY, NOCASE, or RTRIM collations per column or expression."
    }
  }

  private var safetyExplanation: String {
    if draft.securityPolicy == .standard, draft.transport == .direct,
      draft.engine != .sqlite, !isLoopbackHost, !draft.requiresTLS
    {
      return "Standard policy requires TLS for a remote direct connection. "
        + "Loopback development remains available without TLS."
    }
    switch draft.accessLevel {
    case .readOnly:
      return "Read-only validates SQL before execution and configures the database session "
        + "to reject writes."
    case .readWrite:
      return "Read/write allows changing SQL. "
        + "The database role remains the final permission boundary."
    case .migration:
      return "Migration access is reserved for a separate reviewed workflow."
    }
  }

  private var isLoopbackHost: Bool {
    ["localhost", "127.0.0.1", "::1"].contains(
      draft.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  private var sheetFooter: some View {
    HStack {
      switch testState {
      case .idle:
        Text(
          settings.text(
            draft.supportsSelectedTransport
              ? "Test the path before saving."
              : "SQLite supports direct file connections only.")
        )
        .foregroundStyle(.secondary)
      case .testing:
        ProgressView().controlSize(.small)
        Text(settings.text("Testing connection…"))
          .foregroundStyle(.secondary)
      case .success(let metadata):
        Label(
          "\(settings.text("Connected in")) \(metadata.latencyMilliseconds) ms",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(SolnariTheme.mint)
      case .failure(let message):
        Label(settings.text(message), systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .lineLimit(2)
          .frame(maxWidth: 300, alignment: .leading)
      }
      Spacer()
      Button(settings.text("Cancel")) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(settings.text("Test connection")) {
        Task {
          let testedDraft = draft
          testState = .testing
          do {
            let metadata = try await model.testConnection(testedDraft)
            testState = draft == testedDraft ? .success(metadata) : .idle
          } catch {
            testState = draft == testedDraft ? .failure(error.localizedDescription) : .idle
          }
        }
      }
      .disabled(isTesting || !draft.isValid)
      Button(settings.text("Save & connect")) {
        Task {
          let savedDraft = draft
          testState = .testing
          do {
            try await model.saveAndConnect(savedDraft)
            dismiss()
          } catch {
            testState = .failure(error.localizedDescription)
          }
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(SolnariTheme.indigo)
      .disabled(isTesting || !draft.isValid)
    }
    .font(.caption)
    .padding(.horizontal, 22)
    .frame(height: 62)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .top) { Divider() }
  }

  private var isTesting: Bool {
    if case .testing = testState { return true }
    return false
  }

  private func formSection<Content: View>(
    number: String, title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(SolnariTheme.indigo)
        .frame(width: 26, height: 26)
        .background(SolnariTheme.indigo.opacity(0.10), in: Circle())

      VStack(alignment: .leading, spacing: 12) {
        Text(settings.text(title))
          .font(.system(size: 13, weight: .semibold))
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func transportCard(_ transport: ConnectionTransport) -> some View {
    let isSelected = draft.transport == transport
    let isSupported = draft.engine != .sqlite || transport == .direct
    return Button {
      guard isSupported else { return }
      withAnimation(.easeOut(duration: 0.15)) { draft.transport = transport }
      testState = .idle
    } label: {
      HStack(spacing: 11) {
        Image(systemName: transport.symbol)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(isSelected ? SolnariTheme.indigo : .secondary)
          .frame(width: 30, height: 30)
          .background(
            (isSelected ? SolnariTheme.indigo : Color.secondary).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 2) {
          Text(settings.text(transport.rawValue))
            .font(.system(size: 12, weight: .semibold))
          Text(settings.text(transport.detail))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? SolnariTheme.indigo : Color.secondary.opacity(0.45))
      }
      .padding(10)
      .background(
        isSelected ? SolnariTheme.indigo.opacity(0.065) : SolnariTheme.elevated,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(isSelected ? SolnariTheme.indigo.opacity(0.55) : SolnariTheme.border)
      )
    }
    .buttonStyle(.plain)
    .disabled(!isSupported)
    .opacity(isSupported ? 1 : 0.45)
  }

  private func fieldLabel(_ title: String) -> some View {
    Text(settings.text(title))
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
  }

  private func labeledField(
    _ title: String, placeholder: String, text: Binding<String>, width: CGFloat? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      fieldLabel(title)
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
    }
    .frame(width: width)
    .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
  }

  private var databaseCredentialFields: some View {
    HStack(spacing: 14) {
      labeledField("Database", placeholder: "app_production", text: $draft.database)
      labeledField(
        "Database user", placeholder: draft.engine == .mysql ? "root" : "postgres",
        text: $draft.user)
    }
  }

  private var passwordField: some View {
    VStack(alignment: .leading, spacing: 7) {
      fieldLabel("Password")
      SecureField(settings.text("Stored in macOS Keychain"), text: $draft.password)
        .textFieldStyle(.roundedBorder)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var defaultPort: String {
    draft.engine == .mysql ? "3306" : "5432"
  }

  private var iamDatabaseUserPlaceholder: String {
    draft.engine == .mysql ? "user" : "user@example.com"
  }

  private func resolveADCIdentityIfNeeded() async {
    guard draft.transport == .cloudSQL, draft.useIAM else { return }
    if case .resolved = adcIdentityState {
      applyResolvedADCIdentity()
      return
    }
    adcIdentityState = .resolving
    let identity = await Self.googleCloudIdentityResolver.resolve()
    guard draft.transport == .cloudSQL, draft.useIAM else { return }
    if let identity {
      adcIdentityState = .resolved(identity)
      apply(identity)
    } else {
      adcIdentityState = .unavailable
    }
  }

  private func applyResolvedADCIdentity() {
    guard case .resolved(let identity) = adcIdentityState else { return }
    apply(identity)
  }

  private func apply(_ identity: GoogleCloudIdentity) {
    let username = identity.databaseUsername(for: draft.engine)
    let trimmedUser = draft.user.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedUser.isEmpty || draft.user == autoFilledIAMUsername {
      draft.user = username
      autoFilledIAMUsername = username
    }
  }

  private func chooseExistingSQLiteFile() {
    let panel = NSOpenPanel()
    panel.title = settings.text("Open SQLite database")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      draft.database = url.path
    }
  }

  private func chooseNewSQLiteFile() {
    let panel = NSSavePanel()
    panel.title = settings.text("Create SQLite database")
    panel.nameFieldStringValue = "database.sqlite"
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      draft.database = url.path
    }
  }
}
