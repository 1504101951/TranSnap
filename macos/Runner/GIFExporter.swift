import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GIFExporter {
    enum Format {
        case gif, apng

        var label: String { self == .gif ? "GIF" : "APNG" }

        var kind: RecordingExport { self == .gif ? .gif : .apng }

        var pathKey: String { self == .gif ? "gifPath" : "apngPath" }

        var type: UTType { self == .gif ? .gif : .png }

        var fileProperties: CFDictionary {
            switch self {
            case .gif: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            case .apng: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary
            }
        }

        func frameProperties(delay: Double) -> CFDictionary {
            switch self {
            case .gif:
                [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]] as CFDictionary
            case .apng:
                [kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGDelayTime: delay,
                    kCGImagePropertyAPNGUnclampedDelayTime: delay,
                ]] as CFDictionary
            }
        }
    }

    struct Options {
        let framesPerSecond: Int
        let maximumWidth: Int?

        init(framesPerSecond: Int = 10, maximumWidth: Int? = nil) {
            self.framesPerSecond = framesPerSecond
            self.maximumWidth = maximumWidth
        }

        func validate(duration: Double, sourceWidth: Int) throws -> Int {
            guard duration.isFinite, duration > 0, sourceWidth > 0,
                  (1...30).contains(framesPerSecond), maximumWidth.map({ $0 > 0 }) ?? true else {
                throw ExportError(message: "GIF/APNG帧率须为1–30，最大宽度须为正整数或不限制。")
            }
            let count = max(1, ceil(duration * Double(framesPerSecond) - 1e-9))
            guard count.isFinite, count <= 1800 else {
                throw ExportError(message: "GIF/APNG最多1800帧，请在截图设置中降低帧率、缩短录制时长或裁剪。")
            }
            return Int(count)
        }
    }

    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func metadata(_ url: URL) async throws -> (duration: Double, width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError(message: "录制文件没有可读取的视频画面。")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = Int(abs(rect.width).rounded())
        let height = Int(abs(rect.height).rounded())
        guard width > 0, height > 0 else { throw ExportError(message: "视频尺寸无效。") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: .zero)
        return (duration, width, height)
    }

    static func export(source: URL, destination: URL, options: Options, format: Format = .gif,
                       range: CMTimeRange? = nil, progress: @escaping (Double) -> Void) async throws -> Int {
        let info = try await metadata(source)
        let start = range?.start.seconds ?? 0
        let duration = range?.duration.seconds ?? info.duration
        let count = try options.validate(duration: duration, sourceWidth: info.width)
        let outputWidth = min(info.width, options.maximumWidth ?? info.width)
        let outputHeight = max(1, Int((Double(info.height) * Double(outputWidth) / Double(info.width)).rounded()))
        guard outputWidth * outputHeight <= 33_554_432,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportError(message: "\(format.label)尺寸超过33554432像素，或临时输出已存在。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, format.type.identifier as CFString, count, nil) else {
            throw ExportError(message: "无法创建\(format.label)，请检查磁盘空间与目录权限。")
        }
        CGImageDestinationSetProperties(encoder, format.fileProperties)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: outputWidth, height: outputHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for index in 0..<count {
            try Task.checkCancellation()
            let offset = Double(index) / Double(options.framesPerSecond)
            let sample = try await generator.image(at: CMTime(seconds: start + offset, preferredTimescale: 60000))
            try Task.checkCancellation()
            let next = min(duration, Double(index + 1) / Double(options.framesPerSecond))
            let delay = max(0.01, (round(next * 100) - round(offset * 100)) / 100)
            CGImageDestinationAddImage(encoder, sample.image, format.frameProperties(delay: delay))
            progress(Double(index + 1) / Double(count))
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(encoder),
              let decoded = CGImageSourceCreateWithURL(destination as CFURL, nil),
              CGImageSourceGetCount(decoded) == count,
              CGImageSourceCreateImageAtIndex(decoded, count - 1, nil) != nil else {
            throw ExportError(message: "\(format.label)编码或文件校验失败，未发布结果。")
        }
        completed = true
        return count
    }

}
