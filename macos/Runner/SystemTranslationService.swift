import Foundation
import OSLog
import Translation

@MainActor
final class SystemTranslationService {
    private var sessions: [String: TranslationSession] = [:]

    struct IncompleteResponse: Error {}

    private static let log = Logger(subsystem: "TranSnap", category: "SystemTranslation")

    func translate(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        defer { sessions[requestId] = nil }
        Self.log.notice("start id=\(requestId, privacy: .public) count=\(texts.count) \(source, privacy: .public)->\(target, privacy: .public)")
        let started = ContinuousClock.now
        do {
            let translations = try await translateWithRetry(requestId: requestId, texts: texts, source: source, target: target, strategy: strategy)
            Self.log.notice("end id=\(requestId, privacy: .public) ms=\(Self.milliseconds(since: started)) ok")
            return translations
        } catch {
            Self.log.notice("end id=\(requestId, privacy: .public) ms=\(Self.milliseconds(since: started)) error=\(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    private func translateWithRetry(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        do {
            return try await run(requestId: requestId, texts: texts, source: source, target: target, strategy: strategy)
        } catch {
            guard case TranslationError.notInstalled = error else { throw error }
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
            )
            guard status == .installed else { throw error }
            guard sessions[requestId] != nil else { throw CancellationError() }
            return try await run(requestId: requestId, texts: texts, source: source, target: target, strategy: strategy)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func run(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        let session = Self.makeSession(source: source, target: target, strategy: strategy)
        sessions[requestId] = session
        let requests = texts.indices.map {
            TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0))
        }
        let responses = try await session.translations(from: requests)
        var translations = [String?](repeating: nil, count: texts.count)
        for response in responses {
            guard let id = response.clientIdentifier, let index = Int(id), translations.indices.contains(index) else {
                continue
            }
            translations[index] = response.targetText
        }
        let complete = translations.compactMap { $0 }
        guard complete.count == texts.count else { throw IncompleteResponse() }
        return complete
    }

    func cancel(requestId: String) {
        sessions.removeValue(forKey: requestId)?.cancel()
    }

    nonisolated static func status(pairs: [[String]]) async -> [String] {
        let availability = LanguageAvailability()
        var statuses: [String] = []
        for pair in pairs {
            let status = await availability.status(
                from: Locale.Language(identifier: pair[0]), to: Locale.Language(identifier: pair[1])
            )
            switch status {
            case .installed:
                statuses.append(AppConstants.systemTranslationInstalled)
            case .supported:
                statuses.append(AppConstants.systemTranslationSupported)
            case .unsupported:
                statuses.append(AppConstants.systemTranslationUnsupported)
            @unknown default:
                statuses.append(AppConstants.systemTranslationUnsupported)
            }
        }
        return statuses
    }

    nonisolated static func errorCode(for error: Error) -> String {
        switch error {
        case TranslationError.notInstalled:
            return AppConstants.translationNotInstalledError
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            return AppConstants.translationUnsupportedError
        default:
            return AppConstants.translateFailedError
        }
    }

    private static func makeSession(source: String, target: String, strategy: String) -> TranslationSession {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        guard #available(macOS 26.4, *) else {
            return TranslationSession(installedSource: from, target: to)
        }
        let preferred: TranslationSession.Strategy = strategy == AppConstants.systemTranslationHighFidelity
            ? .highFidelity
            : .lowLatency
        return TranslationSession(installedSource: from, target: to, preferredStrategy: preferred)
    }
}
