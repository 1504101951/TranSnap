import CoreGraphics
import Foundation
import ImageIO

enum ScreenshotComposer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let highlight = [UInt8]([153, 35, 29, 153]).withUnsafeBytes { $0.load(as: UInt32.self) }

    static func stitch(paths: [String], vertical: Bool) throws -> Data {
        guard paths.count >= 2 else { throw Failure(message: "拼接至少需要 2 张截图。") }
        let images = try paths.map(load)
        let width = vertical ? images.map(\.width).max()! : images.map(\.width).reduce(0, +)
        let height = vertical ? images.map(\.height).reduce(0, +) : images.map(\.height).max()!
        let context = try canvas(width: width, height: height, like: images[0])
        var offset = 0
        for image in images {
            let x = vertical ? (width - image.width) / 2 : offset
            let y = vertical ? height - offset - image.height : (height - image.height) / 2
            context.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
            offset += vertical ? image.height : image.width
        }
        guard let merged = context.makeImage() else { throw PNGEncoding.failure }
        return try PNGEncoding.data(merged)
    }

    static func split(path: String, parts: Int) throws -> [Data] {
        let image = try load(path)
        guard (2...10).contains(parts), parts <= image.height else {
            throw Failure(message: "段数需在 2–10 之间且不超过图片高度。")
        }
        let piece = image.height / parts
        return try (0..<parts).map { index in
            let top = index * piece
            let height = index == parts - 1 ? image.height - top : piece
            guard let part = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)) else {
                throw PNGEncoding.failure
            }
            return try PNGEncoding.data(part)
        }
    }

    static func compare(first: String, second: String) throws -> (mask: Data, different: Int, total: Int) {
        let a = try load(first), b = try load(second)
        let width = max(a.width, b.width), height = max(a.height, b.height)
        let left = try pixels(a, width: width, height: height)
        let right = try pixels(b, width: width, height: height)
        let inside = { (image: CGImage, x: Int, y: Int) in x < image.width && y < image.height }
        let context = try canvas(width: width, height: height, like: nil)
        let mask = context.data!.bindMemory(to: UInt32.self, capacity: width * height)
        var different = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if inside(a, x, y) && inside(b, x, y) && left[index] == right[index] { continue }
                different += 1
                mask[index] = highlight
            }
        }
        guard let diff = context.makeImage() else { throw PNGEncoding.failure }
        return (try PNGEncoding.data(diff), different, width * height)
    }

    private static func load(_ path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure(message: "图片文件不可读。") }
        return image
    }

    private static func canvas(width: Int, height: Int, like image: CGImage?) throws -> CGContext {
        let space = image?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure(message: "图片过大，无法处理。") }
        context.interpolationQuality = .none
        return context
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt32] {
        let context = try canvas(width: width, height: height, like: image)
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        return [UInt32](UnsafeBufferPointer(
            start: context.data!.bindMemory(to: UInt32.self, capacity: width * height),
            count: width * height
        ))
    }

}
