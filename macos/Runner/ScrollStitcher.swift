import CoreGraphics
import Foundation

final class ScrollStitcher {
    struct Edges {
        let top: Int
        let bottom: Int
        let automatic: Bool
    }

    struct Failure: LocalizedError {
        let message: String
        var recoverable = false
        var errorDescription: String? { message }
    }

    private struct Frame {
        let image: CGImage
        let rows: [[Double]]
        let smoothed: [[Double]]

        init(_ image: CGImage) throws {
            self.image = image
            let width = image.width
            let height = image.height
            guard width >= 32, height >= 64,
                  width <= 32768, height <= 32768,
                  width * height <= 33_554_432 else {
                throw Failure(message: "选区尺寸不支持，请缩小区域；最长边32768像素、总像素33554432。")
            }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { throw Failure(message: "无法读取截图像素。") }
            let inset = max(1, width / 20)
            let columns = stride(from: inset, to: width - inset, by: max(1, (width - inset * 2) / 32))
            let sampled = (0..<height).map { y in
                columns.flatMap { x -> [Double] in
                    let offset = (y * width + x) * 4
                    return [Double(rgba[offset]), Double(rgba[offset + 1]), Double(rgba[offset + 2])]
                }
            }
            rows = sampled
            smoothed = sampled.indices.map { y in
                let above = sampled[max(0, y - 1)]
                let below = sampled[min(height - 1, y + 1)]
                return sampled[y].indices.map { (above[$0] + sampled[y][$0] * 2 + below[$0]) / 4 }
            }
        }
    }

    private let requested: Edges
    private var edges: Edges?
    private var first: Frame?
    private var previous: Frame?
    private var previousProbe: [Double]?
    private var strips: [CGImage] = []
    private(set) var acceptedFrames = 0
    private(set) var height = 0
    private var scrolled = 0.0
    private var appended = 0
    private(set) var lastShiftRatio = 0.0

    init(edges: Edges) { requested = edges }

    @discardableResult
    func append(_ image: CGImage) throws -> Bool {
        let probe = try Self.probe(image)
        if let previousProbe, let old = previous, old.image.width == image.width, old.image.height == image.height,
           zip(previousProbe, probe).reduce(0, { $0 + abs($1.0 - $1.1) }) / Double(probe.count) < 0.8 {
            return false
        }
        let current = try Frame(image)
        guard let old = previous else {
            guard requested.top >= 0, requested.bottom >= 0,
                  requested.top + requested.bottom <= image.height - 64 else {
                throw Failure(message: "顶部和底部固定区之间至少保留64像素正文。")
            }
            first = current
            previous = current
            previousProbe = probe
            acceptedFrames = 1
            height = image.height
            return false
        }
        guard old.image.width == image.width, old.image.height == image.height else {
            throw Failure(message: "捕获尺寸或显示倍率发生变化，请重新框选。")
        }
        if difference(old, current, oldStart: 0, newStart: 0, count: image.height, samples: 64) < 0.8 {
            return false
        }
        var selected: Edges
        if let edges {
            selected = edges
        }
        else if requested.automatic {
            let limit = image.height / 3
            var top = 0
            var bottom = 0
            while top < limit && rowDifference(old.rows[top], current.rows[top]) < 0.8 { top += 1 }
            while bottom < limit && rowDifference(old.rows[image.height - bottom - 1], current.rows[image.height - bottom - 1]) < 0.8 { bottom += 1 }
            selected = Edges(top: top, bottom: bottom, automatic: true)
        } else { selected = requested }
        var body = image.height - selected.top - selected.bottom
        let overlap = max(32, body / 4)
        guard body > overlap else { throw Failure(message: "正文区域不足以验证重叠，请调整固定边界。") }
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 1...(body - overlap) {
            let score = difference(old, current, oldStart: selected.top + shift,
                                   newStart: selected.top, count: body - shift, samples: 64, smoothed: true)
            if score < 8 { candidates.append((shift, score)) }
        }
        let verified = candidates.sorted { $0.score < $1.score }.prefix(12).map { candidate -> (shift: Int, score: Double, phase: Double) in
            let match = registration(old, current, oldStart: selected.top + candidate.shift,
                                     newStart: selected.top, count: body - candidate.shift, samples: 96)
            return (candidate.shift, match.score, match.phase)
        }.sorted { $0.score < $1.score }
        guard let best = verified.first, best.score < 3,
              !verified.dropFirst().contains(where: {
                  abs($0.shift - best.shift) > 2 && $0.score < max(best.score * 1.8, best.score + 0.3)
              }) else {
            throw Failure(message: "相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。",
                          recoverable: true)
        }
        let shiftRatio = Double(best.shift) / Double(body - overlap)
        let estimate = scrolled + Double(best.shift) + best.phase
        let advance = Int(estimate.rounded()) - appended
        guard advance >= 1 else { return false }
        if edges == nil && requested.automatic {
            let limit = image.height / 3
            var top = 0
            var bottom = 0
            for row in Array(0..<limit) + Array(image.height - limit..<image.height) {
                let isTop = row < limit
                let shifted = isTop ? row + best.shift : row - best.shift
                guard shifted >= 0, shifted < image.height else { continue }
                var run = 0
                let wholeRowStable = rowDifference(old.rows[row], current.rows[row]) < 0.8
                let minimumRun = wholeRowStable ? 1 : 3
                for column in stride(from: 0, through: old.rows[row].count, by: 3) {
                    let stationary = column < old.rows[row].count &&
                        sampleDifference(old.rows[row], current.rows[row], column: column) < 0.8
                    let moving = column < old.rows[row].count && (isTop
                        ? sampleDifference(old.rows[shifted], current.rows[row], column: column)
                        : sampleDifference(old.rows[row], current.rows[shifted], column: column)) >= 0.8
                    if stationary && moving { run += 1; continue }
                    if run >= minimumRun {
                        if isTop { top = max(top, row + 1) }
                        else { bottom = max(bottom, image.height - row) }
                    }
                    run = 0
                }
            }
            selected = Edges(top: top, bottom: bottom, automatic: true)
            body = image.height - selected.top - selected.bottom
            guard body - best.shift >= 32, registration(old, current, oldStart: selected.top + best.shift,
                newStart: selected.top, count: body - best.shift, samples: body).score < 3 else {
                throw Failure(message: "无法可靠区分固定区域与正文，已保留确认部分。")
            }
        }
        let texture = old.rows[selected.top..<(image.height - selected.bottom)].map { row in
            (row.max() ?? 0) - (row.min() ?? 0)
        }.reduce(0, +) / Double(body)
        guard texture >= 3 else { throw Failure(message: "正文缺少可识别细节，无法确认接缝。请调整选区。") }
        let nextHeight = height + advance
        guard nextHeight <= 32768, image.width * nextHeight <= 33_554_432 else {
            throw Failure(message: "长图达到资源上限：最长边32768像素、总像素33554432。已保留确认部分。")
        }
        if edges == nil, let first {
            strips.append(try copyStrip(first.image, y: selected.top, height: body))
            edges = selected
        }
        strips.append(try copyStrip(image, y: image.height - selected.bottom - advance, height: advance))
        previous = current
        previousProbe = probe
        acceptedFrames += 1
        height = nextHeight
        scrolled = estimate
        appended += advance
        lastShiftRatio = shiftRatio
        return true
    }

    func finish() throws -> (png: Data, width: Int, height: Int, frames: Int) {
        guard let first, let last = previous else { throw Failure(message: "还没有捕获到图像。") }
        let image: CGImage
        if let edges {
            let width = first.image.width
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(message: "无法分配长图内存，请缩短捕获范围。")
            }
            var pieces: [CGImage] = []
            if edges.top > 0 { pieces.append(try copyStrip(first.image, y: 0, height: edges.top)) }
            pieces.append(contentsOf: strips)
            if edges.bottom > 0 { pieces.append(try copyStrip(last.image, y: last.image.height - edges.bottom, height: edges.bottom)) }
            var y = 0
            context.interpolationQuality = .none
            for piece in pieces {
                context.draw(piece, in: CGRect(x: 0, y: height - y - piece.height, width: width, height: piece.height))
                y += piece.height
            }
            guard let result = context.makeImage() else { throw Failure(message: "无法合成长图。") }
            image = result
        } else { image = first.image }
        return (try PNGEncoding.data(image), image.width, image.height, acceptedFrames)
    }

    struct Preview {
        let image: CGImage
        let target: CGRect?
    }

    func preview(width: Int, maxHeight: Int, markTarget: Bool) -> Preview? {
        guard let first, let last = previous, width > 0, maxHeight > 0 else { return nil }
        let imageWidth = first.image.width
        let scale = min(1, Double(width) / Double(imageWidth))
        let outputWidth = max(1, Int((Double(imageWidth) * scale).rounded()))
        let rows = min(height, Int((Double(maxHeight) / scale).rounded(.down)))
        let outputHeight = max(1, min(maxHeight, Int((Double(rows) * scale).rounded())))
        var pieces: [CGImage] = []
        if let edges {
            if edges.top > 0, let top = first.image.cropping(to: CGRect(x: 0, y: 0, width: imageWidth, height: edges.top)) {
                pieces.append(top)
            }
            pieces.append(contentsOf: strips)
            if edges.bottom > 0, let bottom = last.image.cropping(
                to: CGRect(x: 0, y: last.image.height - edges.bottom, width: imageWidth, height: edges.bottom)) {
                pieces.append(bottom)
            }
        } else { pieces = [first.image] }
        guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        var bottom = 0.0
        for piece in pieces.reversed() {
            let pieceHeight = Double(piece.height) * scale
            context.draw(piece, in: CGRect(x: 0, y: bottom, width: Double(outputWidth), height: pieceHeight))
            bottom += pieceHeight
            if bottom >= Double(outputHeight) { break }
        }
        guard let image = context.makeImage() else { return nil }
        var target: CGRect?
        if markTarget {
            let fixed = edges ?? Edges(top: 0, bottom: 0, automatic: requested.automatic)
            let body = last.image.height - fixed.top - fixed.bottom
            let overlap = max(32, body / 4)
            let fromBottom = Double(fixed.bottom + overlap) * scale
            target = CGRect(x: 0, y: Double(outputHeight) - fromBottom, width: Double(outputWidth),
                            height: Double(overlap) * scale)
                .intersection(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        }
        return Preview(image: image, target: target)
    }

    func confirmedFrame() throws -> (png: Data, width: Int, height: Int, frames: Int) {
        guard let first else { throw Failure(message: "还没有捕获到图像。") }
        return (try PNGEncoding.data(first.image), first.image.width, first.image.height, acceptedFrames)
    }

    private func copyStrip(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        guard let crop = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)),
              let context = CGContext(data: nil, width: image.width, height: height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "无法保存长图条带。")
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        guard let result = context.makeImage() else { throw Failure(message: "无法保存长图条带。") }
        return result
    }

    private static func probe(_ image: CGImage) throws -> [Double] {
        let (width, height) = (32, 64)
        let inset = max(1, image.width / 20)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let body = image.cropping(to: CGRect(x: inset, y: 0, width: image.width - inset * 2, height: image.height)),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(body, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw Failure(message: "无法读取截图像素。") }
        return stride(from: 0, to: rgba.count, by: 4).flatMap { [Double(rgba[$0]), Double(rgba[$0 + 1]), Double(rgba[$0 + 2])] }
    }

    private func sampleDifference(_ a: [Double], _ b: [Double], column: Int) -> Double {
        (abs(a[column] - b[column]) + abs(a[column + 1] - b[column + 1]) + abs(a[column + 2] - b[column + 2])) / 3
    }

    private func rowDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    private func difference(_ a: Frame, _ b: Frame, oldStart: Int, newStart: Int, count: Int,
                            samples: Int, smoothed: Bool = false) -> Double {
        let step = max(1, count / samples)
        var total = 0.0
        var used = 0
        for offset in stride(from: 0, to: count, by: step) {
            total += smoothed
                ? rowDifference(a.smoothed[oldStart + offset], b.smoothed[newStart + offset])
                : rowDifference(a.rows[oldStart + offset], b.rows[newStart + offset])
            used += 1
        }
        return total / Double(used)
    }

    private func registration(_ a: Frame, _ b: Frame, oldStart: Int, newStart: Int, count: Int,
                              samples: Int) -> (score: Double, phase: Double) {
        let step = max(1, count / samples)
        var totals = [Double](repeating: 0, count: 16)
        var used = 0
        for offset in stride(from: 0, to: count, by: step) {
            let oldRow = a.smoothed[oldStart + offset]
            let newRow = b.smoothed[newStart + offset]
            let oldNext = a.smoothed[min(oldStart + offset + 1, a.smoothed.count - 1)]
            let newNext = b.smoothed[min(newStart + offset + 1, b.smoothed.count - 1)]
            for index in oldRow.indices {
                let delta = oldRow[index] - newRow[index]
                for oldQuarter in 0...3 {
                    for newQuarter in 0...3 {
                        totals[oldQuarter * 4 + newQuarter] += abs(delta
                            + (oldNext[index] - oldRow[index]) * Double(oldQuarter) / 4
                            - (newNext[index] - newRow[index]) * Double(newQuarter) / 4)
                    }
                }
            }
            used += 1
        }
        var bestIndex = 0
        for index in totals.indices where totals[index] < totals[bestIndex] { bestIndex = index }
        let score = totals[bestIndex] / Double(used) / Double(a.rows[0].count)
        return (score, Double(bestIndex / 4 - bestIndex % 4) / 4)
    }
}
