import AdjustmentUI
import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI

/// Owns the image canvas, comparison modes, crop/mask overlays, zoom gesture,
/// and the optional filmstrip. Editing state remains in the shared session.
struct PadEditorCanvasView: View {
    @ObservedObject var editor: EditorSession
    @ObservedObject var library: PadLibraryModel
    let services: PadAppServices
    @Binding var canvasScale: CGFloat
    let size: CGSize
    let filmstripPhotos: [PhotoAsset]
    let showsFilmstrip: Bool
    let onSelectFilmstripPhoto: (PhotoAsset) -> Void

    @GestureState private var canvasMagnification: CGFloat = 1
    @State private var wipeDragStartPosition: CGFloat?

    private static let minimumCanvasScale: CGFloat = 1
    private static let maximumCanvasScale: CGFloat = 5

    var body: some View {
        ZStack {
            Color.black
            if editor.previewImage != nil || editor.originalImage != nil {
                comparisonCanvas
                    .scaleEffect(canvasScale * canvasMagnification)
                    .gesture(
                        MagnificationGesture()
                            .updating($canvasMagnification) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                let proposed = canvasScale * value
                                canvasScale = min(max(proposed, Self.minimumCanvasScale), Self.maximumCanvasScale)
                            }
                    )
            } else if editor.decodeFailed {
                ContentUnavailableView(
                    L10n.t("Couldn't show this photo"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView(L10n.t("Decoding RAW…"))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsFilmstrip {
                PadEditorFilmstrip(
                    photos: filmstripPhotos,
                    currentPhotoID: editor.photo?.id,
                    library: library,
                    services: services,
                    onSelect: onSelectFilmstripPhoto
                )
            }
        }
    }

    @ViewBuilder
    private var comparisonCanvas: some View {
        GeometryReader { proxy in
            switch editor.compareMode {
            case .single:
                if let image = editor.displayedImage {
                    canvasImageWithOverlays(image, in: proxy.size)
                }
            case .sideBySide:
                HStack(spacing: 1) {
                    if let original = editor.originalImage {
                        canvasImage(original)
                            .frame(maxWidth: .infinity)
                    }
                    if let edited = editor.previewImage {
                        canvasImage(edited)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            case .verticalWipe:
                verticalWipeCanvas
            }
        }
    }

    /// The wipe viewport keeps the divider, clip, and 44pt gesture strip in
    /// the same coordinate system in portrait, landscape, and Split View.
    private var verticalWipeCanvas: some View {
        GeometryReader { wipeProxy in
            ZStack(alignment: .leading) {
                if let edited = editor.previewImage {
                    canvasImage(edited)
                }
                if let original = editor.originalImage {
                    canvasImage(original)
                        .frame(width: wipeProxy.size.width * editor.wipePosition)
                        .clipped()
                }
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2)
                    .offset(x: wipeProxy.size.width * editor.wipePosition - 1)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .offset(x: wipeProxy.size.width * editor.wipePosition - 22)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard wipeProxy.size.width > 0 else { return }
                                let start = wipeDragStartPosition ?? editor.wipePosition
                                if wipeDragStartPosition == nil {
                                    wipeDragStartPosition = start
                                }
                                editor.setWipePosition(
                                    start + value.translation.width / wipeProxy.size.width
                                )
                            }
                            .onEnded { _ in
                                wipeDragStartPosition = nil
                            }
                    )
            }
            .frame(width: wipeProxy.size.width, height: wipeProxy.size.height)
        }
        .padding()
    }

    private func canvasImageWithOverlays(_ image: CGImage, in canvasSize: CGSize) -> some View {
        let imageFrame = fittedImageFrame(
            imageSize: CGSize(width: image.width, height: image.height),
            in: canvasSize,
            padding: 0
        )

        return ZStack {
            canvasImage(image)

            if editor.toolMode == .crop {
                PadCropOverlayView(editor: editor, imageFrame: imageFrame)
            }
            if editor.toolMode == .radialGradient {
                RadialMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }
            if editor.toolMode == .brush {
                BrushMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }
            if editor.toolMode == .linearGradient {
                LinearGradientMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }
            if editor.toolMode == .spotHeal {
                SpotHealMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }
            if editor.toolMode == .whiteBalance {
                WhiteBalanceEyedropperOverlay(editor: editor, imageFrame: imageFrame, image: image)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func fittedImageFrame(imageSize: CGSize, in container: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(
            width: max(container.width - padding * 2, 0),
            height: max(container.height - padding * 2, 0)
        )
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: CGPoint(x: padding, y: padding), size: available)
        }

        let aspect = imageSize.width / imageSize.height
        let availableAspect = available.width / available.height
        let fittedSize: CGSize
        if aspect > availableAspect {
            fittedSize = CGSize(width: available.width, height: available.width / aspect)
        } else {
            fittedSize = CGSize(width: available.height * aspect, height: available.height)
        }
        return CGRect(
            x: padding + (available.width - fittedSize.width) / 2,
            y: padding + (available.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func canvasImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
    }
}
