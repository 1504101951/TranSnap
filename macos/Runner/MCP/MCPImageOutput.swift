import CoreGraphics
import Foundation
import ImageIO

enum MCPImageOutput {
    static func fitted(width: Int, height: Int, detail: MCPDetail) -> (width: Int, height: Int) {
        let patch = Double(AppConstants.mcpTokenPatch)
        let budget = detail.tokenBudget
        let size = { (scale: Double) in
            (width: max(1, Int((Double(width) * scale).rounded())), height: max(1, Int((Double(height) * scale).rounded())))
        }
        let patches = { (size: (width: Int, height: Int)) in
            Int((Double(size.width) / patch).rounded(.up)) * Int((Double(size.height) / patch).rounded(.up))
        }
        var scale = min(
            1,
            Double(AppConstants.mcpImageMaxEdge) / Double(max(width, height)),
            (Double(budget) * patch * patch / (Double(width) * Double(height))).squareRoot()
        )
        while patches(size(scale)) > budget { scale *= 0.999 }
        return size(scale)
    }

    static func sourceRect(
        x: Int, y: Int, width: Int, height: Int, detail: MCPDetail, sourceWidth: Int, sourceHeight: Int
    ) -> CGRect? {
        let output = fitted(width: sourceWidth, height: sourceHeight, detail: detail)
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= output.width, y + height <= output.height else { return nil }
        let scaleX = Double(sourceWidth) / Double(output.width)
        let scaleY = Double(sourceHeight) / Double(output.height)
        let left = max(0, Int((Double(x) * scaleX).rounded(.down)))
        let top = max(0, Int((Double(y) * scaleY).rounded(.down)))
        let right = min(sourceWidth, Int((Double(x + width) * scaleX).rounded(.up)))
        let bottom = min(sourceHeight, Int((Double(y + height) * scaleY).rounded(.up)))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func reply(_ source: CGImage, options: MCPCaptureOptions) async throws -> MCPToolReply {
        let size = fitted(width: source.width, height: source.height, detail: options.detail)
        let png = options.output == .text
            ? nil
            : try PNGEncoding.data(try resize(source, to: size), scale: 1)
        guard options.output != .image else { return .image(png: png, markdown: nil) }
        let blocks = try await ScreenCaptureService.recognizeDocument(image: source)
        let markdown = text(
            blocks,
            scaleX: Double(size.width) / Double(source.width),
            scaleY: Double(size.height) / Double(source.height),
            size: size,
            includePositions: options.includePositions
        )
        return .image(png: png, markdown: markdown)
    }

    static func text(
        _ blocks: [ScreenCaptureService.OCRBlock], scaleX: Double, scaleY: Double,
        size: (width: Int, height: Int), includePositions: Bool
    ) -> String {
        guard !blocks.isEmpty else { return AppConstants.mcpNoTextMessage }
        guard includePositions else { return blocks.map(\.markdown).joined(separator: "\n\n") }
        let positioned = blocks.map { block in
            let x = Int((block.rect.minX * scaleX).rounded())
            let y = Int((block.rect.minY * scaleY).rounded())
            let width = Int((block.rect.width * scaleX).rounded())
            let height = Int((block.rect.height * scaleY).rounded())
            return "[\(x),\(y),\(width),\(height)]\n\(block.markdown)"
        }
        return (["[image \(size.width)×\(size.height)]"] + positioned).joined(separator: "\n\n")
    }

    static func image(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: AppConstants.errorDomain, code: 14, userInfo: [NSLocalizedDescriptionKey: AppConstants.mcpPixelReadFailedMessage])
        }
        return image
    }

    private static func resize(_ image: CGImage, to size: (width: Int, height: Int)) throws -> CGImage {
        guard size.width != image.width || size.height != image.height else { return image }
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: AppConstants.errorDomain, code: 15, userInfo: [NSLocalizedDescriptionKey: AppConstants.mcpScaleFailedMessage])
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let resized = context.makeImage() else {
            throw NSError(domain: AppConstants.errorDomain, code: 15, userInfo: [NSLocalizedDescriptionKey: AppConstants.mcpScaleFailedMessage])
        }
        return resized
    }
}
