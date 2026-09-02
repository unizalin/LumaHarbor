import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The advanced tone curve (design spec §6.3 "Curve" group). Unlike every
/// other grouped panel, `AdvancedToneCurve.points` has no fixed slider set --
/// it is an arbitrary-length list of control points, whose only current
/// source is a style/XMP import (see that type's own doc comment) -- so a
/// draggable curve graph is out of scope for this task (plan: "precision
/// input... if not finished, record as NOT RUN / follow-up, not PASS"). This
/// first version shows the curve's current state and a visible Reset button,
/// satisfying the plan's "each adjustment has visible neutral/reset
/// semantics" acceptance without inventing a shape for an interactive editor
/// this task was never scoped to build.
public struct CurveAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("Reset")) {
                editor.updateAdjustments { $0.advancedToneCurve = .neutral }
            }
            .controlSize(.small)
            .disabled(editor.adjustments.advancedToneCurve.isIdentity)
        }
    }

    private var statusText: String {
        let curve = editor.adjustments.advancedToneCurve
        if curve.isIdentity {
            return L10n.t("No curve applied")
        }
        return String(format: L10n.t("%d control points"), curve.points.count)
    }
}
