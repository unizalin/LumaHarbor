import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The white balance eyedropper's on-canvas hit area, drawn on top of the
/// photo while `EditorSession.toolMode == .whiteBalance` (design spec
/// §6.4). A press-and-hold previews the sampled point live
/// (`EditorSession.previewEyedropper(sample:)`, which never touches
/// `history`/`saveState`); releasing commits it
/// (`EditorSession.commitEyedropper()`) and returns to `.adjust`. The ring
/// marker is purely visual feedback for where the last sample was taken --
/// it carries no state of its own that affects the actual white balance.
struct EyedropperOverlayView: View {
    @ObservedObject var editor: EditorSession
    /// The fitted image rect from `AspectFitRect.fitting(...)` -- the same
    /// rectangle `CropOverlayView` (Task 2.3) draws and hit-tests against,
    /// so a click here lines up with the photo pixel for pixel regardless
    /// of window size or aspect ratio.
    let imageFrame: CGRect
    /// The currently displayed `CGImage` -- what the sample actually reads,
    /// via `PixelSampler`. Passed in rather than read from `editor
    /// .displayedImage` at gesture time, so what's sampled during a drag is
    /// always the frame the overlay itself was laid out against.
    let image: CGImage

    @State private var lastSampleLocation: CGPoint?
    /// A drag samples one immutable frame.  The editor may publish a newer
    /// preview while the pointer is moving; switching source images halfway
    /// through would otherwise make the marker, RGB sample, and release commit
    /// refer to three different frames.
    @State private var samplingSnapshot: SamplingSnapshot?
    @State private var samplingAttempted = false

    private struct SamplingSnapshot {
        let image: CGImage
        let imageFrame: CGRect
        let context: EditorSession.EyedropperSamplingContext
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .gesture(sampleGesture)

            if let lastSampleLocation {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                    .shadow(radius: 1)
                    .position(lastSampleLocation)
                    .allowsHitTesting(false)
            }

            if let issue = editor.eyedropperIssue {
                Text(issueMessage(for: issue))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .help(L10n.t("Click a point that should be neutral gray"))
    }

    private var sampleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                sample(at: value.location, commit: false)
            }
            .onEnded { value in
                sample(at: value.location, commit: true)
                samplingSnapshot = nil
                samplingAttempted = false
            }
    }

    private func sample(at location: CGPoint, commit: Bool) {
        if !samplingAttempted {
            samplingAttempted = true
            guard imageFrame.width > 0, imageFrame.height > 0,
                  let context = editor.beginEyedropperSampling(sourceImage: image) else {
                editor.rejectEyedropperSample(editor.whiteBalanceCapability == .valid ? .staleFrame : .unavailableBaseline)
                return
            }
            samplingSnapshot = SamplingSnapshot(image: image, imageFrame: imageFrame, context: context)
        }
        guard let snapshot = samplingSnapshot else { return }
        guard snapshot.imageFrame.contains(location) else {
            editor.rejectEyedropperSample(.outOfRange, context: snapshot.context)
            if commit {
                samplingSnapshot = nil
            }
            return
        }
        let pixel = AspectFitRect.imagePixel(
            at: location,
            imageFrame: snapshot.imageFrame,
            imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)
        )
        guard let rgb = PixelSampler.sample(at: pixel, in: snapshot.image) else {
            editor.rejectEyedropperSample(.outOfRange, context: snapshot.context)
            if commit {
                samplingSnapshot = nil
            }
            return
        }
        lastSampleLocation = location
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: rgb.red, green: rgb.green, blue: rgb.blue), context: snapshot.context)
        if commit {
            if editor.commitEyedropper(context: snapshot.context) {
                editor.setToolMode(.adjust)
            }
            samplingSnapshot = nil
        }
    }

    private func issueMessage(for issue: WhiteBalanceEyedropper.SampleIssue) -> String {
        switch issue {
        case .nonFinite:
            return L10n.t("The sampled color is unavailable.")
        case .outOfRange:
            return L10n.t("Choose a visible pixel inside the photo.")
        case .tooDark:
            return L10n.t("Choose a brighter neutral area.")
        case .clipped:
            return L10n.t("Choose a neutral area without clipped highlights.")
        case .unavailableBaseline:
            return L10n.t("White balance is unavailable for this photo.")
        case .staleFrame:
            return L10n.t("Wait for the current preview before sampling.")
        }
    }
}
