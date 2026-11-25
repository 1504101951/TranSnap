import AVFoundation
import Foundation
import VideoToolbox
import WebKit

enum WebMExporter {
    private static let keyFrameInterval: Int64 = 2_000_000
    private static let encodeQueueLimit = 4

    private static let colourTable: [String: [String: (name: String, code: UInt64)]] = [
        kCVImageBufferColorPrimariesKey as String: [
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String: ("bt709", 1),
            kCVImageBufferColorPrimaries_SMPTE_C as String: ("smpte170m", 6),
            kCVImageBufferColorPrimaries_EBU_3213 as String: ("bt470bg", 5),
        ],
        kCVImageBufferTransferFunctionKey as String: [
            kCVImageBufferTransferFunction_ITU_R_709_2 as String: ("bt709", 1),
            kCVImageBufferTransferFunction_sRGB as String: ("iec61966-2-1", 13),
        ],
    ]

    @MainActor
    static func export(source: URL, destination: URL, range: CMTimeRange?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GIFExporter.ExportError(message: "录制文件没有可读取的视频画面。")
        }
        let (size, dataRate) = try await track.load(.naturalSize, .estimatedDataRate)
        let assetDuration = try await asset.load(.duration)
        let window = range ?? CMTimeRange(start: .zero, duration: assetDuration)
        let duration = microseconds(window.duration)
        let width = Int(size.width), height = Int(size.height)
        let frames = try FrameSource(asset: asset, track: track, range: window, width: width, height: height)
        guard var next = try await frames.next() else { throw GIFExporter.ExportError(message: "所选区间没有视频画面。") }
        let colour = try colorimetry(of: next.source)
        let session = EncoderSession()
        try await session.load()
        let config: [String: Any] = [
            "codec": "vp8", "width": width, "height": height, "bitrate": Int(dataRate),
            "framerate": AppConstants.recordingFramesPerSecond, "latencyMode": "quality",
        ]
        guard try await session.begin(config: config, colorSpace: colour.webCodecs,
                                      keyFrameInterval: keyFrameInterval, queueLimit: encodeQueueLimit) else {
            throw GIFExporter.ExportError(message: "本机 WebKit 不支持 VP8 编码，无法导出 WebM。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let writer = try WebMWriter(url: destination, width: width, height: height, duration: duration, colour: colour.matroska)
        var count = 0
        while true {
            try Task.checkCancellation()
            let timestamp = max(0, microseconds(next.time - window.start))
            async let upcoming = frames.next()
            for frame in try await session.encode(next.pixels, timestamp: timestamp) { try writer.append(frame) }
            count += 1
            progress(Double(timestamp) / Double(duration))
            guard let frame = try await upcoming else { break }
            next = frame
        }
        for frame in try await session.finish() { try writer.append(frame) }
        try Task.checkCancellation()
        try writer.finish(expectedFrames: count)
        completed = true
        return count
    }

    private static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }

    private static func colorimetry(of buffer: CVPixelBuffer) throws -> (webCodecs: [String: Any], matroska: WebMWriter.Colour) {
        var names: [String: String] = [:]
        var codes: [String: UInt64] = [:]
        for (key, entries) in colourTable {
            let value = CVBufferCopyAttachment(buffer, key as CFString, nil) as? String
            guard let value, let entry = entries[value] else {
                throw GIFExporter.ExportError(message: "录制视频的色彩标注（\(value ?? "缺失")）无法写入 WebM。")
            }
            names[key] = entry.name
            codes[key] = entry.code
        }
        let primaries = kCVImageBufferColorPrimariesKey as String
        let transfer = kCVImageBufferTransferFunctionKey as String
        return (["matrix": "smpte170m", "primaries": names[primaries]!, "transfer": names[transfer]!, "fullRange": false],
                .init(matrix: 6, transfer: codes[transfer]!, primaries: codes[primaries]!))
    }

    fileprivate static let page = """
    <!doctype html><meta charset="utf-8"><script>
    let encoder = null, frameInit = null, failure = null, wake = null, lastKey = -Infinity, interval = 0, limit = 0;
    const produced = [];
    const base64 = (bytes) => {
      let text = '';
      for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
      return btoa(text);
    };
    const take = () => { if (failure) throw new Error(failure); return produced.splice(0); };
    async function begin(config, colorSpace, keyInterval, queueLimit) {
      if (!(await VideoEncoder.isConfigSupported(config)).supported) return false;
      encoder = new VideoEncoder({
        output: (chunk) => {
          const bytes = new Uint8Array(chunk.byteLength);
          chunk.copyTo(bytes);
          produced.push({ timestamp: chunk.timestamp, key: chunk.type === 'key', data: base64(bytes) });
        },
        error: (error) => { failure = error.message; if (wake) wake(); },
      });
      encoder.configure(config);
      frameInit = { format: 'NV12', codedWidth: config.width, codedHeight: config.height, colorSpace };
      interval = keyInterval;
      limit = queueLimit;
      return true;
    }
    async function step(timestamp) {
      const buffer = await (await fetch('/frame')).arrayBuffer();
      const frame = new VideoFrame(buffer, { ...frameInit, timestamp });
      const key = timestamp - lastKey >= interval;
      if (key) lastKey = timestamp;
      encoder.encode(frame, { keyFrame: key });
      frame.close();
      while (encoder.encodeQueueSize > limit && !failure) {
        await new Promise((resolve) => { wake = resolve; encoder.addEventListener('dequeue', resolve, { once: true }); });
      }
      return take();
    }
    async function finish() {
      await encoder.flush();
      encoder.close();
      return take();
    }
    </script>
    """
}

private final class FrameSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let transfer: VTPixelTransferSession
    private let converted: CVPixelBuffer

    init(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, width: Int, height: Int) throws {
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        var session: VTPixelTransferSession?
        var buffer: CVPixelBuffer?
        guard reader.startReading(),
              VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session,
              CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw GIFExporter.ExportError(message: reader.error?.localizedDescription ?? "无法读取录制视频。")
        }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        transfer = session
        converted = buffer
    }

    func next() async throws -> (pixels: Data, source: CVPixelBuffer, time: CMTime)? {
        while let sample = output.copyNextSampleBuffer() {
            guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard VTPixelTransferSessionTransferImage(transfer, from: source, to: converted) == noErr else {
                throw GIFExporter.ExportError(message: "录制视频的色彩转换失败。")
            }
            return (packed(converted), source, CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard reader.status == .completed else {
            throw GIFExporter.ExportError(message: reader.error?.localizedDescription ?? "读取录制视频失败。")
        }
        return nil
    }

    private func packed(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var data = Data(capacity: width * height * 3 / 2)
        for (plane, rows) in [(0, height), (1, height / 2)] {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<rows { data.append(base + row * stride, count: width) }
        }
        return data
    }
}

@MainActor
private final class EncoderSession: NSObject, WKNavigationDelegate {
    private let server = FrameServer()
    private let webView: WKWebView
    private var loading: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: AppConstants.webMEncoderScheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            webView.load(URLRequest(url: URL(string: "\(AppConstants.webMEncoderScheme)://encoder/index.html")!))
        }
    }

    func begin(config: [String: Any], colorSpace: [String: Any], keyFrameInterval: Int64, queueLimit: Int) async throws -> Bool {
        try await call("return await begin(config, colorSpace, interval, limit)", [
            "config": config, "colorSpace": colorSpace, "interval": keyFrameInterval, "limit": queueLimit,
        ]) as! Bool
    }

    func encode(_ frame: Data, timestamp: Int64) async throws -> [WebMWriter.Frame] {
        server.frame = frame
        return Self.frames(try await call("return await step(timestamp)", ["timestamp": timestamp]))
    }

    func finish() async throws -> [WebMWriter.Frame] {
        Self.frames(try await call("return await finish()", [:]))
    }

    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch let error as NSError {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw GIFExporter.ExportError(message: "WebM 编码失败：\(message)")
        }
    }

    private static func frames(_ value: Any?) -> [WebMWriter.Frame] {
        (value as! [[String: Any]]).map {
            WebMWriter.Frame(timestamp: ($0["timestamp"] as! NSNumber).int64Value, key: $0["key"] as! Bool,
                             data: Data(base64Encoded: $0["data"] as! String)!)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }
}

@MainActor
private final class FrameServer: NSObject, WKURLSchemeHandler {
    var frame = Data()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        let (status, type, body): (Int, String, Data) = switch url.path {
        case "/index.html": (200, "text/html", Data(WebMExporter.page.utf8))
        case "/frame": (200, "application/octet-stream", frame)
        default: (404, "text/plain", Data())
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type])!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class WebMWriter {
    struct Frame {
        let timestamp: Int64
        let key: Bool
        let data: Data
    }

    struct Colour {
        let matrix: UInt64
        let transfer: UInt64
        let primaries: UInt64
    }

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3, ebmlVersion: UInt32 = 0x4286, ebmlReadVersion: UInt32 = 0x42F7
        static let ebmlMaxIDLength: UInt32 = 0x42F2, ebmlMaxSizeLength: UInt32 = 0x42F3
        static let docType: UInt32 = 0x4282, docTypeVersion: UInt32 = 0x4287, docTypeReadVersion: UInt32 = 0x4285
        static let segment: UInt32 = 0x1853_8067, seekHead: UInt32 = 0x114D_9B74, seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966, timecodeScale: UInt32 = 0x2A_D7B1, duration: UInt32 = 0x4489
        static let muxingApp: UInt32 = 0x4D80, writingApp: UInt32 = 0x5741
        static let tracks: UInt32 = 0x1654_AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7
        static let trackUID: UInt32 = 0x73C5, trackType: UInt32 = 0x83, codecID: UInt32 = 0x86, flagLacing: UInt32 = 0x9C
        static let video: UInt32 = 0xE0, pixelWidth: UInt32 = 0xB0, pixelHeight: UInt32 = 0xBA, colour: UInt32 = 0x55B0
        static let matrixCoefficients: UInt32 = 0x55B1, range: UInt32 = 0x55B9
        static let transferCharacteristics: UInt32 = 0x55BA, primaries: UInt32 = 0x55BB
        static let cluster: UInt32 = 0x1F43_B675, timecode: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0, block: UInt32 = 0xA1, blockDuration: UInt32 = 0x9B, referenceBlock: UInt32 = 0xFB
        static let cues: UInt32 = 0x1C53_BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7, cueTrack: UInt32 = 0xF7, cueClusterPosition: UInt32 = 0xF1
    }

    private let handle: FileHandle
    private let durationMs: Int64
    private let segmentStart: UInt64
    private let cuesPositionField: UInt64
    private var cluster = Data()
    private var clusterTime: Int64?
    private var cuePoints = Data()
    private var held: Frame?
    private var lastTime: Int64?
    private var received = 0

    init(url: URL, width: Int, height: Int, duration: Int64, colour: Colour) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw GIFExporter.ExportError(message: "无法创建WebM，请检查磁盘空间与目录权限。")
        }
        handle = try FileHandle(forWritingTo: url)
        durationMs = Self.milliseconds(duration)
        let header = Self.element(ID.ebml, Self.uint(ID.ebmlVersion, 1) + Self.uint(ID.ebmlReadVersion, 1) +
            Self.uint(ID.ebmlMaxIDLength, 4) + Self.uint(ID.ebmlMaxSizeLength, 8) + Self.string(ID.docType, "webm") +
            Self.uint(ID.docTypeVersion, 4) + Self.uint(ID.docTypeReadVersion, 2))
        let segment = Self.id(ID.segment) + Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let seekHead = Self.element(ID.seekHead, Self.element(ID.seek,
            Self.element(ID.seekID, Self.id(ID.cues)) + Self.uint(ID.seekPosition, 0, width: 8)))
        let info = Self.element(ID.info, Self.uint(ID.timecodeScale, 1_000_000) + Self.float(ID.duration, Double(durationMs)) +
            Self.string(ID.muxingApp, "TranSnap") + Self.string(ID.writingApp, "TranSnap"))
        let colourElement = Self.element(ID.colour, Self.uint(ID.matrixCoefficients, colour.matrix) + Self.uint(ID.range, 1) +
            Self.uint(ID.transferCharacteristics, colour.transfer) + Self.uint(ID.primaries, colour.primaries))
        let tracks = Self.element(ID.tracks, Self.element(ID.trackEntry,
            Self.uint(ID.trackNumber, 1) + Self.uint(ID.trackUID, 1) + Self.uint(ID.trackType, 1) +
            Self.string(ID.codecID, "V_VP8") + Self.uint(ID.flagLacing, 0) +
            Self.element(ID.video, Self.uint(ID.pixelWidth, UInt64(width)) + Self.uint(ID.pixelHeight, UInt64(height)) + colourElement)))
        try handle.write(contentsOf: header + segment + seekHead + info + tracks)
        segmentStart = UInt64(header.count + segment.count)
        cuesPositionField = segmentStart + UInt64(seekHead.count - 8)
    }

    func append(_ frame: Frame) throws {
        if let held { try write(held, last: false) }
        held = frame
        received += 1
    }

    func finish(expectedFrames: Int) throws {
        guard received == expectedFrames, let held else {
            throw GIFExporter.ExportError(message: "WebM 编码器丢弃了 \(expectedFrames - received) 帧，帧时间无法与源一致，未保存结果。")
        }
        try write(held, last: true)
        try flushCluster()
        let cuesPosition = try handle.offset() - segmentStart
        try handle.write(contentsOf: Self.element(ID.cues, cuePoints))
        let segmentSize = try handle.offset() - segmentStart
        try handle.seek(toOffset: segmentStart - 8)
        try handle.write(contentsOf: Data([0x01]) + Self.bigEndian(segmentSize, width: 7))
        try handle.seek(toOffset: cuesPositionField)
        try handle.write(contentsOf: Self.bigEndian(cuesPosition, width: 8))
        try handle.close()
    }

    private func write(_ frame: Frame, last: Bool) throws {
        let time = Self.milliseconds(frame.timestamp)
        if frame.key || clusterTime.map({ time - $0 > Int64(Int16.max) }) ?? true {
            try flushCluster()
            clusterTime = time
            if frame.key { cuePoints += cuePoint(time: time, position: try handle.offset() - segmentStart) }
        }
        let relative = UInt16(bitPattern: Int16(time - clusterTime!))
        let blockHeader = Self.vint(1) + Data([UInt8(relative >> 8), UInt8(relative & 0xFF)])
        if last {
            var group = Self.element(ID.block, blockHeader + Data([0x00]) + frame.data) +
                Self.uint(ID.blockDuration, UInt64(durationMs - time))
            if !frame.key, let lastTime { group += Self.signed(ID.referenceBlock, lastTime - time) }
            cluster += Self.element(ID.blockGroup, group)
        } else {
            cluster += Self.element(ID.simpleBlock, blockHeader + Data([frame.key ? 0x80 : 0x00]) + frame.data)
        }
        lastTime = time
    }

    private func flushCluster() throws {
        guard let clusterTime else { return }
        try handle.write(contentsOf: Self.element(ID.cluster, Self.uint(ID.timecode, UInt64(clusterTime)) + cluster))
        cluster = Data()
    }

    private func cuePoint(time: Int64, position: UInt64) -> Data {
        Self.element(ID.cuePoint, Self.uint(ID.cueTime, UInt64(time)) +
            Self.element(ID.cueTrackPositions, Self.uint(ID.cueTrack, 1) + Self.uint(ID.cueClusterPosition, position)))
    }

    static func milliseconds(_ microseconds: Int64) -> Int64 { (microseconds + 500) / 1000 }

    private static func id(_ value: UInt32) -> Data {
        let bytes = bigEndian(UInt64(value), width: 4)
        return bytes.drop { $0 == 0 }
    }

    private static func vint(_ value: UInt64) -> Data {
        let length = (1...8).first { value < (UInt64(1) << (7 * UInt64($0))) - 1 }!
        var bytes = bigEndian(value, width: length)
        bytes[bytes.startIndex] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    private static func bigEndian(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    private static func element(_ id: UInt32, _ payload: Data) -> Data { Self.id(id) + vint(UInt64(payload.count)) + payload }

    private static func uint(_ id: UInt32, _ value: UInt64, width: Int? = nil) -> Data {
        let length = width ?? max(1, (64 - value.leadingZeroBitCount + 7) / 8)
        return element(id, bigEndian(value, width: length))
    }

    private static func signed(_ id: UInt32, _ value: Int64) -> Data {
        var bytes = bigEndian(UInt64(bitPattern: value), width: 8)
        while bytes.count > 1, let first = bytes.first, let second = bytes.dropFirst().first,
              (first == 0x00 && second & 0x80 == 0) || (first == 0xFF && second & 0x80 != 0) {
            bytes = bytes.dropFirst()
        }
        return element(id, Data(bytes))
    }

    private static func string(_ id: UInt32, _ value: String) -> Data { element(id, Data(value.utf8)) }

    private static func float(_ id: UInt32, _ value: Double) -> Data { element(id, bigEndian(value.bitPattern, width: 8)) }
}
