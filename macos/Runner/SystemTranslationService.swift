import Foundation
import OSLog
import Translation

/// Apple 系统翻译：按语言对创建无界面 TranslationSession，在本机翻译一组段落。
/// 只按请求 ID 持有进行中的会话以便取消，不保存翻译业务状态；分片、配对与错误文案由 Dart 负责。
@MainActor
final class SystemTranslationService {
    /// 进行中的会话；键为 Dart 生成的请求 ID，完成、失败或取消后移除。
    private var sessions: [String: TranslationSession] = [:]

    /// 框架未返回某个段落的译文；整批按失败处理，Dart 不接受不完整结果。
    struct IncompleteResponse: Error {}

    /// 排查日志：每次请求的段数、语言对、耗时与结果，不写原文或译文（#138）。
    private static let log = Logger(subsystem: "TranslateApp", category: "SystemTranslation")

    /// requestId 定位会话，texts 为待译段落，source/target 为语言码（如 zh-CN、en），strategy 为策略协议值。
    /// 返回与 texts 下标一一对应的译文；语言包未安装、语言对不支持或框架失败时抛出错误，
    /// 等待重试期间请求被取消时抛出 CancellationError。
    func translate(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        defer { sessions[requestId] = nil }
        // 开始与结束各记一行；只有开始没有结束即为框架调用未返回。
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

    /// 参数与返回同 translate；执行翻译，冷启动误报未安装时确认已安装后重试一次。
    private func translateWithRetry(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        do {
            // run 新建会话并翻译整批段落。
            return try await run(requestId: requestId, texts: texts, source: source, target: target, strategy: strategy)
        } catch {
            guard case TranslationError.notInstalled = error else { throw error }
            // 系统翻译后台进程 translationd 空闲退出后冷启动时，框架在语言包状态加载完成前就报告未安装
            // （日志为 TranslationErrorDomain Code=16，语言状态未知），稍后同一请求可正常翻译。
            // 适用条件：查询到该语言对已安装才重试一次；Apple 修复该竞态，或 LanguageAvailability 冷启动时同样误报时重新评估（#1）。
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
            )
            guard status == .installed else { throw error }
            // cancel 在查询期间移除了本请求的会话：Dart 已放弃该请求，不再重试。
            guard sessions[requestId] != nil else { throw CancellationError() }
            return try await run(requestId: requestId, texts: texts, source: source, target: target, strategy: strategy)
        }
    }

    /// 作用：计算自 start 起经过的毫秒数。参数 start：起始时刻。返回：整数毫秒。
    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// 参数同 translate；新建会话并登记到 sessions 以便取消，返回与 texts 下标一一对应的译文；
    /// 框架失败或未返回某段译文时抛出错误。会话由 translate 在结束时移除。
    private func run(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        // makeSession 按系统版本决定是否带策略参数。
        let session = Self.makeSession(source: source, target: target, strategy: strategy)
        sessions[requestId] = session
        // clientIdentifier 为段落下标，响应据此对回原段，不依赖返回顺序。
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

    /// requestId 为 Dart 已放弃的请求；停止对应会话的本机计算，不存在时忽略，无返回值。
    func cancel(requestId: String) {
        sessions.removeValue(forKey: requestId)?.cancel()
    }

    /// pairs 为 [源语言, 目标语言] 列表；返回一一对应的安装状态协议值，不触发下载。
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
                // 框架新增的状态无法确认可用，按不支持提示，不尝试翻译。
                statuses.append(AppConstants.systemTranslationUnsupported)
            }
        }
        return statuses
    }

    /// error 为翻译抛出的错误；返回跨端错误码：语言包未安装、语言对不支持，其余为一般翻译失败。
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

    /// source/target 为语言码，strategy 为策略协议值；返回只使用已安装语言包的无界面会话。
    private static func makeSession(source: String, target: String, strategy: String) -> TranslationSession {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        // macOS 26.4 之前没有策略参数，由系统选择模型。
        guard #available(macOS 26.4, *) else {
            return TranslationSession(installedSource: from, target: to)
        }
        let preferred: TranslationSession.Strategy = strategy == AppConstants.systemTranslationHighFidelity
            ? .highFidelity
            : .lowLatency
        return TranslationSession(installedSource: from, target: to, preferredStrategy: preferred)
    }
}
