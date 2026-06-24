import Foundation

final class Preferences {
    private enum Keys {
        static let modelName = "modelName"
        static let variantCount = "variantCount"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var modelName: String {
        get { defaults.string(forKey: Keys.modelName) ?? "claude-haiku-4-5-20251001" }
        set { defaults.set(newValue, forKey: Keys.modelName) }
    }

    var variantCount: Int {
        get { defaults.object(forKey: Keys.variantCount) as? Int ?? 3 }
        set { defaults.set(newValue, forKey: Keys.variantCount) }
    }
}
