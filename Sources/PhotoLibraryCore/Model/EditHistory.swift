import Foundation
import RawProcessingCore

/// Bounded undo/redo over immutable snapshots.
///
/// Snapshots rather than commands: `PhotoAdjustments` is ten `Double`s, so the
/// memory cost is nil and every transition is trivially correct — which matters
/// because spec §13.4 requires undo, redo and reset to be covered by tests.
public struct EditHistory<Value: Equatable>: Equatable {
    public private(set) var current: Value
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    public let limit: Int

    public init(initial: Value, limit: Int = 100) {
        self.current = initial
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// Pushes a new value. A no-op when nothing changed, so holding a slider
    /// still at its current value doesn't fill the stack with duplicates.
    @discardableResult
    public mutating func record(_ newValue: Value) -> Bool {
        guard newValue != current else { return false }
        undoStack.append(current)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        // Any new edit invalidates the redo branch.
        redoStack.removeAll()
        current = newValue
        return true
    }

    @discardableResult
    public mutating func undo() -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        return current
    }

    @discardableResult
    public mutating func redo() -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        return current
    }

    /// Replaces the value without clearing history — used when a save round-trip
    /// or an external change brings in a value the user didn't type.
    public mutating func reset(to value: Value) {
        undoStack.removeAll()
        redoStack.removeAll()
        current = value
    }
}

extension EditHistory where Value == PhotoAdjustments {
    /// "Reset this photo" — an undoable step back to neutral (spec §6.2).
    @discardableResult
    public mutating func resetToNeutral() -> Bool {
        record(.neutral)
    }

    @discardableResult
    public mutating func resetAdjustment(_ kind: AdjustmentKind) -> Bool {
        record(current.resetting(kind))
    }

    @discardableResult
    public mutating func setAdjustment(_ kind: AdjustmentKind, to value: Double) -> Bool {
        record(current.setting(kind, to: value))
    }
}
