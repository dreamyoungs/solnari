import Foundation

enum SolnariResources {
  static let bundle: Bundle = {
    if let resourceURL = Bundle.main.url(
      forResource: "Solnari_Solnari",
      withExtension: "bundle"
    ), let applicationBundle = Bundle(url: resourceURL) {
      return applicationBundle
    }
    return Bundle.module
  }()
}
