import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let defaults: UserDefaults
    private let key = "factorial.clock.settings"
    private weak var logStore: AppLogStore?
    private let storedSettingsDecodingError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: key) {
            do {
                settings = try JSONDecoder.settingsDecoder.decode(AppSettings.self, from: data)
                storedSettingsDecodingError = nil
            } catch {
                settings = .defaultSettings
                storedSettingsDecodingError = error.localizedDescription
            }
        } else {
            settings = .defaultSettings
            storedSettingsDecodingError = nil
        }
    }

    func attachLogStore(_ logStore: AppLogStore) {
        self.logStore = logStore

        if let storedSettingsDecodingError {
            logStore.warning(
                "No se pudieron leer los ajustes guardados y se restauraron los valores por defecto: \(storedSettingsDecodingError)",
                source: "Ajustes"
            )
        }
    }

    func reset() {
        settings = .defaultSettings
    }

    func addHistory(_ attempt: ClockAttempt) {
        settings.history.insert(attempt, at: 0)

        if settings.history.count > 30 {
            settings.history = Array(settings.history.prefix(30))
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.settingsEncoder.encode(settings)
            defaults.set(data, forKey: key)
        } catch {
            logStore?.error(
                "No se pudieron guardar los ajustes: \(error.localizedDescription)",
                source: "Ajustes"
            )
        }
    }
}

extension JSONEncoder {
    static var settingsEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var settingsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
