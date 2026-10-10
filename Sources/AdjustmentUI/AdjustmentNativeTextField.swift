import SwiftUI

#if os(macOS)
import AppKit

@MainActor
private final class AdjustmentNSTextField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }
}

@MainActor
struct AdjustmentNativeTextField: NSViewRepresentable {
    let controller: AdjustmentInputController
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let fractionDigits: Int
    let identity: AnyHashable
    let revision: UInt64
    let unit: String
    let readContext: () -> (AnyHashable, UInt64)

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> NSStackView {
        let field = AdjustmentNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.focusRingType = .none
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        field.onFocus = { [weak controller] in controller?.focus() }

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .right
        errorLabel.isHidden = true

        let stack = NSStackView(views: [field, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 2
        field.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: AdjustmentControlMetrics.nudgeHitTarget),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        controller.render = { [weak field, weak errorLabel] text, error in
            field?.stringValue = text
            if let editor = field?.currentEditor(), editor.string != text { editor.string = text }
            field?.setAccessibilityHelp(error)
            errorLabel?.stringValue = error ?? ""
            errorLabel?.setAccessibilityLabel(error)
            errorLabel?.isHidden = error == nil
        }
        configure()
        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {
        configure()
    }

    private func configure() {
        controller.configure(value: value, range: range, fractionDigits: fractionDigits,
            identity: readContext().0, revision: readContext().1, unit: unit,
            readContext: readContext)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: AdjustmentInputController
        init(_ controller: AdjustmentInputController) { self.controller = controller }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            controller.edit(field.currentEditor()?.string ?? field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            controller.submit()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                controller.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                controller.cancel()
                return true
            default:
                return false
            }
        }
    }
}
#else
import UIKit

@MainActor
private final class AdjustmentUITextField: UITextField {
    var onCancel: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelDraft))]
    }
    @objc private func cancelDraft() { onCancel?() }
}

@MainActor
struct AdjustmentNativeTextField: UIViewRepresentable {
    let controller: AdjustmentInputController
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let fractionDigits: Int
    let identity: AnyHashable
    let revision: UInt64
    let unit: String
    let readContext: () -> (AnyHashable, UInt64)

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> UIStackView {
        let field = AdjustmentUITextField()
        field.textAlignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: UIFont.labelFontSize, weight: .regular)
        field.keyboardType = .numbersAndPunctuation
        field.returnKeyType = .done
        field.accessibilityLabel = label
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.onCancel = { [weak controller] in controller?.cancel() }

        let errorLabel = UILabel()
        errorLabel.font = .preferredFont(forTextStyle: .caption2)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .right
        errorLabel.isHidden = true
        let stack = UIStackView(arrangedSubviews: [field, errorLabel])
        stack.axis = .vertical
        stack.spacing = 2
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: AdjustmentControlMetrics.nudgeHitTarget).isActive = true
        controller.render = { [weak field, weak errorLabel] text, error in
            if field?.text != text { field?.text = text }
            field?.accessibilityHint = error
            errorLabel?.text = error
            errorLabel?.isHidden = error == nil
        }
        configure()
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {
        configure()
    }

    private func configure() {
        controller.configure(value: value, range: range, fractionDigits: fractionDigits,
            identity: readContext().0, revision: readContext().1, unit: unit,
            readContext: readContext)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let controller: AdjustmentInputController
        init(_ controller: AdjustmentInputController) { self.controller = controller }
        func textFieldDidBeginEditing(_ textField: UITextField) { controller.focus() }
        @objc func changed(_ field: UITextField) { controller.edit(field.text ?? "") }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            controller.submit()
            textField.resignFirstResponder()
            return true
        }
        func textFieldDidEndEditing(_ textField: UITextField) { controller.submit() }
    }
}
#endif
