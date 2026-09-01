import AppKit
import SwiftUI

enum LicenseDocument: String, Identifiable {
  case solnari
  case thirdParty

  var id: String { rawValue }

  var fileName: String {
    switch self {
    case .solnari: "Solnari-LICENSE"
    case .thirdParty: "THIRD-PARTY-NOTICES"
    }
  }

  var titleKey: String {
    switch self {
    case .solnari: "Solnari license"
    case .thirdParty: "Open-source licenses"
    }
  }
}

struct LicenseDocumentView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var settings: AppSettings

  let document: LicenseDocument

  private var contents: String {
    LicenseDocumentLoader.contents(for: document)
      ?? settings.text("This license file is unavailable in this development build.")
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(settings.text(document.titleKey))
          .font(.headline)
        Spacer()
        Button(settings.text("Copy")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(contents, forType: .string)
        }
      }
      .padding(16)

      Divider()

      SelectableLicenseText(text: contents)

      Divider()

      HStack {
        Text(settings.text("License texts are included with every distributed app."))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(settings.text("Close")) {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(minWidth: 720, minHeight: 560)
  }
}

enum LicenseDocumentLoader {
  static func contents(for document: LicenseDocument) -> String? {
    let bundles = [Bundle.main, SolnariResources.bundle]
    for bundle in bundles {
      if let url = bundle.url(
        forResource: document.fileName,
        withExtension: "txt",
        subdirectory: "Licenses"
      ), let contents = try? String(contentsOf: url, encoding: .utf8) {
        return contents
      }
    }
    return nil
  }
}

private struct SelectableLicenseText: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.drawsBackground = false
    textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    textView.textContainerInset = NSSize(width: 14, height: 14)
    textView.textContainer?.widthTracksTextView = true
    textView.string = text

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView,
      textView.string != text
    else { return }
    textView.string = text
  }
}
