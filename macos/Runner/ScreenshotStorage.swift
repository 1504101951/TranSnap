import Foundation

enum ScreenshotStorage {
    static func rootDirectory(_ path: String?) -> URL {
        guard let path, !path.isEmpty else {
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("截图", isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    enum Category: String {
        case screenshot = "截图", video = "视频", gif, apng, webm

        init(_ export: RecordingExport) {
            switch export {
            case .mp4: self = .video
            case .gif: self = .gif
            case .apng: self = .apng
            case .webm: self = .webm
            }
        }
    }

    static func datedDirectory(basePath: String?, category: Category, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = rootDirectory(basePath).appendingPathComponent(category.rawValue, isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func publish(source: URL, target: URL) throws -> URL {
        let directory = target.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".TranSnap-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: staging)
        let stem = target.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let destination = suffix == 1 ? target : directory
                .appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(target.pathExtension)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                suffix += 1
            }
        }
    }

    static func save(_ data: Data, directory: URL, name: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              (name as NSString).pathExtension.lowercased() == "png" else {
            throw NSError(domain: AppConstants.errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "截图文件名必须是 PNG 文件名。"])
        }
        let stem = (name as NSString).deletingPathExtension
        var suffix = 1
        while true {
            let filename = suffix == 1 ? name : "\(stem)-\(suffix).png"
            let url = directory.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                suffix += 1
            }
        }
    }
}
