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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder.settingsDecoder.decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .defaultSettings
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
        guard let data = try? JSONEncoder.settingsEncoder.encode(settings) else {
            return
        }

        defaults.set(data, forKey: key)
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
