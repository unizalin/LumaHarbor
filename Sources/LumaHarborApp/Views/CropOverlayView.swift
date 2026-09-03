import EditorCore
import RawProcessingCore
import SwiftUI

/// The crop-rect drag overlay drawn on top of the photo while `EditorSession
/// .toolMode == .crop` (design spec §6.5). Draws a dimmed scrim outside the
/// current crop, a border around it, and four corner handles; dragging a
/// handle resizes from the opposite corner (fixed-corner math in
/// `CropDragMath`, unit-tested independently of this view ever rendering),
/// dragging the interior moves the whole rect. Every edit goes through
/// `EditorSession.updateAdjustments(_:)`, so undo/autosave/preview-refresh
/// come for free with no separate wiring (same pattern every other
/// adjustment control in this app already uses).
struct CropOverlayView: View {
    @ObservedObject var editor: EditorSession
    /// The fitted image rect from `AspectFitRect.fitting(...)` -- the exact
    /// rectangle the photo itself occupies, so the overlay lines up with it
    /// pixel for pixel regardless of window size or aspect ratio.
    let imageFrame: CGRect

    /// The crop at the moment the current drag gesture began. `nil` between
    /// drags. Captured once per gesture so cumulative `translation` (always
    /// relative to the gesture's own start point) is applied against a
    /// stable base rather than compounding against whatever
    /// `updateAdjustments` last wrote.
    @State private var dragBaseCrop: NormalizedCropRect?

    private static let handleSize: CGFloat = 12
    private static let handleHitAreaSize: CGFloat = 28

    private var currentCrop: NormalizedCropRect { editor.adjustments.geometry.crop ?? .full }

    private var cropRectInFrame: CGRect {
        CGRect(
            x: imageFrame.minX + currentCrop.x * imageFrame.width,
            y: imageFrame.minY + currentCrop.y * imageFrame.height,
            width: currentCrop.width * imageFrame.width,
            height: currentCrop.height * imageFrame.height
        )
    }

    var body: some View {
        ZStack {
            scrim
            interior
            border
            ForEach([CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { handle in
                handleView(handle)
            }
        }
    }

    /// Dims everything outside the crop using an even-odd fill (outer rect +
    /// inner rect punched out), rather than four separately-computed dimming
    /// bands.
    private var scrim: some View {
        Path { path in
            path.addRect(imageFrame)
            path.addRect(cropRectInFrame)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .frame(width: cropRectInFrame.width, height: cropRectInFrame.height)
            .position(x: cropRectInFrame.midX, y: cropRectInFrame.midY)
            .allowsHitTesting(false)
    }

    /// A transparent hit area covering the crop's interior, below the
    /// border/handles in z-order so it never steals a handle drag.
    private var interior: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: cropRectInFrame.width, height: cropRectInFrame.height)
            .position(x: cropRectInFrame.midX, y: cropRectInFrame.midY)
            .gesture(dragGesture(for: .move))
    }

    private func handleView(_ handle: CropHandle) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .shadow(radius: 1)
            .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
            .contentShape(Circle())
            .position(handlePosition(handle))
            .gesture(dragGesture(for: handle))
    }

    private func handlePosition(_ handle: CropHandle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: cropRectInFrame.minX, y: cropRectInFrame.minY)
        case .topRight: return CGPoint(x: cropRectInFrame.maxX, y: cropRectInFrame.minY)
        case .bottomLeft: return CGPoint(x: cropRectInFrame.minX, y: cropRectInFrame.maxY)
        case .bottomRight: return CGPoint(x: cropRectInFrame.maxX, y: cropRectInFrame.maxY)
        case .move: return CGPoint(x: cropRectInFrame.midX, y: cropRectInFrame.midY)
        }
    }

    private func dragGesture(for handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = dragBaseCrop ?? currentCrop
                if dragBaseCrop == nil { dragBaseCrop = base }
                let updated = CropDragMath.updatedCrop(
                    base: base,
                    handle: handle,
                    translation: value.translation,
                    imageFrameSize: imageFrame.size
                )
                // Writing back to `nil` when the drag lands back on the full
                // frame keeps `GeometryAdjustments.isIdentity`/`hasEdits`
                // exact, matching the sidecar's own neutral encoding
                // (Task 2.1) rather than leaving a redundant, visually
                // identical `.full` crop recorded as an edit.
                editor.updateAdjustments { $0.geometry.crop = updated.isFull ? nil : updated }
            }
            .onEnded { _ in dragBaseCrop = nil }
    }
}
