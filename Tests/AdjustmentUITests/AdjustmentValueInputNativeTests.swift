#if os(macOS)
import AppKit
import EditorCore
import Localization
import PhotoLibraryCore
import PresetCore
import RawProcessingCore
import SwiftUI
import XCTest
@testable import AdjustmentUI

private final class NativeBaselineSource: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double?
    private var paused: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ baseline: Double?, paused: Bool = false) { stored = baseline; self.paused = paused }
    var baseline: Double? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func waitUntilResumed() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if paused { waiters.append(continuation); return false }
                return true
            }
            if shouldResume { continuation.resume() }
        }
    }
    func resume() {
        let pending = lock.withLock {
            paused = false
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}

private struct NativeBaselineRenderer: PreviewRendering {
    let source: NativeBaselineSource
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        await source.waitUntilResumed()
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return PreviewImage(cgImage: context.makeImage()!, pixelSize: CGSize(width: 1, height: 1),
            whiteBalanceBaseline: source.baseline.map { .init(temperatureKelvin: $0, tint: 0) })
    }
}

/// Exercises the actual product view's native field editor without launching
/// another app or placing a test window on the user's desktop.
@MainActor
final class AdjustmentValueInputNativeTests: XCTestCase {
    @MainActor private final class Model: ObservableObject {
        @Published var value: Double
        @Published var identity = "photo-A"
        var writes: [Double] = []
        init(_ value: Double) { self.value = value }
    }

    @MainActor private struct Content: View {
        @ObservedObject var model: Model
        @State private var other = "0"
        var body: some View {
            VStack {
                AdjustmentValueInput(label: "Temperature", value: Binding(
                    get: { model.value },
                    set: { model.writes.append($0); model.value = $0 }
                ), range: 2000...50000, fractionDigits: 0, step: 50,
                    onReset: { model.value = 6500 }, identity: AnyHashable(model.identity), unit: "K")
                TextField("Tint", text: $other)
            }.frame(width: 300, height: 160)
        }
    }

    @MainActor private final class Host {
        let model: Model
        let window: NSWindow
        let view: NSHostingView<AnyView>
        init(_ value: Double, content: ((Model) -> AnyView)? = nil) {
            _ = NSApplication.shared
            model = Model(value)
            view = NSHostingView(rootView: content?(model) ?? AnyView(Content(model: model)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
        }
        var fields: [NSTextField] {
            func collect(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(collect)
            }
            return collect(view)
        }
        func flush() {
            view.layoutSubtreeIfNeeded()
            for _ in 0..<8 {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
                view.layoutSubtreeIfNeeded()
            }
        }
        func focus() throws -> NSTextView {
            flush()
            let field = try XCTUnwrap(fields.first)
            let focused = window.makeFirstResponder(field)
            XCTAssertTrue(focused)
            flush()
            return try XCTUnwrap(field.currentEditor() as? NSTextView)
        }
        func type(_ text: String, in editor: NSTextView) {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            flush()
        }
        func blur() throws {
            let other = try XCTUnwrap(fields.last)
            let focused = window.makeFirstResponder(other)
            XCTAssertTrue(focused)
            flush()
        }
        func close() { window.orderOut(nil); window.close() }
    }

    func testInvalidEnterThenBlurRestoresNativeTextWithoutWriting() throws {
        let host = Host(6500)
        defer { host.close() }
        let editor = try host.focus()
        host.type("60000", in: editor)
        editor.insertNewline(nil)
        host.flush()
        XCTAssertEqual(host.fields.first?.stringValue, "6500")
        XCTAssertEqual(editor.string, "6500", "the native buffer, not merely SwiftUI state")
        try host.blur()
        XCTAssertEqual(host.fields.first?.stringValue, "6500")
        XCTAssertEqual(host.model.value, 6500)
        XCTAssertEqual(host.model.writes, [])
    }

    func testUntouchedPreciseValueEnterThenBlurDoesNotCallSetter() throws {
        let precise = 4536.72802734375
        let host = Host(precise)
        defer { host.close() }
        let editor = try host.focus()
        XCTAssertEqual(editor.string, String(precise))
        editor.insertNewline(nil)
        host.flush()
        try host.blur()
        XCTAssertEqual(host.model.value, precise)
        XCTAssertEqual(host.model.writes, [])
    }

    func testExplicitRoundedDisplayValueIsARealEdit() throws {
        let host = Host(4536.72802734375)
        defer { host.close() }
        let editor = try host.focus()
        host.type("4537", in: editor)
        editor.insertNewline(nil)
        host.flush()
        try host.blur()
        XCTAssertEqual(host.model.value, 4537)
        XCTAssertEqual(host.model.writes, [4537])
    }

    func testEscapeThenBlurNeverCommitsTheDraft() throws {
        let host = Host(6500)
        defer { host.close() }
        let editor = try host.focus()
        host.type("7000", in: editor)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        host.flush()
        try host.blur()
        XCTAssertEqual(host.fields.first?.stringValue, "6500")
        XCTAssertEqual(host.model.value, 6500)
        XCTAssertEqual(host.model.writes, [])
    }

    func testValidEnterThenBlurWritesExactlyOnce() throws {
        let host = Host(6500)
        defer { host.close() }
        let editor = try host.focus()
        host.type("7000.125", in: editor)
        editor.insertNewline(nil)
        host.flush()
        try host.blur()
        XCTAssertEqual(host.model.value, 7000.125)
        XCTAssertEqual(host.model.writes, [7000.125])
    }

    func testProductPanelSameValueResetInvalidatesNativeDraft() throws {
        let session = EditorSession()
        let photo = PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready)
        session.open(photo: photo, sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral, isReadOnly: false)
        let host = Host(0) { _ in AnyView(VStack {
            BasicAdjustmentPanel(editor: session, kinds: [.exposure])
            TextField("Other", text: .constant("0"))
        }.frame(width: 550, height: 160)) }
        defer { host.close(); session.close() }
        let fieldEditor = try host.focus()
        host.type("1.5", in: fieldEditor)
        session.resetAdjustment(.exposure) // Still zero; value observation alone cannot invalidate the draft.
        // Deliberately submit before a SwiftUI update; the live revision reader
        // must see reset even when the binding's numeric value did not change.
        fieldEditor.insertNewline(nil)
        try host.blur()
        XCTAssertEqual(session.adjustments.exposure, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(host.fields.first?.stringValue, "0.00")
    }

    func testInvalidNativeDraftMatrixEnterAndBlurKeepsVisibleAccessibleRange() throws {
        for text in ["", "abc", "NaN", "Infinity", "-Infinity", "+", "-", "1999", "50001"] {
            for enter in [true, false] {
                let host = Host(6500)
                let editor = try host.focus()
                host.type(text, in: editor)
                if enter { editor.insertNewline(nil); host.flush() }
                try host.blur()
                XCTAssertEqual(host.model.value, 6500, text)
                XCTAssertEqual(host.model.writes, [], text)
                XCTAssertEqual(host.fields.first?.stringValue, "6500", text)
                let help = try XCTUnwrap(host.fields.first?.accessibilityHelp())
                XCTAssertTrue(help.contains("2000") && help.contains("50000") && help.contains("K"), help)
                func visibleError(_ view: NSView) -> Bool {
                    if let field = view as? NSTextField, !field.isEditable, !field.isHidden,
                       field.stringValue == help { return true }
                    return view.subviews.contains(where: visibleError)
                }
                XCTAssertTrue(visibleError(host.view), "error must be visible, not accessibility-only")
                host.close()
            }
        }
    }

    func testProductPanelExternalActionsInvalidateTheNativeDraft() throws {
        for action in ["undo", "redo", "slider", "preset", "photo"] {
            let session = EditorSession()
            func openPhoto() {
                session.open(photo: PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
                    fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready),
                    sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"), adjustments: .neutral, isReadOnly: false)
            }
            openPhoto()
            if action == "undo" || action == "redo" { session.setAdjustment(.exposure, to: 1) }
            if action == "redo" { session.undo() }
            let host = Host(0) { _ in AnyView(VStack {
                BasicAdjustmentPanel(editor: session, kinds: [.exposure])
                TextField("Other", text: .constant("0"))
            }.frame(width: 550, height: 160)) }
            let fieldEditor = try host.focus()
            host.type("4", in: fieldEditor)
            let expected: Double
            switch action {
            case "undo": session.undo(); expected = 0
            case "redo": session.redo(); expected = 1
            case "slider": session.setAdjustment(.exposure, to: 2); expected = 2
            case "preset":
                session.commitPreset(PresetDocument(name: "Neutral", patch: .init(basic: .init(exposure: 0))), mode: .merge)
                expected = 0
            default: openPhoto(); expected = 0
            }
            fieldEditor.insertNewline(nil) // No waiting for SwiftUI to reconcile.
            try host.blur()
            XCTAssertEqual(session.adjustments.exposure, expected, action)
            XCTAssertEqual(host.fields.first?.stringValue, String(format: "%.2f", expected), action)
            host.close()
            session.close()
        }
    }

    func testTemperaturePanelDisablesMissingInvalidBaselinesAndRecoversWithoutWriting() throws {
        for baseline: Double? in [nil, .nan, .infinity, -.infinity, 0, -1, 1999, 50001] {
            let source = NativeBaselineSource(baseline, paused: true)
            defer { source.resume() }
            let renderer = NativeBaselineRenderer(source: source)
            let session = EditorSession()
            session.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: renderer),
                previewRenderer: renderer, loadAdjustments: { _ in .neutral }, saveAdjustments: { _, _ in
                    XCTFail("capability recovery must not autosave")
                }))
            session.open(photo: PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
                fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready),
                sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"), adjustments: .neutral, isReadOnly: false)
            XCTAssertEqual(session.whiteBalanceCapability, .loading)
            let host = Host(0) { _ in AnyView(VStack {
                BasicAdjustmentPanel(editor: session, kinds: [.temperature])
                TextField("Other", text: .constant("0"))
            }.frame(width: 550, height: 160)) }
            host.flush()
            XCTAssertEqual(
                BasicAdjustmentPanelModel.unavailableWhiteBalanceMessage(for: session.whiteBalanceCapability),
                L10n.t("White balance baseline is still loading.")
            )
            XCTAssertEqual(host.fields.count, 1)
            source.resume()
            let deadline = Date().addingTimeInterval(2)
            while session.whiteBalanceCapability == .loading && Date() < deadline { host.flush() }
            host.flush()
            XCTAssertEqual(session.whiteBalanceCapability, baseline == nil ? .unavailable : .invalid)
            XCTAssertEqual(host.fields.count, 1, "no editable relative-temperature fallback or fabricated Kelvin")
            let reason = baseline == nil ? "White balance is unavailable for this photo."
                : "White balance baseline is invalid; Kelvin adjustment is unavailable."
            XCTAssertEqual(
                BasicAdjustmentPanelModel.unavailableWhiteBalanceMessage(for: session.whiteBalanceCapability),
                L10n.t(reason)
            )
            session.setAdjustment(.temperature, to: 10)
            XCTAssertEqual(session.adjustments.temperature, 0)
            source.baseline = 4536.72802734375
            // A second high-quality render obtains recovered decoder metadata.
            // The initial open already scheduled it; no recipe edit is needed.
            let recoveryDeadline = Date().addingTimeInterval(2)
            while session.whiteBalanceCapability != .valid && Date() < recoveryDeadline { host.flush() }
            host.flush()
            XCTAssertEqual(session.whiteBalanceCapability, .valid)
            XCTAssertEqual(host.fields.count, 2)
            XCTAssertEqual(host.fields.first?.stringValue, "4537")
            XCTAssertEqual(session.adjustments.temperature, 0)
            XCTAssertFalse(session.canUndo)
            XCTAssertEqual(session.saveState, .unchanged)
            host.close()
            session.close()
        }
    }

    func testNudgeConsumesTheActualNativeDraftAndWritesOnlyTheFinalValue() throws {
        let precise = 4536.72802734375
        for (initial, draft, expected, count) in [
            (6500.0, "7000", 7050.0, 1),
            (6500.0, "60000", 6550.0, 1),
            (precise, String(precise), precise + 50, 1),
            (50000.0, "50000", 50000.0, 0)
        ] {
            let host = Host(initial)
            let editor = try host.focus()
            host.type(draft, in: editor)
            let coordinator = try XCTUnwrap(host.fields.first?.delegate as? AdjustmentNativeTextField.Coordinator)
            // The same controller action the iPad buttons and macOS adjustable
            // accessibility action call; the draft came from real insertText.
            coordinator.controller.nudge(by: 50)
            try host.blur()
            XCTAssertEqual(host.model.value, expected, accuracy: 1e-9)
            XCTAssertEqual(host.model.writes.count, count)
            if count == 1 { XCTAssertEqual(host.model.writes, [expected]) }
            XCTAssertEqual(host.fields.first?.stringValue, String(format: "%.0f", expected))
            host.close()
        }
    }

    func testActualKelvinPanelRejects60000BeforeTintFocusWithoutChangingPixelsOrSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KelvinInput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileSidecarRepository(libraryRootURL: root)
        let photo = PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready)
        let sidecar = PhotoSidecar(photoID: photo.id, sourceRelativePath: photo.relativePath,
            sourceFingerprint: photo.fingerprint, adjustments: .neutral)
        try repository.write(sidecar: sidecar)
        let sidecarURL = repository.sidecarURL(for: photo.id)
        let originalSidecar = try Data(contentsOf: sidecarURL)
        let renderer = NativeBaselineRenderer(source: NativeBaselineSource(6500))
        let session = EditorSession()
        session.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { photo in try repository.loadSidecar(for: photo.id)?.adjustments ?? .neutral },
            saveAdjustments: { _, _ in XCTFail("invalid Kelvin input must never call persistence") }))
        session.open(photo: photo, sourceURL: root.appendingPathComponent(photo.relativePath),
            adjustments: .neutral, isReadOnly: false)
        let host = Host(0) { _ in AnyView(VStack {
            BasicAdjustmentPanel(editor: session, kinds: [.temperature, .tint])
        }.frame(width: 550, height: 220)) }
        defer { host.close(); session.close() }
        let deadline = Date().addingTimeInterval(2)
        while session.whiteBalanceCapability != .valid && Date() < deadline { host.flush() }
        let fieldEditor = try host.focus()
        let before = try XCTUnwrap(session.previewImage?.dataProvider?.data as Data?)
        host.type("60000", in: fieldEditor)
        fieldEditor.insertNewline(nil)
        try host.blur() // The second real product field is Tint.
        XCTAssertEqual(host.fields.first?.stringValue, "6500")
        XCTAssertTrue(host.fields.first?.accessibilityHelp()?.contains("50000") == true)
        XCTAssertEqual(session.adjustments, .neutral)
        XCTAssertEqual(session.displayedAdjustments, .neutral)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.saveState, .unchanged)
        XCTAssertEqual(session.previewImage?.dataProvider?.data as Data?, before)
        var saveChecked = false
        Task { await session.save(); saveChecked = true }
        let saveDeadline = Date().addingTimeInterval(2)
        while !saveChecked && Date() < saveDeadline { host.flush() }
        XCTAssertTrue(saveChecked)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), originalSidecar)
        XCTAssertEqual(try repository.loadSidecar(for: photo.id)?.adjustments, .neutral)
    }

    func testDoubleClickSelectsNativeNumericTextWithoutResettingTheParentRow() throws {
        let session = EditorSession()
        session.open(photo: PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"), adjustments: PhotoAdjustments(exposure: 1), isReadOnly: false)
        let host = Host(0) { _ in AnyView(VStack {
            BasicAdjustmentPanel(editor: session, kinds: [.exposure])
            TextField("Other", text: .constant("0"))
        }.frame(width: 550, height: 160)) }
        defer { host.close(); session.close() }
        let editor = try host.focus()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let field = try XCTUnwrap(host.fields.first)
        func doubleClick(_ field: NSTextField) throws {
            let location = field.convert(NSPoint(x: field.bounds.maxX - 8, y: field.bounds.midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 2, pressure: 0))
            NSApplication.shared.postEvent(up, atStart: false)
            host.window.sendEvent(down)
            host.flush()
        }
        // Calibrate synthetic mouse dispatch against a plain AppKit control,
        // independent of the product and its parent SwiftUI reset gesture.
        let reference = NSTextField(string: "12345")
        reference.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
        reference.alignment = .right
        host.view.addSubview(reference)
        XCTAssertTrue(host.window.makeFirstResponder(reference))
        let referenceEditor = try XCTUnwrap(reference.currentEditor() as? NSTextView)
        referenceEditor.setSelectedRange(NSRange(location: 0, length: 0))
        try doubleClick(reference)
        guard referenceEditor.selectedRange().length > 0 else {
            throw XCTSkip("Hidden-window mouse dispatch does not select even a plain AppKit text field; visible mouse/trackpad verification is required. Keyboard/delegate tests remain executable.")
        }
        reference.removeFromSuperview()
        XCTAssertTrue(host.window.makeFirstResponder(field))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try doubleClick(field)
        XCTAssertGreaterThan(editor.selectedRange().length, 0, "the native double click must actually select text")
        XCTAssertEqual(session.adjustments.exposure, 1)
        XCTAssertFalse(session.canUndo, "text selection must not become a reset operation")
    }
}
#endif
