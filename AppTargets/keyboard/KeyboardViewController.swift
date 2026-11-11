import UIKit

/// A deliberately offline keyboard for short development feedback.
///
/// The extension never reads surrounding text, persists keystrokes, or links
/// networking code. Text only leaves this controller through the system-owned
/// `UITextDocumentProxy` after an explicit key tap.
final class KeyboardViewController: UIInputViewController {
    private enum KeyRole {
        case character(String)
        case feedback(String)
        case shift
        case delete
        case space
        case newline
        case nextKeyboard
    }

    private final class KeyboardButton: UIButton {
        let keyRole: KeyRole

        init(role: KeyRole) {
            keyRole = role
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private enum Metrics {
        static let outerInset: CGFloat = 6
        static let rowSpacing: CGFloat = 6
        static let keySpacing: CGFloat = 5
        static let shortcutHeight: CGFloat = 36
        static let letterHeight: CGFloat = 42
        static let actionHeight: CGFloat = 44
    }

    private let feedbackPhrases = [
        "请按截图标注修改。",
        "请补充复现步骤。",
        "请回传验证结果。",
    ]

    private var letterButtons: [KeyboardButton] = []
    private weak var shiftButton: KeyboardButton?
    private weak var nextKeyboardButton: KeyboardButton?
    private var isShifted = false {
        didSet {
            refreshLetterTitles()
            refreshShiftAppearance()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureKeyboard()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshButtonColors()
    }

    private func configureKeyboard() {
        view.backgroundColor = .systemGroupedBackground

        let keyboardStack = UIStackView(arrangedSubviews: [
            makeFeedbackRow(),
            makeLetterRow("qwertyuiop"),
            makeLetterRow("asdfghjkl", horizontalInset: 14),
            makeShiftRow(),
            makeActionRow(),
        ])
        keyboardStack.axis = .vertical
        keyboardStack.spacing = Metrics.rowSpacing
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(keyboardStack)
        NSLayoutConstraint.activate([
            keyboardStack.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: Metrics.outerInset
            ),
            keyboardStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Metrics.outerInset
            ),
            keyboardStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            keyboardStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Metrics.outerInset
            ),
        ])

        refreshLetterTitles()
        refreshShiftAppearance()
        refreshButtonColors()
    }

    private func makeFeedbackRow() -> UIStackView {
        let buttons = feedbackPhrases.enumerated().map { index, phrase in
            let button = makeButton(
                role: .feedback(phrase),
                title: phrase,
                style: .feedback
            )
            button.accessibilityIdentifier = "feedback-phrase-\(index + 1)"
            return button
        }
        let row = makeRow(buttons, distribution: .fillEqually)
        row.heightAnchor.constraint(
            equalToConstant: Metrics.shortcutHeight
        ).isActive = true
        return row
    }

    private func makeLetterRow(
        _ letters: String,
        horizontalInset: CGFloat = 0
    ) -> UIStackView {
        let buttons = letters.map { character in
            let value = String(character)
            let button = makeButton(
                role: .character(value),
                title: value,
                style: .character
            )
            button.accessibilityIdentifier = "letter-\(value)"
            letterButtons.append(button)
            return button
        }
        let row = makeRow(buttons, distribution: .fillEqually)
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: horizontalInset,
            bottom: 0,
            trailing: horizontalInset
        )
        row.heightAnchor.constraint(
            equalToConstant: Metrics.letterHeight
        ).isActive = true
        return row
    }

    private func makeShiftRow() -> UIStackView {
        let shift = makeButton(role: .shift, imageName: "shift", style: .action)
        shift.accessibilityLabel = "大写"
        shift.accessibilityIdentifier = "shift"
        shiftButton = shift

        let letters = "zxcvbnm".map { character in
            let value = String(character)
            let button = makeButton(
                role: .character(value),
                title: value,
                style: .character
            )
            button.accessibilityIdentifier = "letter-\(value)"
            letterButtons.append(button)
            return button
        }

        let delete = makeButton(
            role: .delete,
            imageName: "delete.left",
            style: .action
        )
        delete.accessibilityLabel = "删除"
        delete.accessibilityIdentifier = "delete"

        let row = makeRow(
            [shift] + letters + [delete],
            distribution: .fillEqually
        )
        row.heightAnchor.constraint(
            equalToConstant: Metrics.letterHeight
        ).isActive = true
        return row
    }

    private func makeActionRow() -> UIStackView {
        let nextKeyboard = makeButton(
            role: .nextKeyboard,
            imageName: "globe",
            style: .action,
            useStandardTapAction: false
        )
        nextKeyboard.accessibilityLabel = "切换输入法"
        nextKeyboard.accessibilityIdentifier = "next-keyboard"
        nextKeyboard.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )
        nextKeyboardButton = nextKeyboard

        let comma = makeButton(
            role: .character(","),
            title: ",",
            style: .character
        )
        comma.accessibilityIdentifier = "comma"

        let space = makeButton(
            role: .space,
            title: "空格",
            style: .character
        )
        space.accessibilityIdentifier = "space"

        let period = makeButton(
            role: .character("."),
            title: ".",
            style: .character
        )
        period.accessibilityIdentifier = "period"

        let newline = makeButton(
            role: .newline,
            imageName: "return.left",
            style: .action
        )
        newline.accessibilityLabel = "换行"
        newline.accessibilityIdentifier = "return"

        NSLayoutConstraint.activate([
            nextKeyboard.widthAnchor.constraint(equalToConstant: 44),
            comma.widthAnchor.constraint(equalToConstant: 38),
            period.widthAnchor.constraint(equalToConstant: 38),
            newline.widthAnchor.constraint(equalToConstant: 62),
        ])

        let row = makeRow(
            [nextKeyboard, comma, space, period, newline],
            distribution: .fill
        )
        row.heightAnchor.constraint(
            equalToConstant: Metrics.actionHeight
        ).isActive = true
        return row
    }

    private func makeRow(
        _ buttons: [UIButton],
        distribution: UIStackView.Distribution
    ) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = distribution
        row.spacing = Metrics.keySpacing
        return row
    }

    private enum ButtonStyle {
        case character
        case action
        case feedback
    }

    private func makeButton(
        role: KeyRole,
        title: String? = nil,
        imageName: String? = nil,
        style: ButtonStyle,
        useStandardTapAction: Bool = true
    ) -> KeyboardButton {
        let button = KeyboardButton(role: role)
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .medium
        configuration.title = title
        if let imageName {
            configuration.image = UIImage(systemName: imageName)
        }
        switch style {
        case .character:
            configuration.baseBackgroundColor = .systemBackground
            configuration.baseForegroundColor = .label
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { attributes in
                    var updated = attributes
                    updated.font = .systemFont(ofSize: 20, weight: .regular)
                    return updated
                }
        case .action:
            configuration.baseBackgroundColor = .secondarySystemBackground
            configuration.baseForegroundColor = .label
        case .feedback:
            configuration.baseBackgroundColor = .systemBlue.withAlphaComponent(0.16)
            configuration.baseForegroundColor = .label
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { attributes in
                    var updated = attributes
                    updated.font = .systemFont(ofSize: 12, weight: .medium)
                    return updated
                }
        }
        button.configuration = configuration
        button.accessibilityTraits.insert(.keyboardKey)

        if useStandardTapAction {
            button.addTarget(
                self,
                action: #selector(keyTapped(_:)),
                for: .touchUpInside
            )
        }
        return button
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let button = sender as? KeyboardButton else {
            return
        }

        switch button.keyRole {
        case let .character(value):
            let insertedValue = isShifted ? value.uppercased() : value
            textDocumentProxy.insertText(insertedValue)
            if isShifted, value.rangeOfCharacter(
                from: .letters
            ) != nil {
                isShifted = false
            }
        case let .feedback(phrase):
            textDocumentProxy.insertText(phrase)
        case .shift:
            isShifted.toggle()
        case .delete:
            textDocumentProxy.deleteBackward()
        case .space:
            textDocumentProxy.insertText(" ")
        case .newline:
            textDocumentProxy.insertText("\n")
        case .nextKeyboard:
            break
        }
    }

    private func refreshLetterTitles() {
        for button in letterButtons {
            guard case let .character(value) = button.keyRole else {
                continue
            }
            button.configuration?.title = isShifted
                ? value.uppercased()
                : value.lowercased()
        }
    }

    private func refreshShiftAppearance() {
        shiftButton?.configuration?.image = UIImage(
            systemName: isShifted ? "shift.fill" : "shift"
        )
        shiftButton?.accessibilityValue = isShifted ? "已开启" : "已关闭"
    }

    private func refreshButtonColors() {
        let isDarkKeyboard = textDocumentProxy.keyboardAppearance == .dark
        view.overrideUserInterfaceStyle = isDarkKeyboard ? .dark : .light
    }
}
