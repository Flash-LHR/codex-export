import CodexExportFeature
import Foundation

@MainActor
final class UserDefaultsSoftwareUpdatePreferences:
    SoftwareUpdatePreferenceStoring
{
    private enum Key {
        // Deliberately distinct from the old visual-preview preference.
        static let automaticUpdatesEnabled = "automaticUpdatesEnabled.v1"
        static let knownAvailableVersion = "knownAvailableUpdateVersion.v1"
        static let knownAvailableBuild = "knownAvailableUpdateBuild.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var automaticUpdatesEnabled: Bool? {
        get {
            guard defaults.object(forKey: Key.automaticUpdatesEnabled) != nil
            else { return nil }
            return defaults.bool(forKey: Key.automaticUpdatesEnabled)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.automaticUpdatesEnabled)
            } else {
                defaults.removeObject(forKey: Key.automaticUpdatesEnabled)
            }
        }
    }

    var knownAvailableVersion: String? {
        get { defaults.string(forKey: Key.knownAvailableVersion) }
        set { defaults.set(newValue, forKey: Key.knownAvailableVersion) }
    }

    var knownAvailableBuild: Int? {
        get {
            guard defaults.object(forKey: Key.knownAvailableBuild) != nil
            else { return nil }
            return defaults.integer(forKey: Key.knownAvailableBuild)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.knownAvailableBuild)
            } else {
                defaults.removeObject(forKey: Key.knownAvailableBuild)
            }
        }
    }
}
