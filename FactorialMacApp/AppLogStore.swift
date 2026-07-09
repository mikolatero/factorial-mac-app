import Foundation
import WebKit

enum AppLogLevel: String, CaseIterable, Identifiable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .debug:
            "Debug"
        case .info:
            "Info"
        case .warning:
            "Warning"
        case .error:
            "Error"
        }
    }
}

struct AppLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: AppLogLevel
    let source: String
    let message: String
}

@MainActor
final class AppLogStore: ObservableObject {
    @Published private(set) var entries: [AppLogEntry] = []

    private let maxEntries = 500

    func debug(_ message: String, source: String = "App") {
        append(level: .debug, source: source, message: message)
    }

    func info(_ message: String, source: String = "App") {
        append(level: .info, source: source, message: message)
    }

    func warning(_ message: String, source: String = "App") {
        append(level: .warning, source: source, message: message)
    }

    func error(_ message: String, source: String = "App") {
        append(level: .error, source: source, message: message)
    }

    func append(level: AppLogLevel, source: String, message: String) {
        let entry = AppLogEntry(
            date: Date(),
            level: level,
            source: source,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        entries.insert(entry, at: 0)

        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    func clear() {
        entries.removeAll()
    }

    var plainText: String {
        entries
            .reversed()
            .map { entry in
                "[\(Self.formatter.string(from: entry.date))] [\(entry.level.title)] [\(entry.source)] \(entry.message)"
            }
            .joined(separator: "\n")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

final class JavaScriptLogMessageHandler: NSObject, WKScriptMessageHandler {
    weak var logStore: AppLogStore?

    init(logStore: AppLogStore? = nil) {
        self.logStore = logStore
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "factorialAppLog" else {
            return
        }

        let payload = message.body as? [String: Any]
        let level = Self.level(from: payload?["level"] as? String)
        let messageText = payload?["message"] as? String ?? String(describing: message.body)
        let source = payload?["source"] as? String ?? "JavaScript"
        let line = payload?["line"] as? NSNumber
        let column = payload?["column"] as? NSNumber
        let url = payload?["url"] as? String
        let suffix = Self.locationSuffix(url: url, line: line?.intValue, column: column?.intValue)

        Task { @MainActor [weak logStore] in
            logStore?.append(level: level, source: source, message: "\(messageText)\(suffix)")
        }
    }

    private static func level(from rawValue: String?) -> AppLogLevel {
        switch rawValue?.lowercased() {
        case "debug":
            .debug
        case "warn", "warning":
            .warning
        case "error":
            .error
        default:
            .info
        }
    }

    private static func locationSuffix(url: String?, line: Int?, column: Int?) -> String {
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanURL?.isEmpty == false || line != nil || column != nil else {
            return ""
        }

        var parts: [String] = []
        if let cleanURL, !cleanURL.isEmpty {
            parts.append(cleanURL)
        }
        if let line {
            if let column {
                parts.append("linea \(line), columna \(column)")
            } else {
                parts.append("linea \(line)")
            }
        }

        return " (\(parts.joined(separator: " - ")))"
    }
}
