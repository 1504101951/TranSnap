import Cocoa
import CoreImage
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers
import FlutterMacOS
import ServiceManagement
import Translation
import XCTest

@testable import TranSnap

class RunnerTests: XCTestCase {
    @MainActor
    func testImportedImageDecodePreservesPixelsOrientationAndFirstFrame() throws {
        let transparent = try captureImageFixture(width: 3, height: 2, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        let png = NSMutableData()
        let encoded = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoded, transparent, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoded))
        let decoded = try ScreenshotWindowController.decodeImage(png as Data)
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.alphaInfo, .premultipliedFirst)
        XCTAssertEqual(decoded.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)
        let pixels = try XCTUnwrap(decoded.dataProvider?.data) as Data
        XCTAssertEqual(pixels[0], 0)
        XCTAssertEqual(pixels[1], 0)
        XCTAssertEqual(Int(pixels[2]), 128, accuracy: 1)
        XCTAssertEqual(Int(pixels[3]), 128, accuracy: 1)

        let red = try captureImageFixture(width: 3, height: 2, color: .red)
        let blue = try captureImageFixture(width: 3, height: 2, color: .blue)
        let gif = NSMutableData()
        let animation = try XCTUnwrap(CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(animation, red, nil)
        CGImageDestinationAddImage(animation, blue, nil)
        XCTAssertTrue(CGImageDestinationFinalize(animation))
        let first = try ScreenshotWindowController.decodeImage(gif as Data)
        let firstPixels = try XCTUnwrap(first.dataProvider?.data) as Data
        XCTAssertEqual(firstPixels[2], 255)
        XCTAssertEqual(firstPixels[0], 0)

        let tiff = NSMutableData()
        let oriented = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(oriented, red, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(oriented))
        let rotated = try ScreenshotWindowController.decodeImage(tiff as Data)
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 3)
        XCTAssertThrowsError(try ScreenshotWindowController.decodeImage(Data("invalid".utf8)))
    }

    @MainActor
    func testClipboardImageCreatesIndependentEditorAndCancelsPendingDecode() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let data = try screenshotFixture(width: 12, height: 8, color: .red)
        XCTAssertTrue(pasteboard.setData(data, forType: .png))
        let controller = ScreenshotWindowController(pasteboard: pasteboard)
        defer { controller.shutdown() }
        let cancelled = expectation(description: "图片取消后结束解码")
        controller.onCapturingChanged = { if !$0 { cancelled.fulfill() } }
        controller.openClipboardImage()
        controller.cancelCapture()
        await fulfillment(of: [cancelled], timeout: 10)
        controller.onCapturingChanged = nil
        var state: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) {
            state = $0 as? [String: Any]
        }
        XCTAssertNil(state?["id"])
        let loaded = expectation(description: "图片解码完成")
        controller.onCapturingChanged = { if !$0 { loaded.fulfill() } }
        controller.openClipboardImage()
        await fulfillment(of: [loaded], timeout: 10)
        controller.onCapturingChanged = nil
        let window = try await waitForScreenshotEditor()
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) {
            state = $0 as? [String: Any]
        }
        let id = try XCTUnwrap(state?["id"] as? String)
        XCTAssertEqual(state?["canCaptureMedia"] as? Bool, false)
        XCTAssertEqual(state?["width"] as? CGFloat, 12)
        XCTAssertEqual(state?["height"] as? CGFloat, 8)
        XCTAssertNil(controller.liveCaptureID)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(controller.isCurrentCapture(id))
        window.close()
        XCTAssertFalse(controller.isCurrentCapture(id))
    }
    @MainActor
    private func screenshotFixture(width: Int, height: Int, color: NSColor) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<width { for y in 0..<height { image.setColor(color, atX: x, y: y) } }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func captureImageFixture(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private func waitForScreenshotEditor() async throws -> NSWindow {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSApp.windows.contains { $0 is ScreenshotPanel && $0.isVisible }
        }, object: nil)
        await fulfillment(of: [visible], timeout: 6)
        return try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
    }

    @MainActor
    func testGlassTitlebarAppearanceAndContentLayout() throws {
        let previous = UserDefaults.standard.object(forKey: AppConstants.preferencesKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppConstants.preferencesKey) }
            else { UserDefaults.standard.removeObject(forKey: AppConstants.preferencesKey) }
        }
        let engine = FlutterEngine(name: "glass-window-test", project: nil, allowHeadlessExecution: false)
        defer { engine.shutDownEngine() }
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        NativeGlassFactory.installContent(flutter, in: window)
        let content = try XCTUnwrap(window.contentViewController as? NativeGlassWindowContent)
        for (mode, opacity) in [("dark", 0.2), ("light", 1.0), ("system", 0.8)] {
            UserDefaults.standard.set([AppConstants.glassAppearanceKey: mode, AppConstants.glassOpacityKey: opacity], forKey: AppConstants.preferencesKey)
            NativeGlassFactory.applyAppearance(to: window)
            XCTAssertEqual(window.appearance?.name, mode == "system" ? nil : (mode == "dark" ? NSAppearance.Name.darkAqua : NSAppearance.Name.aqua))
            XCTAssertEqual(content.windowCanvas.alphaValue, 1)
            let expectedWhite = mode == "dark" ? 23.0 / 255.0 : 247.0 / 255.0
            if mode != "system" {
                let canvasColor = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(content.windowCanvas.layer?.backgroundColor)))
                XCTAssertEqual(canvasColor.usingColorSpace(.sRGB)!.redComponent, expectedWhite, accuracy: 0.01)
            }
            XCTAssertEqual(flutter.view.alphaValue, 1)
            window.setContentSize(NSSize(width: 620, height: 540))
            content.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.windowCanvas.frame, content.view.bounds)
            XCTAssertEqual(flutter.view.frame.maxY, window.contentLayoutRect.maxY, accuracy: 0.5)
            XCTAssertNil(content.windowCanvas.hitTest(.zero))
            XCTAssertEqual(flutter.view.frame.width, content.windowCanvas.frame.width, accuracy: 0.5)
        }
    }

    @MainActor
    func testScreenshotPendingStartupCancellationKeepsOnlyLatestDraft() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let image = try captureImageFixture(width: 80, height: 60, color: .blue)
        for id in ["cancel-pending", "capture-pending"] {
            controller.seedCaptureForTesting(image: image, id: id, width: 80, height: 60, showEditor: true)
            if id == "cancel-pending" { controller.cancelCapture() }
            else { controller.closeForCapture() }
            XCTAssertFalse(controller.isCurrentCapture(id))
        }
        controller.seedCaptureForTesting(image: image, id: "latest", width: 80, height: 60, showEditor: true)
        _ = try await waitForScreenshotEditor()
        var state: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) {
            state = $0 as? [String: Any]
        }
        XCTAssertEqual(state?["id"] as? String, "latest")
        XCTAssertEqual((state?["pixels"] as? FlutterStandardTypedData)?.data, image.dataProvider?.data as Data?)
        XCTAssertEqual(state?["rowBytes"] as? Int, image.bytesPerRow)
        XCTAssertEqual(NSApp.windows.filter { $0 is ScreenshotPanel && $0.isVisible }.count, 1)
    }

    @MainActor
    func testCaptureShutdownCancelsPendingWarmup() async {
        let screenshot = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        let capture = CaptureWindowController(screenshot: screenshot)
        let before = Set(NSApp.windows.filter { $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) }.map(\.windowNumber))
        capture.prepareControls()
        capture.prepareControls()
        await capture.shutdown()
        await Task.yield()
        let after = Set(NSApp.windows.filter { $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) }.map(\.windowNumber))
        XCTAssertEqual(after, before)
        XCTAssertEqual(capture.service.phase, .idle)
        screenshot.shutdown()
    }

    @MainActor
    func testScreenshotDiagonalCursorUsesNativeFrameResize() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown(); NSCursor.arrow.set() }
        let image = try captureImageFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(image: image, id: "diagonal", width: 80, height: 60, showEditor: true)
        _ = try await waitForScreenshotEditor()
        for (direction, position) in [(AppConstants.resizeNorthWestSouthEast, NSCursor.FrameResizePosition.topLeft), (AppConstants.resizeNorthEastSouthWest, .topRight)] {
            NSCursor.arrow.set()
            var response: Any?
            controller.handle(FlutterMethodCall(methodName: AppConstants.setResizeCursorMethod, arguments: ["direction": direction])) { response = $0 }
            XCTAssertNil(response)
            let expected = NSCursor.frameResize(position: position, directions: .all)
            XCTAssertEqual(NSCursor.current.image.tiffRepresentation, expected.image.tiffRepresentation)
            XCTAssertEqual(NSCursor.current.hotSpot, expected.hotSpot)
            XCTAssertNotEqual(NSCursor.current.image.tiffRepresentation, NSCursor.arrow.image.tiffRepresentation)
        }
        var invalid: Any?
        controller.handle(FlutterMethodCall(methodName: AppConstants.setResizeCursorMethod, arguments: ["direction": "unknown"])) { invalid = $0 }
        XCTAssertTrue(invalid is FlutterError)
        controller.handle(FlutterMethodCall(methodName: AppConstants.closeScreenshotMethod, arguments: nil)) { _ in }
        XCTAssertEqual(NSCursor.current.image.tiffRepresentation, NSCursor.arrow.image.tiffRepresentation)
        controller.handle(FlutterMethodCall(methodName: AppConstants.setResizeCursorMethod, arguments: ["direction": AppConstants.resizeNorthWestSouthEast])) { _ in }
        XCTAssertEqual(NSCursor.current.image.tiffRepresentation, NSCursor.arrow.image.tiffRepresentation)
    }

    @MainActor
    func testScreenshotConfiguredShortcutConsumesOnlyItsScope() async throws {
        let previous = UserDefaults.standard.object(forKey: AppConstants.preferencesKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppConstants.preferencesKey) }
            else { UserDefaults.standard.removeObject(forKey: AppConstants.preferencesKey) }
        }
        UserDefaults.standard.set([String: Any](), forKey: AppConstants.preferencesKey)
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let image = try captureImageFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(image: image, id: "shortcut", width: 80, height: 60, showEditor: true)
        _ = try await waitForScreenshotEditor()
        var preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey)!
        let drawing: [String: Any] = ["shape": "filledCircle", "brushMode": "mosaic", "tools": ["arrow": ["color": 0xFF007AFF, "width": 5]]]
        preferences[AppConstants.screenshotDrawingKey] = drawing
        UserDefaults.standard.set(preferences, forKey: AppConstants.preferencesKey)
        var snapshot: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) { snapshot = $0 as? [String: Any] }
        XCTAssertEqual(snapshot?[AppConstants.screenshotDrawingKey] as? NSDictionary, drawing as NSDictionary)

        let one = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
        let two = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 19, keyDown: true))
        two.flags = .maskCommand
        XCTAssertNil(controller.filterScreenshotEvent(one))
        XCTAssertNil(controller.filterScreenshotEvent(two))
        let seven = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 26, keyDown: true))
        XCTAssertTrue(controller.filterScreenshotEvent(seven) === seven)
        let shifted = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
        shifted.flags = .maskShift
        XCTAssertTrue(controller.filterScreenshotEvent(shifted) === shifted)
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "shortcut", "active": true])) { _ in }
        XCTAssertTrue(controller.filterScreenshotEvent(one) === one)
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "shortcut", "active": false])) { _ in }
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "stale", "active": true])) { _ in }
        XCTAssertNil(controller.filterScreenshotEvent(two))
        controller.shutdown()
        XCTAssertTrue(controller.filterScreenshotEvent(one) === one)
    }

    @MainActor
    func testScreenshotKeysPreserveTypingAndTextEditing() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let image = try captureImageFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(image: image, id: "typing", width: 80, height: 60, showEditor: true)
        _ = try await waitForScreenshotEditor()
        for repeated in [false, true] {
            let typed = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
            typed.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            XCTAssertTrue(controller.filterScreenshotEvent(typed) === typed)
        }
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "typing", "active": true])) { _ in }
        let undo = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        undo.flags = .maskCommand
        XCTAssertTrue(controller.filterScreenshotEvent(undo) === undo)
        let enter = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        XCTAssertTrue(controller.filterScreenshotEvent(enter) === enter)
        controller.shutdown()
        XCTAssertTrue(controller.filterScreenshotEvent(enter) === enter)
    }

    @MainActor
    func testLongScreenshotResultWindowShowsAndSavesAfterCapture() async throws {
        let screenshot = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        let controller = CaptureWindowController(screenshot: screenshot)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongResult-\(UUID().uuidString)")
        let defaults = UserDefaults.standard
        let oldDirectory = defaults.object(forKey: AppConstants.screenshotSaveDirectoryKey)
        let oldPolicy = NSApp.activationPolicy()
        defaults.set(root.path, forKey: AppConstants.screenshotSaveDirectoryKey)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
            screenshot.shutdown()
            defaults.set(oldDirectory, forKey: AppConstants.screenshotSaveDirectoryKey)
            if NSApp.activationPolicy() != oldPolicy { _ = NSApp.setActivationPolicy(oldPolicy) }
            try? FileManager.default.removeItem(at: root)
        }
        _ = NSApp.setActivationPolicy(.accessory)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        let png = try screenshotFixture(width: 200, height: 2000, color: .white)
        for _ in 0...1 {
            let token = controller.service.id
            let editorsBefore = NSApp.windows.filter { $0 is ScreenshotPanel && $0.isVisible }.count
            controller.service.publishFinishedScroll(png: png, width: 200, height: 2000, frames: 3,
                failure: "相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。", token: token)
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                NSApp.windows.contains { $0.title == "长截图结果" && $0.isVisible }
            }, object: nil)
            await fulfillment(of: [visible], timeout: 6)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "长截图结果" && $0.isVisible })
            XCTAssertEqual(panel.level, .normal)
            XCTAssertTrue(panel.styleMask.contains(.titled))
            XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(NSApp.activationPolicy(), .regular)
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertTrue(try XCTUnwrap(panel.screen).visibleFrame.contains(panel.frame))
            XCTAssertEqual(NSApp.windows.filter { $0 is ScreenshotPanel && $0.isVisible }.count, editorsBefore)
            XCTAssertEqual(controller.service.phase, .imageReady)
            XCTAssertEqual((controller.service.snapshot()["imageBytes"] as? FlutterStandardTypedData)?.data, png)
            let copied = expectation(description: "复制长图")
            controller.handle(FlutterMethodCall(methodName: AppConstants.copyScreenshotMethod, arguments: ["id": token])) { value in
                XCTAssertFalse(value is FlutterError)
                copied.fulfill()
            }
            await fulfillment(of: [copied], timeout: 3)
            XCTAssertEqual(NSPasteboard.general.data(forType: .png), png)
            let saved = expectation(description: "保存长图")
            var path: String?
            controller.handle(FlutterMethodCall(methodName: AppConstants.saveScreenshotMethod,
                arguments: ["id": token, "name": "长截图.png"])) {
                path = ($0 as? [String: Any])?["savedPath"] as? String
                saved.fulfill()
            }
            await fulfillment(of: [saved], timeout: 3)
            let file = try XCTUnwrap(path)
            XCTAssertTrue(file.hasPrefix(root.appendingPathComponent("截图").path + "/"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), png)
            let ended = expectation(description: "红按钮关闭")
            controller.onActiveChanged = { active in
                if !active && controller.service.id != token { ended.fulfill() }
            }
            try XCTUnwrap(panel.standardWindowButton(.closeButton)).performClick(nil)
            await fulfillment(of: [ended], timeout: 3)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(controller.service.phase, .idle)
            XCTAssertEqual(NSApp.activationPolicy(), .accessory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file))
            controller.onActiveChanged = nil
        }
    }

    @MainActor
    func testScreenshotEscapeClosesColdWarmAndReusedEditor() async throws {
        let board = NSPasteboard.withUniqueName()
        let controller = ScreenshotWindowController(pasteboard: board)
        defer { controller.shutdown(); board.releaseGlobally() }
        let image = try captureImageFixture(width: 80, height: 60, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        for phase in ["cold", "warm", "reused"] {
            board.clearContents()
            board.setString("unchanged", forType: .string)
            controller.seedCaptureForTesting(image: image, id: phase, width: 80, height: 60, showEditor: true)
            _ = try await waitForScreenshotEditor()
            if phase == "warm" { try await Task.sleep(nanoseconds: 500_000_000) }
            let panel = try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
            panel.makeFirstResponder(nil)
            panel.resignKey()
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
            ))
            XCTAssertNil(controller.filterScreenshotEvent(try XCTUnwrap(event.cgEvent)))
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !controller.isCurrentCapture(phase) && !panel.isVisible
            }, object: nil)
            await fulfillment(of: [closed], timeout: 2)
            XCTAssertEqual(board.string(forType: .string), "unchanged")
            XCTAssertNil(board.data(forType: .png))
        }
    }

    @MainActor
    func testScreenshotReturnCopiesImageAndClosesFromNativeRoute() async throws {
        let board = NSPasteboard.withUniqueName()
        let controller = ScreenshotWindowController(pasteboard: board)
        defer { controller.shutdown(); board.releaseGlobally() }
        let image = try captureImageFixture(width: 80, height: 60, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        for keyCode: UInt16 in [36, 76] {
            let id = "return-\(keyCode)"
            board.clearContents()
            controller.seedCaptureForTesting(image: image, id: id, width: 80, height: 60, showEditor: true)
            _ = try await waitForScreenshotEditor()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let panel = try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
            var descendants = [try XCTUnwrap(panel.contentView)]
            var glassViews: [NativeGlassView] = []
            while let view = descendants.popLast() {
                if let glass = view as? NativeGlassView { glassViews.append(glass) }
                descendants.append(contentsOf: view.subviews)
            }
            XCTAssertFalse(glassViews.isEmpty)
            XCTAssertTrue(glassViews.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
            panel.makeFirstResponder(nil)
            panel.resignKey()
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode
            ))
            XCTAssertNil(controller.filterScreenshotEvent(try XCTUnwrap(event.cgEvent)))
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                board.data(forType: .png) != nil && !controller.isCurrentCapture(id) && !panel.isVisible
            }, object: nil)
            await fulfillment(of: [completed], timeout: 2)
            let copied = try XCTUnwrap(board.data(forType: .png))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: copied))
            XCTAssertEqual(decoded.pixelsWide, 80)
            XCTAssertEqual(decoded.pixelsHigh, 60)
            let color = try XCTUnwrap(decoded.colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.redComponent, 0.95)
            XCTAssertLessThan(color.blueComponent, 0.05)
        }
    }

    @MainActor
    func testScreenshotPinShortcutPreservesImageAndClosesWithoutCopyOrSave() async throws {
        let defaults = UserDefaults.standard
        let previousPreferences = defaults.object(forKey: AppConstants.preferencesKey)
        let previousDirectory = defaults.object(forKey: AppConstants.screenshotSaveDirectoryKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenshotPin-01a17aec-c9a5-72f3-b897-aa5e2c2e720d-\(UUID().uuidString)", isDirectory: true
        )
        let board = NSPasteboard.withUniqueName()
        let controller = ScreenshotWindowController(pasteboard: board)
        defer {
            controller.shutdown()
            board.releaseGlobally()
            if let previousPreferences { defaults.set(previousPreferences, forKey: AppConstants.preferencesKey) }
            else { defaults.removeObject(forKey: AppConstants.preferencesKey) }
            if let previousDirectory { defaults.set(previousDirectory, forKey: AppConstants.screenshotSaveDirectoryKey) }
            else { defaults.removeObject(forKey: AppConstants.screenshotSaveDirectoryKey) }
            try? FileManager.default.removeItem(at: root)
        }
        var preferences = previousPreferences as? [String: Any] ?? [:]
        preferences[AppConstants.screenshotToolbarColumnsKey] = nil
        defaults.set(preferences, forKey: AppConstants.preferencesKey)
        defaults.set(root.path, forKey: AppConstants.screenshotSaveDirectoryKey)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("existing.bin")
        let savedContents = Data([0, 1, 2, 255])
        try savedContents.write(to: sentinel)
        let existingFiles = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let clipboardImage = try screenshotFixture(width: 2, height: 3, color: .blue)
        XCTAssertTrue(board.setData(clipboardImage, forType: .png))
        XCTAssertTrue(board.setString("clipboard stays unchanged", forType: .string))
        let clipboardChangeCount = board.changeCount
        let image = try captureImageFixture(width: 80, height: 60, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        let id = "pin-shortcut"
        controller.seedCaptureForTesting(image: image, id: id, width: 80, height: 60, showEditor: true)
        _ = try await waitForScreenshotEditor()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
        XCTAssertTrue(controller.isCurrentCapture(id))
        XCTAssertEqual(controller.pins.count, 0)
        panel.makeFirstResponder(nil)
        panel.resignKey()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "4",
            charactersIgnoringModifiers: "4", isARepeat: false, keyCode: 21
        ))
        XCTAssertNil(controller.filterScreenshotEvent(try XCTUnwrap(event.cgEvent)))
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.pins.count == 1 && !controller.isCurrentCapture(id) && !panel.isVisible
        }, object: nil)
        await fulfillment(of: [completed], timeout: 2)
        let pin = try XCTUnwrap(controller.pins.firstPanel)
        XCTAssertTrue(pin.isVisible)
        let decoded = try XCTUnwrap(pin.imageViewForTesting.image?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(decoded.pixelsWide, 80)
        XCTAssertEqual(decoded.pixelsHigh, 60)
        let original = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(try XCTUnwrap(decoded.colorSpace.iccProfileData),
                       try XCTUnwrap(original.colorSpace.iccProfileData))
        let fullChannel = (1 << decoded.bitsPerSample) - 1
        for (x, y) in [(0, 0), (79, 0), (0, 59), (79, 59), (40, 30)] {
            var samples = [Int](repeating: 0, count: decoded.samplesPerPixel)
            decoded.getPixel(&samples, atX: x, y: y)
            XCTAssertEqual(samples, [fullChannel, 0, 0, fullChannel])
        }
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.isCurrentCapture(id))
        XCTAssertEqual(board.changeCount, clipboardChangeCount)
        XCTAssertEqual(board.data(forType: .png), clipboardImage)
        XCTAssertEqual(board.string(forType: .string), "clipboard stays unchanged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), existingFiles)
        XCTAssertEqual(try Data(contentsOf: sentinel), savedContents)
    }


    @MainActor
    func testCopyReadPreservesClipboardAfterCancellation() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let selection = "First paragraph.\n\nSecond paragraph."
        board.setString("original clipboard", forType: .string)
        let copied = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString(selection, forType: .string)
        }, accepts: { $0 == selection })
        XCTAssertEqual(copied, selection)
        XCTAssertEqual(board.string(forType: .string), "original clipboard")

        let requested = expectation(description: "copy requested")
        let pending = Task {
            await AccessibilitySelection.readByCopyingSelection(
                pasteboard: board, copy: { requested.fulfill() }, accepts: { $0 == selection }
            )
        }
        await fulfillment(of: [requested], timeout: 1)
        pending.cancel()
        board.clearContents()
        board.setString("new user clipboard", forType: .string)
        let cancelled = await pending.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(board.string(forType: .string), "new user clipboard")

        let unrelated = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString("not the selection", forType: .string)
        }, accepts: { $0 == selection })
        XCTAssertNil(unrelated)
        XCTAssertEqual(board.string(forType: .string), "new user clipboard")

        let overtaken = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString(selection, forType: .string)
        }, accepts: { _ in
            board.clearContents()
            board.setString("copied while reading", forType: .string)
            return true
        })
        XCTAssertNil(overtaken)
        XCTAssertEqual(board.string(forType: .string), "copied while reading")
    }

    @MainActor
    func testOverlayStaysAboveReorderedFloatingSource() throws {
        let source = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let overlay = OverlayPanelController()
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is TranslationPanel && !existing.contains(ObjectIdentifier($0)) })
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        defer { overlay.hide(sessionId: "stacking"); source.orderOut(nil) }
        for level in [NSWindow.Level.floating, .statusBar, .popUpMenu] {
            source.level = level
            for size in [NSSize(width: 84, height: 36), NSSize(width: 380, height: 360)] {
                overlay.show(at: NSPoint(x: 250, y: 450), size: size, sessionId: "stacking")
                source.orderFrontRegardless()
                let windows = try XCTUnwrap(NSWindow.windowNumbers(options: .allApplications))
                let overlayIndex = try XCTUnwrap(windows.firstIndex(of: NSNumber(value: panel.windowNumber)))
                let sourceIndex = try XCTUnwrap(windows.firstIndex(of: NSNumber(value: source.windowNumber)))
                XCTAssertLessThan(overlayIndex, sourceIndex, "翻译浮层被来源置顶窗口覆盖")
                XCTAssertFalse(panel.canBecomeKey)
                XCTAssertFalse(panel.canBecomeMain)
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, sourcePID)
            }
        }
    }

    @MainActor
    func testWindowRequestsRouteLocalFirstThenToApplication() throws {
        final class Messenger: NSObject, FlutterBinaryMessenger {
            func send(onChannel channel: String, message: Data?) {}
            func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
                callback?(FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope("from-main"))
            }
            func setMessageHandlerOnChannel(_ channel: String,
                                            binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 0 }
            func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
        }
        let previous = MacPlatformBridge.Shared.instance
        defer { MacPlatformBridge.Shared.instance = previous }
        let bridge = MacPlatformBridge.register(with: Messenger(), overlay: OverlayPanelController(),
                                                selectionMonitor: SelectionMonitor())
        var forwarded: Any?
        bridge.routeWindowRequest(FlutterMethodCall(methodName: AppConstants.vocabularyListMethod, arguments: nil)) {
            forwarded = $0
        }
        XCTAssertEqual(forwarded as? String, "from-main")
        var local: Any?
        bridge.routeWindowRequest(FlutterMethodCall(methodName: AppConstants.systemStatusMethod, arguments: nil)) {
            local = $0
        }
        XCTAssertNotNil((local as? [String: Any])?["accessibility"])
    }


    @MainActor
    func testCredentialsRoundTripAndSettingsRollback() throws {
        let id = "test-\(UUID().uuidString)"
        defer { try? MacPlatformBridge.storeCredentials(id: id, value: nil) }
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
        try MacPlatformBridge.storeCredentials(id: id, value: ["apiKey": "first"])
        XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), ["apiKey": "first"])
        try MacPlatformBridge.storeCredentials(id: id, value: ["apiKey": "second", "appId": "dummy"])
        XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), ["apiKey": "second", "appId": "dummy"])

        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        let preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey)
        let settings: [String: Any] = [
            AppConstants.automaticKey: false, AppConstants.shortcutKeyCodeKey: 128, AppConstants.shortcutModifiersKey: 6144,
            AppConstants.inputShortcutKeyCodeKey: 15, AppConstants.inputShortcutModifiersKey: 6144,
            AppConstants.screenshotShortcutKeyCodeKey: 1, AppConstants.screenshotShortcutModifiersKey: 6144,
            AppConstants.excludedAppsKey: [String: String](),
            AppConstants.launchAtLoginKey: [.enabled, .requiresApproval].contains(SMAppService.mainApp.status),
        ]
        for prior in [["apiKey": "original"], [:]] {
            try MacPlatformBridge.storeCredentials(id: id, value: prior)
            var response: Any?
            bridge.handle(FlutterMethodCall(methodName: AppConstants.applySettingsMethod, arguments: [
                "settings": settings, "credentials": [id: ["apiKey": "replacement"]],
            ])) { response = $0 }
            XCTAssertNotNil(response as? FlutterError)
            XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), prior)
        }
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) as NSDictionary?, preferences as NSDictionary?)
        try MacPlatformBridge.storeCredentials(id: id, value: nil)
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
        bridge.handle(FlutterMethodCall(methodName: AppConstants.applySettingsMethod, arguments: [
            "settings": settings, "credentials": [id: ["apiKey": "temporary"]],
        ])) { XCTAssertNotNil($0 as? FlutterError) }
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
    }


    @MainActor
    func testHotKeyConflictAcrossProcesses() throws {
        let child = Process()
        let output = Pipe()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        child.arguments = ["-e", """
        import AppKit
        import Carbon
        let app = NSApplication.shared
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(9, 6912, EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        print(status)
        fflush(stdout)
        _ = readLine()
        if let reference { UnregisterEventHotKey(reference) }
        """]
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
            if child.isRunning { child.terminate() }
        }
        let bytes = output.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0")
        let monitor = SelectionMonitor()
        try monitor.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(16, 11, 3))
        XCTAssertThrowsError(try monitor.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(9, 11, 3)))
        XCTAssertTrue(monitor.automatic)
    }

    @MainActor
    func testHotKeyConflictPreservesPreviousConfiguration() throws {
        let first = SelectionMonitor()
        let second = SelectionMonitor()
        let probe = SelectionMonitor()
        try first.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(7, 6, 3))
        try first.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(7, 6, 3))
        XCTAssertTrue(first.automatic)
        try first.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(3, 7, 6))
        try second.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(16, 13, 4))
        XCTAssertThrowsError(try second.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(7, 13, 4)))
        XCTAssertTrue(second.automatic)
        XCTAssertThrowsError(try probe.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(16, 14, 5)))
        XCTAssertThrowsError(try second.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(17, 17, 4)))
        XCTAssertTrue(second.automatic)
        withExtendedLifetime((first, second, probe)) {}
    }

    private func hotKeys(_ translate: UInt32, _ input: UInt32, _ screenshot: UInt32) -> [GlobalHotKey: SelectionMonitor.HotKeyBinding] {
        [
            .translate: SelectionMonitor.HotKeyBinding(keyCode: translate, modifiers: 6912),
            .input: SelectionMonitor.HotKeyBinding(keyCode: input, modifiers: 6912),
            .screenshot: SelectionMonitor.HotKeyBinding(keyCode: screenshot, modifiers: 6912),
        ]
    }

    @MainActor
    func testPasteReplacingSelectionRestoresClipboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("transnap-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("原剪贴板", forType: .string)
        var pasted: String?
        let sent = await AccessibilitySelection.pasteReplacingSelection("译文", pasteboard: pasteboard) {
            pasted = pasteboard.string(forType: .string)
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(pasted, "译文")
        XCTAssertEqual(pasteboard.string(forType: .string), "原剪贴板")
        _ = await AccessibilitySelection.pasteReplacingSelection("译文", pasteboard: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("用户新复制", forType: .string)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "用户新复制")
    }

    @MainActor
    func testDictionaryAndSaveFileRejectMissingArguments() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var codes: [String?] = []
        bridge.handle(FlutterMethodCall(methodName: AppConstants.lookupDefinitionMethod, arguments: [:])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.saveTextFileMethod, arguments: ["text": "a"])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        XCTAssertEqual(codes, [AppConstants.badArgsError, AppConstants.badArgsError])
    }

    @MainActor
    func testScreenshotHistoryFileActionsRejectMissingOrUnreadableFiles() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var codes: [String?] = []
        for method in [AppConstants.openFileMethod, AppConstants.revealFileMethod, AppConstants.copyImageFileMethod] {
            bridge.handle(FlutterMethodCall(methodName: method, arguments: [:])) {
                codes.append(($0 as? FlutterError)?.code)
            }
        }
        let changeCount = NSPasteboard.general.changeCount
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png").path
        bridge.handle(FlutterMethodCall(methodName: AppConstants.copyImageFileMethod, arguments: ["path": missing])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        XCTAssertEqual(codes, Array(repeating: AppConstants.badArgsError, count: 3) + [AppConstants.copyFailedError])
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    func testScreenshotTargetInitialSelection() throws {
        let frame = ScreenCaptureService.FreezeFrame(
            displayID: 7, scale: 2, image: try captureImageFixture(width: 200, height: 100, color: .white),
            pixelWidth: 200, pixelHeight: 100,
            displayFrame: NSRect(x: 0, y: 0, width: 100, height: 50),
            windowCrop: NSRect(x: 20, y: 10, width: 40, height: 30)
        )
        let pointer = ScreenshotTarget.pointerDisplay.selection(in: frame)
        XCTAssertEqual(pointer.crop, NSRect(x: 20, y: 10, width: 40, height: 30))
        XCTAssertFalse(pointer.selected)
        let display = ScreenshotTarget.display(7).selection(in: frame)
        XCTAssertEqual(display.crop, NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(display.selected)
        XCTAssertEqual(ScreenshotTarget.display(7).displayID, 7)
        XCTAssertNil(ScreenshotTarget.pointerDisplay.displayID)
    }

    func testSpeechVoiceUsesDefaultRegion() {
        XCTAssertEqual(SpeechService.voice(for: "en")?.language, "en-US")
        XCTAssertEqual(SpeechService.voice(for: "zh-TW")?.language, "zh-TW")
        XCTAssertEqual(SpeechService.voice(for: "ar")?.language.hasPrefix("ar"), true)
    }

    @MainActor
    func testToggleSpeechRejectsMissingArguments() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var response: Any?
        bridge.handle(FlutterMethodCall(methodName: AppConstants.toggleSpeechMethod, arguments: ["text": "Hello"])) { response = $0 }
        XCTAssertEqual((response as? FlutterError)?.code, AppConstants.badArgsError)
    }

    @MainActor
    func testReplaceSelectionRejectsStaleSession() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var response: Any?
        bridge.handle(FlutterMethodCall(methodName: AppConstants.replaceSelectionMethod, arguments: [
            "sessionId": "stale", "text": "译文",
        ])) { response = $0 }
        XCTAssertEqual(response as? String, "输入已结束，未替换原文。")
    }

    func testStickerImageDownscalesLongSide() throws {
        func makeImage(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let wide = try StickerImage.downscaled(makeImage(2048, 1024), maxPixels: 1024)
        XCTAssertEqual([wide.width, wide.height], [1024, 512])
        let exact = try StickerImage.downscaled(makeImage(600, 1024), maxPixels: 1024)
        XCTAssertEqual([exact.width, exact.height], [600, 1024])
    }

    func testInputStatusBubbleFrameAvoidsAnchor() {
        let visible = NSRect(x: 0, y: 0, width: 400, height: 300)
        let size = NSSize(width: 120, height: 28)
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 50, y: 100, width: 80, height: 20), area: visible),
                       NSRect(x: 50, y: 64, width: 120, height: 28))
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 50, y: 20, width: 80, height: 20), area: visible),
                       NSRect(x: 50, y: 48, width: 120, height: 28))
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 350, y: 100, width: 30, height: 20), area: visible),
                       NSRect(x: 280, y: 64, width: 120, height: 28))
        let short = NSRect(x: 0, y: 0, width: 400, height: 40)
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 50, y: 10, width: 80, height: 20), area: short),
                       NSRect(x: 50, y: 0, width: 120, height: 28))
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 20)
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 50, y: 5, width: 80, height: 10), area: tiny),
                       NSRect(x: 50, y: -8, width: 120, height: 28))
    }

    func testInputStatusBubbleAvailableAreaClipsToWindow() {
        let visible = NSRect(x: 0, y: 0, width: 400, height: 300)
        let size = NSSize(width: 120, height: 28)
        let window = NSRect(x: 100, y: 50, width: 200, height: 200)
        let area = InputStatusBubble.availableArea(visible: visible, window: window)
        XCTAssertEqual(area, window)
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 280, y: 150, width: 10, height: 20), area: area).minX, 180)
        XCTAssertEqual(InputStatusBubble.frame(size: size, anchor: NSRect(x: 20, y: 150, width: 10, height: 20), area: area).minX, 100)
        XCTAssertEqual(InputStatusBubble.availableArea(visible: visible, window: NSRect(x: 350, y: 0, width: 200, height: 100)),
                       NSRect(x: 350, y: 0, width: 50, height: 100))
        XCTAssertEqual(InputStatusBubble.availableArea(visible: visible, window: nil), visible)
        XCTAssertEqual(InputStatusBubble.availableArea(visible: visible, window: NSRect(x: 900, y: 0, width: 50, height: 50)), visible)
    }

    func testInputProgressSizeWrapsText() {
        XCTAssertEqual(InputStatusBubble.progressSize(textWidth: 39.4), NSSize(width: 78, height: 24))
    }

    @MainActor
    func testSelectionSourceSurvivesNativeEventEncoding() throws {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var payload: [String: Any]?
        _ = bridge.onListen(withArguments: nil) { payload = $0 as? [String: Any] }
        defer { _ = bridge.onCancel(withArguments: nil) }
        let apps = [NSRunningApplication.current, try XCTUnwrap(NSWorkspace.shared.frontmostApplication)]
        for app in apps {
            let expected = try XCTUnwrap(app.localizedName)
            XCTAssertFalse(expected.isEmpty)
            bridge.emitSelectionCaptured(text: "fixture", gesture: SelectionGesture.hotkey.rawValue,
                                         x: 0, y: 0, sourcePID: app.processIdentifier, sourceAppName: expected)
            let event = try XCTUnwrap(payload)
            let codec = FlutterStandardMessageCodec.sharedInstance()
            let encoded = try XCTUnwrap(codec.encode(event))
            let decoded = try XCTUnwrap(codec.decode(encoded) as? [String: Any])
            XCTAssertEqual(decoded["sourceAppName"] as? String, expected)
            bridge.emitSelectionCaptured(text: "fixture", gesture: SelectionGesture.hotkey.rawValue,
                                         x: 0, y: 0, sourcePID: -1, sourceAppName: expected)
            XCTAssertEqual(payload?["sourceAppName"] as? String, expected)

        }
    }

    func testAppearanceSnapshotCarriesOpaqueAccentColors() {
        let original = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: AppConstants.preferencesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppConstants.preferencesKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: AppConstants.preferencesKey)
        let snapshot = NativeGlassFactory.appearanceSnapshot()
        for key in [AppConstants.accentLightKey, AppConstants.accentDarkKey] {
            let argb = snapshot[key] as? Int
            XCTAssertNotNil(argb)
            XCTAssertEqual((argb ?? 0) >> 24 & 0xFF, 0xFF)
        }
        UserDefaults.standard.set([AppConstants.accentColorKey: "purple"], forKey: AppConstants.preferencesKey)
        let custom = NativeGlassFactory.appearanceSnapshot()
        XCTAssertEqual(custom[AppConstants.accentLightKey] as? Int, 0xFF95_3D96)
        XCTAssertEqual(custom[AppConstants.accentDarkKey] as? Int, 0xFFA5_50A7)
    }

    @MainActor
    func testDeviceLanguageDetection() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        bridge.handle(FlutterMethodCall(methodName: AppConstants.detectLanguageMethod, arguments: [
            "text": "Bonjour, cette application permet de traduire le texte sélectionné dans une autre langue sans interrompre votre travail.",
        ])) { value in
            XCTAssertEqual(value as? String, "fr")
        }
    }

    func testSystemTranslationErrorCodes() {
        XCTAssertEqual(SystemTranslationService.errorCode(for: TranslationError.notInstalled),
                       AppConstants.translationNotInstalledError)
        for unsupported in [TranslationError.unsupportedSourceLanguage,
                            TranslationError.unsupportedTargetLanguage,
                            TranslationError.unsupportedLanguagePairing] {
            XCTAssertEqual(SystemTranslationService.errorCode(for: unsupported),
                           AppConstants.translationUnsupportedError)
        }
        XCTAssertEqual(SystemTranslationService.errorCode(for: TranslationError.internalError),
                       AppConstants.translateFailedError)
        XCTAssertEqual(SystemTranslationService.errorCode(for: SystemTranslationService.IncompleteResponse()),
                       AppConstants.translateFailedError)
    }

    @MainActor
    func testSystemTranslationRejectsMalformedArguments() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var codes: [String?] = []
        bridge.handle(FlutterMethodCall(methodName: AppConstants.systemTranslateMethod, arguments: [
            "requestId": "r1", "source": "en", "target": "zh-CN", "strategy": AppConstants.systemTranslationHighFidelity,
        ])) { codes.append(($0 as? FlutterError)?.code) }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.systemTranslationStatusMethod, arguments: [
            "pairs": [["en"]],
        ])) { codes.append(($0 as? FlutterError)?.code) }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.cancelSystemTranslationMethod, arguments: [:])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        XCTAssertEqual(codes, Array(repeating: AppConstants.badArgsError, count: 3))
    }
    @MainActor
    func testOverlayPanelDoesNotBecomeKeyOrMain() {
        let panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 84, height: 36),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor
    func testOverlayContentSizePositionAndStaleCommands() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY + 100)
        let overlay = OverlayPanelController()
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        overlay.show(at: anchor, size: NSSize(width: 84, height: 36), sessionId: "s1")
        XCTAssertEqual(overlay.frame.size, NSSize(width: 84, height: 36))
        XCTAssertTrue(overlay.isPanelVisible)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, sourcePID)

        overlay.setCaptureHidden(true)
        overlay.show(at: anchor, size: NSSize(width: 84, height: 36), sessionId: "s1")
        XCTAssertFalse(overlay.isPanelVisible)
        overlay.setCaptureHidden(false)
        XCTAssertTrue(overlay.isPanelVisible)
        let top = overlay.frame.maxY
        overlay.resize(sessionId: "s1", size: NSSize(width: 320, height: 220))
        XCTAssertEqual(overlay.frame.maxY, top)
        let resultFrame = overlay.frame
        overlay.resize(sessionId: "old", size: NSSize(width: 900, height: 900))
        overlay.hide(sessionId: "old")
        XCTAssertEqual(overlay.frame, resultFrame)
        XCTAssertTrue(overlay.isPanelVisible)
        overlay.hide(sessionId: "s1")
        XCTAssertFalse(overlay.isPanelVisible)
    }

    @MainActor
    func testPassiveInvalidationOnlyClosesTriggerAndEscapeClosesResult() {
        for retained in [false, true] {
            let overlay = OverlayPanelController()
            let bridge = MacPlatformBridge(overlay: overlay, selectionMonitor: SelectionMonitor())
            var events: [[String: Any]] = []
            _ = bridge.onListen(withArguments: nil) { events.append($0 as! [String: Any]) }
            bridge.emitSelectionCaptured(text: "Hello", gesture: SelectionGesture.drag.rawValue, x: 300, y: 500, sourcePID: 100, sourceAppName: "Fixture")
            let sessionId = events.last!["sessionId"] as! String
            let show = FlutterMethodCall(methodName: AppConstants.showOverlayMethod, arguments: [
                "sessionId": sessionId, "x": 300.0, "y": 500.0, "width": 720.0, "height": 420.0,
            ])
            bridge.handle(show) { _ in }
            if retained {
                bridge.handle(FlutterMethodCall(methodName: AppConstants.retainOverlayMethod, arguments: ["sessionId": sessionId])) { _ in }
            }
            let frame = overlay.frame
            bridge.sourceApplicationChanged(to: 200)
            bridge.invalidateSelection()
            if retained {
                bridge.emitSelectionCaptured(text: "Ignored", gesture: SelectionGesture.selectAll.rawValue, x: 500, y: 600, sourcePID: 200, sourceAppName: "Other Fixture")
                XCTAssertTrue(overlay.isPanelVisible)
                XCTAssertEqual(overlay.frame, frame)
                XCTAssertTrue(bridge.hasSelection)
                XCTAssertTrue(bridge.retainsResult)
                bridge.invalidateSelection(eventType: AppConstants.escapePressedMethod)
            }
            XCTAssertFalse(overlay.isPanelVisible)
            XCTAssertFalse(bridge.hasSelection)
            XCTAssertFalse(bridge.retainsResult)
            XCTAssertEqual(events.last?["sessionId"] as? String, sessionId)
            bridge.handle(show) { _ in }
            XCTAssertFalse(overlay.isPanelVisible)
        }
    }

    @MainActor
    func testReplacementAndEscapeKeepSessionIdentity() {
        let overlay = OverlayPanelController()
        let bridge = MacPlatformBridge(overlay: overlay, selectionMonitor: SelectionMonitor())
        var events: [[String: Any]] = []
        _ = bridge.onListen(withArguments: nil) { events.append($0 as! [String: Any]) }
        bridge.emitSelectionCaptured(text: "first", gesture: SelectionGesture.drag.rawValue, x: 300, y: 500, sourcePID: 100, sourceAppName: "Fixture")
        let oldId = events.last!["sessionId"] as! String
        bridge.handle(FlutterMethodCall(methodName: AppConstants.retainOverlayMethod, arguments: ["sessionId": oldId])) { _ in }
        bridge.emitSelectionCaptured(text: "second", gesture: SelectionGesture.hotkey.rawValue, x: 300, y: 500, sourcePID: 100, sourceAppName: "Fixture")
        let newId = events.last!["sessionId"] as! String
        bridge.handle(FlutterMethodCall(methodName: AppConstants.showOverlayMethod, arguments: [
            "sessionId": newId, "x": 300.0, "y": 500.0, "width": 84.0, "height": 36.0,
        ])) { _ in }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.hideOverlayMethod, arguments: ["sessionId": oldId])) { _ in }
        XCTAssertTrue(overlay.isPanelVisible)
        bridge.invalidateSelection(eventType: AppConstants.escapePressedMethod)
        XCTAssertFalse(overlay.isPanelVisible)
        XCTAssertEqual(events.last?["type"] as? String, AppConstants.escapePressedMethod)
        XCTAssertEqual(events.last?["sessionId"] as? String, newId)
    }

    func testKeyboardSelectionGestures() {
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 0, modifiers: .command), .selectAll)
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 123, modifiers: .shift), .keyboard)
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 123, modifiers: [.shift, .option]), .keyboard)
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 115, modifiers: [.shift, .command]), .keyboard)
        XCTAssertNil(SelectionGesture.keyboardGesture(keyCode: 0, modifiers: .shift))
        XCTAssertNil(SelectionGesture.keyboardGesture(keyCode: 8, modifiers: .command))
        XCTAssertNil(SelectionGesture.keyboardGesture(keyCode: 123, modifiers: []))
    }

    func testTextSelectionContexts() {
        for roles in [["AXStaticText", "AXList"], ["AXWebArea"], ["AXTextArea"], []] {
            for hasAXText in [false, true] {
                XCTAssertFalse(TextSelectionContext.shouldCopySelection(
                    ancestorRoles: roles, hasAXText: hasAXText, allowCopy: false
                ))
            }
        }
        for roles in [["AXStaticText", "AXRow", "AXOutline"], ["AXCell", "AXTable"], ["AXBrowser"]] {
            XCTAssertFalse(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles))
            XCTAssertFalse(TextSelectionContext.shouldCopySelection(ancestorRoles: roles, hasAXText: false, allowCopy: true))
            XCTAssertFalse(TextSelectionContext.shouldCopySelection(ancestorRoles: roles, hasAXText: true, allowCopy: true))
        }
        for roles in [["AXTextArea"], ["AXStaticText", "AXWebArea"], ["AXStaticText", "AXList"]] {
            XCTAssertTrue(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles))
            XCTAssertTrue(TextSelectionContext.shouldCopySelection(ancestorRoles: roles, hasAXText: false, allowCopy: true))
        }
        XCTAssertTrue(TextSelectionContext.shouldCopySelection(ancestorRoles: ["AXStaticText", "AXWebArea"], hasAXText: true, allowCopy: true))
        XCTAssertFalse(TextSelectionContext.shouldCopySelection(ancestorRoles: ["AXTextArea"], hasAXText: true, allowCopy: true))

        XCTAssertTrue(TextSelectionContext.matchesCopiedSelection(
            axText: "• First item.• Second item.",
            copiedText: "First item.\nSecond item."
        ))
        XCTAssertTrue(TextSelectionContext.matchesCopiedSelection(
            axText: "Paragraph oneParagraph two",
            copiedText: "Paragraph one\n\nParagraph two"
        ))
        XCTAssertFalse(TextSelectionContext.matchesCopiedSelection(
            axText: "• First item.",
            copiedText: "Unrelated clipboard text"
        ))
        XCTAssertFalse(TextSelectionContext.matchesCopiedSelection(
            axText: "•",
            copiedText: ""
        ))
        XCTAssertTrue(TextSelectionContext.matchesCopiedSelection(
            axText: "Adding tests.已运行 1 个命令已运行 1 个命令The three new tests pass.",
            copiedText: "Adding tests.\n已运行 1 个命令\nThe three new tests pass."
        ))
        XCTAssertFalse(TextSelectionContext.matchesCopiedSelection(
            axText: "Adding tests for batching, ordering, and failure in the provider.",
            copiedText: "Adding tests."
        ))
        XCTAssertFalse(TextSelectionContext.matchesCopiedSelection(
            axText: "Adding tests.",
            copiedText: "Tests adding."
        ))
    }

    @MainActor
    func testScreenCaptureOcrReadsDrawnText() async throws {
        let image = NSImage(size: NSSize(width: 200, height: 60))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 200, height: 60))
        let text = "HelloOCR" as NSString
        text.draw(at: NSPoint(x: 8, y: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let recognized = try await ScreenCaptureService.recognizeText(image: ScreenCaptureService.decodeImage(png: png))
        XCTAssertTrue(recognized.contains("HelloOCR"), recognized)
        let blocks = try await ScreenCaptureService.recognizeBlocks(png: png)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue((blocks[0]["text"] as? String)?.contains("HelloOCR") == true, String(describing: blocks))
        XCTAssertGreaterThan((blocks[0]["width"] as? Double) ?? 0, 0)
        XCTAssertGreaterThan((blocks[0]["height"] as? Double) ?? 0, 0)
        let blank = NSImage(size: NSSize(width: 8, height: 8))
        blank.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 8, height: 8))
        blank.unlockFocus()
        let blankTiff = try XCTUnwrap(blank.tiffRepresentation)
        let blankBitmap = try XCTUnwrap(NSBitmapImageRep(data: blankTiff))
        let blankPng = try XCTUnwrap(blankBitmap.representation(using: .png, properties: [:]))
        let empty = try await ScreenCaptureService.recognizeText(image: ScreenCaptureService.decodeImage(png: blankPng))
        XCTAssertTrue(empty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func generatedCode(_ name: String, message: String, scale: CGFloat) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: name))
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
    }

    @MainActor
    func testDetectCodesReadsQRAndBarcodeInPositionOrder() async throws {
        let link = "https://example.com/a?b=1"
        let qr = try generatedCode("CIQRCodeGenerator", message: link, scale: 6)
        let bar = try generatedCode("CICode128BarcodeGenerator", message: "TRANSLATE-108", scale: 2)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 520, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 520))
        context.interpolationQuality = .none
        for x in [40, 360] {
            context.draw(qr, in: CGRect(x: x, y: 260, width: qr.width, height: qr.height))
        }
        context.draw(bar, in: CGRect(x: 40, y: 40, width: bar.width, height: bar.height))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let codes = try await ScreenCaptureService.detectCodes(image: ScreenCaptureService.decodeImage(png: png))
        XCTAssertEqual(codes, [
            ["symbology": "qr", "payload": link],
            ["symbology": "code128", "payload": "TRANSLATE-108"],
        ])
        let blank = try screenshotFixture(width: 64, height: 64, color: .white)
        let none = try await ScreenCaptureService.detectCodes(image: ScreenCaptureService.decodeImage(png: blank))
        XCTAssertEqual(none, [])
    }

    func testShortcutRejectsTextEditingCombinations() {
        let command: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048
        let editingMessage = "这个组合是全选、撤销、剪切、复制或粘贴快捷键，请换一个组合。"
        XCTAssertThrowsError(try SelectionMonitor.validateShortcut(keyCode: 8, modifiers: command)) {
            XCTAssertEqual($0.localizedDescription, editingMessage)
        }
        XCTAssertThrowsError(try SelectionMonitor.validateShortcut(keyCode: 9, modifiers: command | shift)) {
            XCTAssertEqual($0.localizedDescription, editingMessage)
        }
        do {
            try SelectionMonitor.validateShortcut(keyCode: 8, modifiers: command | option)
        } catch {
            XCTAssertNotEqual(error.localizedDescription, editingMessage)
        }
    }

    func testLanguageDetectionPrefersUserLanguages() {
        let user = ["zh-CN", "en"]
        XCTAssertEqual(LanguageDetection.resolve(
            hypotheses: [("en", 0.13), ("nl", 0.11), ("id", 0.10)], text: "hello", preferred: user), "en")
        XCTAssertEqual(LanguageDetection.resolve(
            hypotheses: [("zh-Hant", 0.80), ("zh-Hans", 0.20)], text: "你好", preferred: user), "zh-Hans")
        XCTAssertEqual(LanguageDetection.resolve(
            hypotheses: [("zh-Hant", 0.99)], text: "這是繁體中文", preferred: user), "zh-Hant")
        XCTAssertEqual(LanguageDetection.resolve(
            hypotheses: [("fr", 0.90)], text: "Bonjour", preferred: user), "fr")
        XCTAssertEqual(LanguageDetection.resolve(
            hypotheses: [("pl", 0.29), ("nl", 0.09), ("ro", 0.09)], text: "ok", preferred: user), "en")
        XCTAssertNil(LanguageDetection.resolve(
            hypotheses: [("pl", 0.29), ("nl", 0.09), ("ro", 0.09)], text: "ok", preferred: ["en", "fr"]))
    }

    func testLanguageDetectionHintsFavorUserLanguages() {
        let user = ["zh-CN", "en"]
        XCTAssertEqual(LanguageDetection.detect("Animation duration", preferred: user), "en")
        XCTAssertEqual(LanguageDetection.detect("Control center", preferred: user), "en")
        XCTAssertEqual(LanguageDetection.detect("Durata animației", preferred: user), "ro")
        XCTAssertEqual(LanguageDetection.detect("Impostazioni avanzate", preferred: user), "it")
        XCTAssertEqual(LanguageDetection.detect("設定を開く", preferred: user), "ja")
    }

    func testLanguageDetectionHintWeights() {
        let hints = LanguageDetection.hints(preferred: ["zh-CN", "pt-BR", "xx"])
        XCTAssertEqual(hints[NLLanguage("zh-Hans")], AppConstants.languageDetectionUserWeight)
        XCTAssertEqual(hints[NLLanguage("pt")], AppConstants.languageDetectionUserWeight)
        XCTAssertEqual(hints[NLLanguage("en")], AppConstants.languageDetectionPopularWeight)
        XCTAssertEqual(hints[NLLanguage("ro")], AppConstants.languageDetectionBaseWeight)
        XCTAssertNil(hints[NLLanguage("xx")])
        XCTAssertEqual(hints.count, AppConstants.languageDetectionAll.count)
    }

    func testScreenshotLinkAcceptsOnlyHttpLinksWithHost() {
        XCTAssertEqual(ScreenshotLink.url(from: "https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertNotNil(ScreenshotLink.url(from: "HTTP://EXAMPLE.COM"))
        for raw in ["https://", "example.com", "file:///etc/hosts", "javascript:alert(1)", "tel:10086", ""] {
            XCTAssertNil(ScreenshotLink.url(from: raw), raw)
        }
    }

    @MainActor
    private func composerFixture(_ directory: URL, _ name: String, width: Int, height: Int, color: NSColor) throws -> String {
        let url = directory.appendingPathComponent(name)
        try screenshotFixture(width: width, height: height, color: color).write(to: url)
        return url.path
    }

    private func composedPixel(_ png: Data, _ x: Int, _ y: Int) throws -> [Int] {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var samples = [Int](repeating: 0, count: rep.samplesPerPixel)
        rep.getPixel(&samples, atX: x, y: y)
        return samples
    }

    @MainActor
    func testScreenshotComposerStitchSplitAndCompare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        let wide = try composerFixture(directory, "wide.png", width: 40, height: 20, color: red)
        let small = try composerFixture(directory, "small.png", width: 20, height: 10, color: blue)

        let vertical = try ScreenshotComposer.stitch(paths: [wide, small], vertical: true)
        let verticalRep = try XCTUnwrap(NSBitmapImageRep(data: vertical))
        XCTAssertEqual([verticalRep.pixelsWide, verticalRep.pixelsHigh], [40, 30])
        XCTAssertEqual(try composedPixel(vertical, 39, 19), [255, 0, 0, 255])
        XCTAssertEqual(try composedPixel(vertical, 10, 20), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(vertical, 29, 29), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(vertical, 9, 25)[3], 0)
        XCTAssertEqual(try composedPixel(vertical, 30, 25)[3], 0)
        let horizontal = try ScreenshotComposer.stitch(paths: [wide, small], vertical: false)
        let horizontalRep = try XCTUnwrap(NSBitmapImageRep(data: horizontal))
        XCTAssertEqual([horizontalRep.pixelsWide, horizontalRep.pixelsHigh], [60, 20])
        XCTAssertEqual(try composedPixel(horizontal, 40, 5), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(horizontal, 59, 14), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(horizontal, 45, 4)[3], 0)
        XCTAssertEqual(try composedPixel(horizontal, 45, 15)[3], 0)

        let tall = try composerFixture(directory, "tall-top.png", width: 20, height: 20, color: red)
        let tallBottom = try composerFixture(directory, "tall-bottom.png", width: 20, height: 30, color: blue)
        let column = directory.appendingPathComponent("column.png")
        try ScreenshotComposer.stitch(paths: [tall, tallBottom], vertical: true).write(to: column)
        let pieces = try ScreenshotComposer.split(path: column.path, parts: 3)
        XCTAssertEqual(try pieces.map { try XCTUnwrap(NSBitmapImageRep(data: $0)).pixelsHigh }, [16, 16, 18])
        XCTAssertEqual(try composedPixel(pieces[1], 0, 3), [255, 0, 0, 255])
        XCTAssertEqual(try composedPixel(pieces[1], 0, 4), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(pieces[2], 19, 17), [0, 0, 255, 255])
        let line = try composerFixture(directory, "line.png", width: 4, height: 1, color: red)
        XCTAssertThrowsError(try ScreenshotComposer.split(path: line, parts: 2))
        XCTAssertThrowsError(try ScreenshotComposer.split(path: column.path, parts: 11))
        XCTAssertThrowsError(try ScreenshotComposer.stitch(paths: [wide, directory.appendingPathComponent("missing.png").path], vertical: true))

        let same = try ScreenshotComposer.compare(first: wide, second: wide)
        XCTAssertEqual([same.different, same.total], [0, 800])
        let taller = try composerFixture(directory, "taller.png", width: 40, height: 30, color: red)
        let grown = try ScreenshotComposer.compare(first: wide, second: taller)
        XCTAssertEqual([grown.different, grown.total], [400, 1200])
        XCTAssertEqual(try composedPixel(grown.mask, 0, 0)[3], 0)
        XCTAssertEqual(try composedPixel(grown.mask, 0, 25)[3], 153)
        let recolored = try composerFixture(directory, "blue.png", width: 40, height: 20, color: blue)
        XCTAssertEqual(try ScreenshotComposer.compare(first: wide, second: recolored).different, 800)
    }

    @MainActor
    func testRequestAccessReusesExistingGrant() async throws {
        guard ScreenCaptureService.isAuthorized() else {
            throw XCTSkip("测试进程没有屏幕录制授权，无法断言复用路径。")
        }
        let granted = await ScreenCaptureService.requestAccess()
        XCTAssertTrue(granted)
    }

    @MainActor
    func testScreenshotSnapshotReportsScreenAccessWithoutCaptureBytes() throws {
        let controller = ScreenshotWindowController()
        defer { controller.shutdown() }
        let snapshotExpectation = expectation(description: AppConstants.getScreenshotMethod)
        var snapshot: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) { value in
            snapshot = value as? [String: Any]
            snapshotExpectation.fulfill()
        }
        wait(for: [snapshotExpectation], timeout: 1)
        let body = try XCTUnwrap(snapshot)
        XCTAssertNotNil(body["screenAccess"] as? Bool)
        XCTAssertNil(body["pixels"])
        XCTAssertNil(body["id"])
    }

    @MainActor
    func testPinOverlayStaysIndependentOfSelectionSession() throws {
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let overlay = OverlayPanelController()
        let pins = PinOverlayController()
        defer {
            pins.closeAll()
            overlay.hide(sessionId: "pin-lifecycle")
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = rep.representation(using: .png, properties: [:])!
        let pinId = try XCTUnwrap(pins.pin(png: png, origin: NSPoint(x: 120, y: 180)))
        let panel = try XCTUnwrap(pins.firstPanel)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(pins.isVisible(pinId: pinId))

        XCTAssertNil(pins.pin(png: Data([0, 1, 2, 3]), origin: NSPoint(x: 120, y: 180)))

        overlay.show(at: NSPoint(x: 250, y: 450), size: NSSize(width: 84, height: 36), sessionId: "pin-lifecycle")
        overlay.hide(sessionId: "pin-lifecycle")
        XCTAssertTrue(pins.isVisible(pinId: pinId))
        XCTAssertEqual(pins.count, 1)

        let second = try XCTUnwrap(pins.pin(png: png, origin: NSPoint(x: 200, y: 220)))
        XCTAssertEqual(pins.count, 2)
        panel.close()
        XCTAssertFalse(pins.isVisible(pinId: pinId))
        XCTAssertTrue(pins.isVisible(pinId: second))
        XCTAssertEqual(pins.count, 1)

        let created = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0 is PinPanel }
        XCTAssertFalse(created.isEmpty)

        let remaining = try XCTUnwrap(pins.firstPanel)
        let image = remaining.imageViewForTesting
        let beforeDrag = image.dragBeginCountForTesting
        let dragEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: image.bounds.midX, y: image.bounds.midY),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: remaining.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        image.mouseDown(with: dragEvent)
        XCTAssertEqual(image.dragBeginCountForTesting, beforeDrag + 1)

        let beforeCloseDrag = image.dragBeginCountForTesting
        XCTAssertTrue(remaining.closeButtonForTesting.isHidden)
        XCTAssertNotNil(image.menu)
        remaining.cancelOperation(nil)
        XCTAssertEqual(image.dragBeginCountForTesting, beforeCloseDrag)
        XCTAssertEqual(pins.count, 0)
        XCTAssertFalse(pins.isVisible(pinId: second))
    }

    @MainActor
    func testScreenshotPinExportUsesPayloadBytesAndRejectsStaleId() throws {
        let controller = ScreenshotWindowController()
        defer { controller.shutdown() }

        func png(width: Int, height: Int, color: NSColor) throws -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            for x in 0..<width {
                for y in 0..<height {
                    rep.setColor(color, atX: x, y: y)
                }
            }
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }

        let original = try captureImageFixture(width: 8, height: 8, color: .red)
        controller.seedCaptureForTesting(image: original, id: "capture-1", width: 8, height: 8)
        let editedPng = try png(width: 64, height: 16, color: .blue)

        var pinResult: Any?
        let pinExpectation = expectation(description: AppConstants.pinScreenshotMethod)
        controller.handle(
            FlutterMethodCall(
                methodName: AppConstants.pinScreenshotMethod,
                arguments: [
                    "id": "capture-1",
                    "bytes": FlutterStandardTypedData(bytes: editedPng),
                    "x": 40.0,
                    "y": 80.0,
                ]
            )
        ) { value in
            pinResult = value
            pinExpectation.fulfill()
        }
        wait(for: [pinExpectation], timeout: 1)
        let pinId = try XCTUnwrap(pinResult as? String)
        XCTAssertEqual(controller.pins.count, 1)
        let panel = try XCTUnwrap(controller.pins.firstPanel)
        let pixels = panel.pinnedImagePixelSizeForTesting
        XCTAssertEqual(Int(pixels.width), 64)
        XCTAssertEqual(Int(pixels.height), 16)

        var staleResult: Any?
        let staleExpectation = expectation(description: "stale pin")
        controller.handle(
            FlutterMethodCall(
                methodName: AppConstants.pinScreenshotMethod,
                arguments: [
                    "id": "not-current",
                    "bytes": FlutterStandardTypedData(bytes: editedPng),
                ]
            )
        ) { value in
            staleResult = value
            staleExpectation.fulfill()
        }
        wait(for: [staleExpectation], timeout: 1)
        let staleError = try XCTUnwrap(staleResult as? FlutterError)
        XCTAssertEqual(staleError.code, AppConstants.staleCaptureError)
        XCTAssertEqual(controller.pins.count, 1)

        panel.closeFromUserAction()
        XCTAssertEqual(controller.pins.count, 0)
        XCTAssertFalse(controller.pins.isVisible(pinId: pinId))
    }

    @MainActor
    func testSelectedPinClosesOnEscape() throws {
        let pins = PinOverlayController()
        defer { pins.closeAll() }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let firstId = try XCTUnwrap(pins.pin(png: png, origin: NSPoint(x: 80, y: 80)))
        let firstPanel = try XCTUnwrap(pins.firstPanel)
        let secondId = try XCTUnwrap(pins.pin(png: png, origin: NSPoint(x: 160, y: 160)))
        XCTAssertEqual(pins.count, 2)
        XCTAssertTrue(firstPanel.canBecomeKey)
        XCTAssertTrue(firstPanel.imageViewForTesting.acceptsFirstMouse(for: nil))

        let esc = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: firstPanel.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        firstPanel.keyDown(with: esc)
        XCTAssertFalse(pins.isVisible(pinId: firstId))
        XCTAssertTrue(pins.isVisible(pinId: secondId))
        XCTAssertEqual(pins.count, 1)
    }

    func testFrontmostWindowPixelCropMapsAppKitRectIntoImagePixels() {
        let display = NSRect(x: 0, y: 0, width: 100, height: 80)
        let window = NSRect(x: 10, y: 10, width: 40, height: 40)
        let crop = CaptureGeometry.pixelCrop(
            window: window,
            displayFrame: display,
            pixelWidth: 200,
            pixelHeight: 160
        )
        XCTAssertEqual(crop?.origin.x ?? -1, 20, accuracy: 0.01)
        XCTAssertEqual(crop?.origin.y ?? -1, 60, accuracy: 0.01)
        XCTAssertEqual(crop?.width ?? -1, 80, accuracy: 0.01)
        XCTAssertEqual(crop?.height ?? -1, 80, accuracy: 0.01)
        XCTAssertNil(
            CaptureGeometry.pixelCrop(
                window: NSRect(x: 400, y: 400, width: 10, height: 10),
                displayFrame: display,
                pixelWidth: 200,
                pixelHeight: 100
            )
        )
    }

}

final class WindowStartupTests: XCTestCase {
    @MainActor
    private func start(_ entrypoint: String) async -> WindowEngine.Started? {
        var pending: WindowEngine.Startup?
        let resources = await withCheckedContinuation { continuation in
            pending = WindowEngine.start(name: "startup-test-\(UUID().uuidString)", entrypoint: entrypoint,
                channel: AppConstants.settingsChannel, handler: { _, reply in reply(nil) }) { started in
                    continuation.resume(returning: started)
                }
        }
        withExtendedLifetime(pending) {}
        return resources
    }

    @MainActor
    func testAllWindowEntrypointsAcknowledgeWithoutAWindow() async throws {
        for entrypoint in [AppConstants.settingsEntrypoint, AppConstants.permissionWizardEntrypoint,
                           AppConstants.historyEntrypoint, AppConstants.screenshotEntrypoint,
                           AppConstants.captureEntrypoint] {
            let begin = ContinuousClock.now
            let outcome = await start(entrypoint)
            let elapsed = (ContinuousClock.now - begin).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            print("WINDOW_STARTUP_MEASURE entrypoint=\(entrypoint) milliseconds=\(milliseconds) ready=\(outcome != nil)")
            let started = try XCTUnwrap(outcome)
            XCTAssertNil(started.flutter.view.window)
            started.channel.setMethodCallHandler(nil)
            started.engine.shutDownEngine()
        }
    }

    @MainActor
    func testMissingEntrypointFailsAndNextStartupSucceeds() async throws {
        let clock = ContinuousClock.now
        let failed = await start("missingWindowStartupTestEntrypoint")
        XCTAssertNil(failed)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - clock, .seconds(AppConstants.windowStartupTimeout))
        let outcome = await start(AppConstants.settingsEntrypoint)
        let retry = try XCTUnwrap(outcome)
        retry.channel.setMethodCallHandler(nil)
        retry.engine.shutDownEngine()
    }

    @MainActor
    func testCancellationBeforeRunAndDuringStartupDoesNotDeliver() async throws {
        let cancelled = expectation(description: "取消后不得交付资源或失败")
        cancelled.isInverted = true
        let beforeRun = WindowEngine.start(name: "cancel-before-run", entrypoint: AppConstants.settingsEntrypoint,
            channel: AppConstants.settingsChannel, handler: { _, reply in reply(nil) }) { _ in cancelled.fulfill() }
        beforeRun.cancel()
        let duringRun = WindowEngine.start(name: "cancel-during-run", entrypoint: "missingWindowStartupTestEntrypoint",
            channel: AppConstants.settingsChannel, handler: { _, reply in reply(nil) }) { _ in cancelled.fulfill() }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { duringRun.cancel(); continuation.resume() }
        }
        await fulfillment(of: [cancelled], timeout: AppConstants.windowStartupTimeout + 0.2)
        withExtendedLifetime((beforeRun, duringRun)) {}
    }

    @MainActor
    private func visibleWindow(title: String) async throws -> NSWindow {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSApp.windows.contains { $0.title == title && $0.isVisible }
        }, object: nil)
        await fulfillment(of: [visible], timeout: 6)
        return try XCTUnwrap(NSApp.windows.first { $0.title == title && $0.isVisible })
    }

    @MainActor
    func testSettingsMergesPendingOpenAndReusesClosedWindow() async throws {
        let settings = SettingsWindowController()
        settings.show()
        settings.shutdown()
        await Task.yield()
        XCTAssertFalse(NSApp.windows.contains { $0.title == "权限与启动" && $0.isVisible })
        settings.show()
        settings.show()
        let window = try await visibleWindow(title: "权限与启动")
        let flutter = try XCTUnwrap(window.contentViewController?.children.first as? FlutterViewController)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "权限与启动" && $0.isVisible }.count, 1)
        window.close()
        XCTAssertFalse(window.isVisible)
        settings.show()
        let reopened = try await visibleWindow(title: "权限与启动")
        XCTAssertTrue(reopened === window)
        XCTAssertTrue((reopened.contentViewController?.children.first as? FlutterViewController)?.engine === flutter.engine)
        reopened.close()
        withExtendedLifetime(settings) {}
    }

    @MainActor
    func testAuxiliaryCloseCancelsPendingAndReopensWithNewEngine() async throws {
        let title = "startup-lifecycle-test"
        let controller = AuxiliaryWindowController(engineName: "startup-lifecycle", entrypoint: AppConstants.historyEntrypoint,
            title: title, size: NSSize(width: 560, height: 720), refreshMethod: AppConstants.historyChangedMethod)
        defer { controller.close() }
        controller.show()
        controller.show()
        controller.close()
        await Task.yield()
        XCTAssertFalse(NSApp.windows.contains { $0.title == title && $0.isVisible })
        controller.show()
        controller.show()
        let window = try await visibleWindow(title: title)
        let flutter = try XCTUnwrap(window.contentViewController?.children.first as? FlutterViewController)
        XCTAssertEqual(NSApp.windows.filter { $0.title == title && $0.isVisible }.count, 1)
        controller.refresh()
        controller.close()
        XCTAssertFalse(window.isVisible)
        controller.show()
        let reopened = try await visibleWindow(title: title)
        let next = try XCTUnwrap(reopened.contentViewController?.children.first as? FlutterViewController)
        XCTAssertFalse(next.engine === flutter.engine)
    }
}
