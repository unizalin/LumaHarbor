import EditorCore
import Foundation
import Localization
import RawProcessingCore
import SwiftUI

/// iPad canvas controls for linear gradients. The Mac composition keeps its
/// richer overlay in `LumaHarborApp`; this shared target owns the equivalent
/// touch-first surface so the iPad Local page never creates a mask that cannot
/// be positioned or resized on canvas.
public struct LinearGradientMaskOverlayView: View {
    @ObservedObject private var editor: EditorSession
    private let imageFrame: CGRect

    @State private var dragBaseGeometry: [UUID: LocalAdjustmentGeometry] = [:]

    private static let visualHandleSize: CGFloat = 12
    private static let handleHitAreaSize: CGFloat = 44

    public init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var gradients: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .linearGradient }
    }

    public var body: some View {
        ZStack {
            ForEach(gradients) { gradient in
                handles(for: gradient)
            }
        }
    }

    private func handles(for gradient: LocalAdjustment) -> some View {
        let anchor = point(for: gradient.geometry)
        let direction = directionPoint(for: gradient.geometry)
        let selected = editor.selectedLocalAdjustmentID == gradient.id

        return ZStack {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: direction)
            }
            .stroke(Color.white.opacity(selected ? 0.9 : 0.45), lineWidth: 1.5)
            .allowsHitTesting(false)

            handle(at: anchor, filled: selected, label: "Gradient Position") {
                positionDrag(for: gradient)
            }
            if selected {
                handle(at: direction, filled: true, label: "Gradient Direction and Range") {
                    directionDrag(for: gradient)
                }
            }
        }
    }

    private func handle(
        at point: CGPoint,
        filled: Bool,
        label: String,
        drag: () -> some Gesture
    ) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.white)
            .frame(width: Self.visualHandleSize, height: Self.visualHandleSize)
            .shadow(radius: 1)
            .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
            .contentShape(Circle())
            .position(point)
            .gesture(drag())
            .accessibilityLabel(Text(L10n.t(label)))
    }

    private func point(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(geometry.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(geometry.y) * imageFrame.height
        )
    }

    private func directionPoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        let anchor = point(for: geometry)
        let diagonal = (imageFrame.width * imageFrame.width + imageFrame.height * imageFrame.height).squareRoot()
        let halfLength = max(CGFloat(geometry.range), 0.01) * diagonal / 2
        let radians = geometry.angleDegrees * .pi / 180
        return CGPoint(
            x: anchor.x + cos(radians) * halfLength,
            y: anchor.y + sin(radians) * halfLength
        )
    }

    private func positionDrag(for gradient: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = gradient.id
                let base = dragBaseGeometry[gradient.id] ?? gradient.geometry
                if dragBaseGeometry[gradient.id] == nil { dragBaseGeometry[gradient.id] = base }
                var updated = base
                guard imageFrame.width > 0, imageFrame.height > 0 else { return }
                updated.x = base.x + Double(value.translation.width / imageFrame.width)
                updated.y = base.y + Double(value.translation.height / imageFrame.height)
                setGeometry(updated, for: gradient.id)
            }
            .onEnded { _ in dragBaseGeometry[gradient.id] = nil }
    }

    private func directionDrag(for gradient: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = gradient.id
                let base = dragBaseGeometry[gradient.id] ?? gradient.geometry
                if dragBaseGeometry[gradient.id] == nil { dragBaseGeometry[gradient.id] = base }
                let anchor = point(for: base)
                let baseDirection = directionPoint(for: base)
                let tip = CGPoint(
                    x: baseDirection.x + value.translation.width,
                    y: baseDirection.y + value.translation.height
                )
                let dx = tip.x - anchor.x
                let dy = tip.y - anchor.y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard imageFrame.width > 0, imageFrame.height > 0 else { return }
                let diagonal = (imageFrame.width * imageFrame.width + imageFrame.height * imageFrame.height).squareRoot()
                var updated = base
                if distance > 1 {
                    updated.angleDegrees = Double(atan2(dy, dx) * 180 / .pi)
                }
                updated.range = Double(distance / max(diagonal / 2, 1))
                setGeometry(updated, for: gradient.id)
            }
            .onEnded { _ in dragBaseGeometry[gradient.id] = nil }
    }

    private func setGeometry(_ geometry: LocalAdjustmentGeometry, for id: UUID) {
        editor.updateAdjustments { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            adjustments.localAdjustments[index].geometry = geometry
        }
    }
}

/// iPad canvas controls for spot heal and clone adjustments. The visual
/// outlines remain lightweight, while every draggable handle gets a stable
/// 44pt touch target for portrait, landscape and Split View.
public struct SpotHealMaskOverlayView: View {
    @ObservedObject private var editor: EditorSession
    private let imageFrame: CGRect

    @State private var dragBaseGeometry: [UUID: LocalAdjustmentGeometry] = [:]

    private static let visualHandleSize: CGFloat = 12
    private static let handleHitAreaSize: CGFloat = 44

    public init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var heals: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .spotHeal }
    }

    public var body: some View {
        ZStack {
            ForEach(heals) { heal in controls(for: heal) }
        }
    }

    private func controls(for heal: LocalAdjustment) -> some View {
        let target = point(for: heal.geometry)
        let sizeHandle = sizePoint(for: heal.geometry)
        let selected = editor.selectedLocalAdjustmentID == heal.id

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(selected ? 0.75 : 0.35), lineWidth: 1)
                .frame(width: max(sizeHandle.x - target.x, 1) * 2)
                .position(target)
                .allowsHitTesting(false)

            if heal.geometry.healMode == .clone {
                let source = sourcePoint(for: heal.geometry)
                Path { path in
                    path.move(to: target)
                    path.addLine(to: source)
                }
                .stroke(Color.yellow.opacity(selected ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .allowsHitTesting(false)
                handle(at: source, tint: .yellow, label: "Spot Heal Source") {
                    sourceDrag(for: heal)
                }
            }

            handle(at: target, tint: .accentColor, label: "Spot Heal Target") {
                targetDrag(for: heal)
            }
            if selected {
                handle(at: sizeHandle, tint: .accentColor, label: "Spot Heal Size") {
                    sizeDrag(for: heal)
                }
            }
        }
    }

    private func handle(
        at point: CGPoint,
        tint: Color,
        label: String,
        drag: () -> some Gesture
    ) -> some View {
        Circle()
            .fill(tint)
            .frame(width: Self.visualHandleSize, height: Self.visualHandleSize)
            .shadow(radius: 1)
            .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
            .contentShape(Circle())
            .position(point)
            .gesture(drag())
            .accessibilityLabel(Text(L10n.t(label)))
    }

    private func point(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(geometry.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(geometry.y) * imageFrame.height
        )
    }

    private func sourcePoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        let sourceX = geometry.sourceX ?? geometry.x
        let sourceY = geometry.sourceY ?? max(geometry.y - min(geometry.radius * 2.5, 0.45), 0)
        return CGPoint(
            x: imageFrame.minX + CGFloat(sourceX) * imageFrame.width,
            y: imageFrame.minY + CGFloat(sourceY) * imageFrame.height
        )
    }

    private func sizePoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        let target = point(for: geometry)
        let distance = max(CGFloat(geometry.radius), 0.01) * min(imageFrame.width, imageFrame.height)
        return CGPoint(x: target.x + distance, y: target.y)
    }

    private func targetDrag(for heal: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = heal.id
                let base = dragBaseGeometry[heal.id] ?? heal.geometry
                if dragBaseGeometry[heal.id] == nil { dragBaseGeometry[heal.id] = base }
                var updated = base
                guard imageFrame.width > 0, imageFrame.height > 0 else { return }
                updated.x = base.x + Double(value.translation.width / imageFrame.width)
                updated.y = base.y + Double(value.translation.height / imageFrame.height)
                setGeometry(updated, for: heal.id)
            }
            .onEnded { _ in dragBaseGeometry[heal.id] = nil }
    }

    private func sourceDrag(for heal: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = heal.id
                let base = dragBaseGeometry[heal.id] ?? resolvedSourceBase(heal.geometry)
                if dragBaseGeometry[heal.id] == nil { dragBaseGeometry[heal.id] = base }
                var updated = base
                guard imageFrame.width > 0, imageFrame.height > 0 else { return }
                updated.sourceX = (base.sourceX ?? base.x) + Double(value.translation.width / imageFrame.width)
                updated.sourceY = (base.sourceY ?? base.y) + Double(value.translation.height / imageFrame.height)
                setGeometry(updated, for: heal.id)
            }
            .onEnded { _ in dragBaseGeometry[heal.id] = nil }
    }

    private func sizeDrag(for heal: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = heal.id
                let base = dragBaseGeometry[heal.id] ?? heal.geometry
                if dragBaseGeometry[heal.id] == nil { dragBaseGeometry[heal.id] = base }
                let target = point(for: base)
                let baseHandle = sizePoint(for: base)
                let dx = baseHandle.x + value.translation.width - target.x
                let dy = baseHandle.y + value.translation.height - target.y
                let shorterSide = min(imageFrame.width, imageFrame.height)
                guard shorterSide > 0 else { return }
                var updated = base
                updated.radius = Double((dx * dx + dy * dy).squareRoot() / shorterSide)
                setGeometry(updated, for: heal.id)
            }
            .onEnded { _ in dragBaseGeometry[heal.id] = nil }
    }

    private func resolvedSourceBase(_ geometry: LocalAdjustmentGeometry) -> LocalAdjustmentGeometry {
        var result = geometry
        result.sourceX = geometry.sourceX ?? geometry.x
        result.sourceY = geometry.sourceY ?? max(geometry.y - min(geometry.radius * 2.5, 0.45), 0)
        return result
    }

    private func setGeometry(_ geometry: LocalAdjustmentGeometry, for id: UUID) {
        editor.updateAdjustments { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            adjustments.localAdjustments[index].geometry = geometry
        }
    }
}
