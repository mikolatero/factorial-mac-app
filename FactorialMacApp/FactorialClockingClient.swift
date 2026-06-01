import Foundation
import WebKit

enum FactorialClockingError: LocalizedError {
    case notAuthenticated
    case graphqlError(String)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "La sesion de Factorial no esta iniciada o ha caducado."
        case .graphqlError(let message):
            message
        case .invalidResult:
            "Factorial devolvio una respuesta inesperada."
        }
    }
}

enum FactorialAuthState: Equatable {
    case unknown
    case loginRequired
    case authenticated
}

@MainActor
final class FactorialClockingClient: NSObject, ObservableObject {
    @Published private(set) var authState: FactorialAuthState = .unknown

    let webView: WKWebView

    private let baseURL = URL(string: "https://app.factorialhr.com")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func openLogin() {
        webView.load(URLRequest(url: baseURL))
    }

    func refreshAuthState() async {
        if webView.url == nil {
            openLogin()
            authState = .loginRequired
            return
        }

        do {
            let href = try await currentURLString()
            authState = href.isFactorialLoginURL ? .loginRequired : .authenticated
        } catch {
            authState = .unknown
        }
    }

    func clockIn(location: String) async throws {
        try await clock(.clockIn, location: location)
    }

    func clockOut(location: String) async throws {
        try await clock(.clockOut, location: location)
    }

    private func clock(_ kind: ClockEventKind, location: String) async throws {
        if webView.url == nil {
            openLogin()
            try await Task.sleep(for: .seconds(2))
        }

        try await refreshAuthBeforeClocking()

        let script = Self.graphQLClockScript(kind: kind, location: location)
        guard let result = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Any],
              let ok = result["ok"] as? Bool else {
            throw FactorialClockingError.invalidResult
        }

        if ok {
            authState = .authenticated
            return
        }

        let message = result["message"] as? String ?? "Factorial rechazo el fichaje."
        if statusCode(from: result) == 401 {
            if try await clockUsingFactorialUI(kind) {
                authState = .authenticated
                return
            }

            authState = .loginRequired
            throw FactorialClockingError.graphqlError(
                "\(message). La sesion web esta abierta, pero la sesion de fichaje ha caducado. Vuelve a cargar Factorial en la pestana Login."
            )
        }

        throw FactorialClockingError.graphqlError(message)
    }

    private func refreshAuthBeforeClocking() async throws {
        if webView.url == nil {
            openLogin()
        }

        let href = try await currentURLString()
        if href.isFactorialLoginURL {
            authState = .loginRequired
            throw FactorialClockingError.notAuthenticated
        }

        authState = .authenticated
    }

    private func currentURLString() async throws -> String {
        if let url = webView.url?.absoluteString {
            return url
        }

        let result = try await webView.evaluateJavaScript("window.location.href")
        return result as? String ?? ""
    }

    private func clockUsingFactorialUI(_ kind: ClockEventKind) async throws -> Bool {
        guard let result = try await webView.callAsyncJavaScript(
            Self.visibleClockButtonScript(kind: kind),
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Any],
              let ok = result["ok"] as? Bool else {
            throw FactorialClockingError.invalidResult
        }

        return ok
    }

    private func statusCode(from result: [String: Any]) -> Int? {
        if let status = result["status"] as? Int {
            return status
        }

        if let status = result["status"] as? NSNumber {
            return status.intValue
        }

        return nil
    }

    private static func graphQLClockScript(kind: ClockEventKind, location: String) -> String {
        let operationName = kind.operationName
        let mutation = kind.graphQLMutation
        let locationType = location.factorialLocationType

        return """
        const pad = (value) => String(value).padStart(2, "0");
        const formatNow = (date) => {
          const offsetMinutes = -date.getTimezoneOffset();
          const sign = offsetMinutes >= 0 ? "+" : "-";
          const absoluteOffset = Math.abs(offsetMinutes);
          return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
            `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
            `${sign}${pad(Math.floor(absoluteOffset / 60))}:${pad(absoluteOffset % 60)}`;
        };
        const formatDate = (date) => {
          return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
        };
        const extractErrors = (payload) => {
          if (payload?.errors?.length) {
            return payload.errors.map((error) => error.message || String(error)).join("\\n");
          }

          const mutationRoot = payload?.data?.attendanceMutations;
          const mutationPayload = mutationRoot?.clockInAttendanceShift || mutationRoot?.forgotClockOutAttendanceShift;
          const errors = mutationPayload?.errors || [];
          if (!errors.length) {
            return "";
          }

          return errors.map((error) => {
            if (error.message) {
              return error.message;
            }
            if (Array.isArray(error.messages)) {
              return `${error.field || "Error"}: ${error.messages.join(", ")}`;
            }
            return JSON.stringify(error);
          }).join("\\n");
        };

        const nowDate = new Date();
        const variables = {
          now: formatNow(nowDate),
          date: formatDate(nowDate),
          source: "desktop"
        };

        if ("\(operationName)" === "ClockIn") {
          variables.locationType = "\(locationType)";
        }

        const response = await fetch("https://api.factorialhr.com/graphql?\(operationName)", {
          method: "POST",
          credentials: "include",
          headers: {
            "accept": "*/*",
            "content-type": "application/json",
            "x-deployment-phase": "default",
            "x-factorial-bigint-support": "true",
            "x-factorial-origin": "web"
          },
          body: JSON.stringify({
            operationName: "\(operationName)",
            variables,
            query: "\(mutation.jsEscaped)"
          })
        });

        const payload = await response.json().catch(() => null);
        if (!response.ok) {
          return {
            ok: false,
            status: response.status,
            message: `Factorial respondio con HTTP ${response.status}`
          };
        }

        const errorMessage = extractErrors(payload);
        if (errorMessage) {
          return { ok: false, status: response.status, message: errorMessage };
        }

        return { ok: true, status: response.status };
        """
    }

    private static func visibleClockButtonScript(kind: ClockEventKind) -> String {
        let expectedLabels = kind.visibleActionLabels

        return """
        const normalize = (value) => (value || "")
          .normalize("NFD")
          .replace(/[\\u0300-\\u036f]/g, "")
          .toLowerCase()
          .replace(/\\s+/g, " ")
          .trim();

        if (normalize(window.location.href).includes("login")) {
          return { ok: false, authRequired: true, message: "La pagina de Factorial esta en login." };
        }

        const isVisible = (element) => {
          const style = window.getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.visibility !== "hidden" &&
            style.display !== "none" &&
            !element.disabled &&
            rect.width > 0 &&
            rect.height > 0;
        };

        const findClockingCard = (button) => {
          let node = button;
          for (let depth = 0; node && depth < 8; depth += 1, node = node.parentElement) {
            const text = normalize(node.innerText || node.textContent);
            if (text.includes("fichaje") || text.includes("attendance")) {
              return node;
            }
          }

          return button.parentElement || document.body;
        };

        const expectedLabels = \(expectedLabels.jsArrayLiteral);
        const clockButtonLabels = ["fichar", "clock in", "clock out", "check in", "check out"];
        const candidates = Array.from(document.querySelectorAll("button, a, [role='button']"))
          .filter(isVisible)
          .map((element) => ({
            element,
            text: normalize(element.innerText || element.textContent || element.getAttribute("aria-label"))
          }))
          .filter((candidate) => clockButtonLabels.some((label) => candidate.text.includes(label)));

        for (const candidate of candidates) {
          const card = findClockingCard(candidate.element);
          const cardText = normalize(card.innerText || card.textContent);
          const matchesExpectedAction = expectedLabels.some((label) => cardText.includes(label));

          if (!matchesExpectedAction) {
            continue;
          }

          candidate.element.click();
          await new Promise((resolve) => setTimeout(resolve, 1500));
          return { ok: true, clicked: true };
        }

        return {
          ok: false,
          actionMismatch: candidates.length > 0,
          message: "No se encontro un boton de fichaje visible que coincidiera con la accion esperada."
        };
        """
    }
}

extension FactorialClockingClient: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await refreshAuthState()
        }
    }
}

private extension String {
    var isFactorialLoginURL: Bool {
        let lowercased = lowercased()
        return lowercased.contains("login") ||
            lowercased.contains("signin") ||
            lowercased.contains("sign_in") ||
            lowercased.contains("oauth")
    }

    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    var jsArrayLiteral: String {
        let values = split(separator: "\n")
            .map { "\"\(String($0).jsEscaped)\"" }
            .joined(separator: ", ")

        return "[\(values)]"
    }

    var factorialLocationType: String {
        let normalized = folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("remot") || normalized.contains("casa") || normalized.contains("home") {
            return "remote"
        }

        if normalized.contains("viaj") || normalized.contains("travel") {
            return "business_trip"
        }

        return "office"
    }
}

private extension ClockEventKind {
    var operationName: String {
        switch self {
        case .clockIn:
            "ClockIn"
        case .clockOut:
            "ForgotClockOut"
        }
    }

    var graphQLMutation: String {
        switch self {
        case .clockIn:
            """
            mutation ClockIn($locationType: AttendanceShiftLocationTypeEnum, $now: ISO8601DateTime!, $projectTaskId: ID, $projectWorkerId: ID, $source: AttendanceEnumsShiftSourceEnum, $subprojectId: ID, $timeSettingsBreakConfigurationId: ID) {
              attendanceMutations {
                clockInAttendanceShift(
                  locationType: $locationType
                  now: $now
                  projectTaskId: $projectTaskId
                  projectWorkerId: $projectWorkerId
                  source: $source
                  subprojectId: $subprojectId
                  timeSettingsBreakConfigurationId: $timeSettingsBreakConfigurationId
                ) {
                  errors {
                    ...ErrorDetails
                    __typename
                  }
                  shift {
                    id
                    clockIn
                    clockOut
                    date
                    locationType
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }

            fragment ErrorDetails on MutationError {
              ... on SimpleError {
                message
                type
                __typename
              }
              ... on StructuredError {
                field
                messages
                __typename
              }
              __typename
            }
            """
        case .clockOut:
            """
            mutation ForgotClockOut($now: ISO8601DateTime!, $source: AttendanceEnumsShiftSourceEnum) {
              attendanceMutations {
                forgotClockOutAttendanceShift(now: $now, source: $source) {
                  errors {
                    ...ErrorDetails
                    __typename
                  }
                  shift {
                    id
                    clockIn
                    clockOut
                    date
                    locationType
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }

            fragment ErrorDetails on MutationError {
              ... on SimpleError {
                message
                type
                __typename
              }
              ... on StructuredError {
                field
                messages
                __typename
              }
              __typename
            }
            """
        }
    }

    var visibleActionLabels: String {
        switch self {
        case .clockIn:
            """
            entrada
            clock in
            check in
            """
        case .clockOut:
            """
            salida
            clock out
            check out
            """
        }
    }
}
