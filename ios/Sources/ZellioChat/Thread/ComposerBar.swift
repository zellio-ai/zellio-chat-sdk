#if canImport(SwiftUI) && canImport(UIKit)
import UIKit
import ZellioChatCore

/// One attachment on its way: a thumbnail with a progress ring. Tap cancels or removes it.
final class PendingChip: UIControl {
    enum State { case uploading(Double), ready, failed }

    let id: String
    private let image = UIImageView()
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private let overlay = UIView()
    private let icon = UIImageView()

    init(id: String, thumbnail: UIImage?, fileName: String) {
        self.id = id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 12
        clipsToBounds = true
        backgroundColor = UIColor.gray.withAlphaComponent(0.25)
        image.image = thumbnail
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        overlay.isUserInteractionEnabled = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        if thumbnail == nil { icon.image = UIImage(systemName: "doc") }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56), heightAnchor.constraint(equalToConstant: 56),
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor), overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor), overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        for shape in [track, ring] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 3
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.strokeEnd = 0
        isAccessibilityElement = true
        accessibilityLabel = fileName
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: 14, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        track.path = path
        ring.path = path
    }

    func apply(_ state: State) {
        switch state {
        case .uploading(let progress):
            overlay.isHidden = false
            track.isHidden = false
            ring.isHidden = false
            ring.strokeEnd = CGFloat(Swift.max(0.05, Swift.min(1, progress)))
            icon.image = UIImage(systemName: "xmark")
            icon.isHidden = false
        case .ready:
            overlay.isHidden = true
            track.isHidden = true
            ring.isHidden = true
            icon.isHidden = true
        case .failed:
            overlay.isHidden = false
            track.isHidden = true
            ring.isHidden = true
            icon.image = UIImage(systemName: "exclamationmark.circle")
            icon.isHidden = false
        }
    }
}

/// The composer. On a phone it is the thread's input accessory view, so the keyboard dismisses interactively by drag.
final class ComposerBar: UIView, UITextViewDelegate {
    var onSend: ((String) -> Void)?
    var onAttach: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    var onHeightChange: (() -> Void)?

    private let topLine = UIView()
    private let attachButton = UIButton(type: .system)
    private let pill = UIView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let chips = UIStackView()
    private let chipScroll = UIScrollView()
    private let statusLabel = UILabel()
    private let column = UIStackView()
    private var chipHeight: NSLayoutConstraint?
    private var theme: ChatTheme = .fallback
    private var canAttach = true
    private var inputRow: UIStackView?
    private(set) var hasPendingAttachments = false
    private var textHeight: CGFloat = 36
    private var textHeightConstraint: NSLayoutConstraint?
    private var pillMinHeight: CGFloat = 44

    init() {
        super.init(frame: .zero)
        autoresizingMask = .flexibleHeight
        build()
    }

    required init?(coder: NSCoder) { nil }

    var text: String {
        get { textView.text ?? "" }
        set { textView.text = newValue; refresh() }
    }

    func focus() { textView.becomeFirstResponder() }

    private func build() {
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)

        attachButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        attachButton.translatesAutoresizingMaskIntoConstraints = false

        pill.layer.cornerRadius = 22
        pill.layer.borderWidth = 1
        pill.translatesAutoresizingMaskIntoConstraints = false

        textView.delegate = self
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.returnKeyType = .default
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        sendButton.layer.cornerRadius = CGFloat(Metrics.composerSend) / 2
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(textView)
        pill.addSubview(placeholder)
        pill.addSubview(sendButton)

        // The send circle is 36 pt. The touch area is 44 pt (the pill is 44 pt high).
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: CGFloat(Metrics.composerSend)),
            sendButton.heightAnchor.constraint(equalToConstant: CGFloat(Metrics.composerSend)),
            sendButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -4),
            sendButton.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
            textView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            textView.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            textView.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 7),
            pill.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let heightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true
        textHeightConstraint = heightConstraint

        let inputRow = UIStackView(arrangedSubviews: [attachButton, pill])
        self.inputRow = inputRow
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 6
        NSLayoutConstraint.activate([
            attachButton.widthAnchor.constraint(equalToConstant: 44),
            attachButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        chips.axis = .horizontal
        chips.spacing = 8
        chips.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.addSubview(chips)
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor, constant: 10),
            chips.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor, constant: -10),
            chips.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
        ])
        let height = chipScroll.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        chipHeight = height

        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(statusLabel)
        column.addArrangedSubview(chipScroll)
        column.addArrangedSubview(inputRow)
        addSubview(column)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            column.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        refresh()
    }

    // MARK: Theme

    func apply(theme: ChatTheme, canAttach: Bool) {
        self.theme = theme
        self.canAttach = canAttach
        let rtl = theme.isRTL
        let semantic: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        let views: [UIView] = [self, column, pill, textView, placeholder, sendButton, chipScroll, chips, statusLabel]
        for view in views { view.semanticContentAttribute = semantic }
        inputRow?.semanticContentAttribute = semantic
        semanticContentAttribute = semantic
        backgroundColor = UIColor(hex: theme.palette.bg)
        topLine.backgroundColor = UIColor(hex: theme.palette.line)
        pill.backgroundColor = UIColor(hex: theme.palette.bgAlt)
        pill.layer.borderColor = UIColor(hex: theme.palette.line).cgColor
        attachButton.tintColor = UIColor(hex: theme.palette.ink2)
        attachButton.isHidden = !canAttach
        attachButton.accessibilityLabel = theme.strings.string("composer.attach")
        textView.font = theme.uiFont(.message)
        textView.textColor = UIColor(hex: theme.palette.ink)
        textView.tintColor = UIColor(hex: theme.palette.primary)
        textView.textAlignment = .natural
        textView.keyboardAppearance = theme.palette.isDark ? .dark : .light
        textView.accessibilityLabel = theme.strings.string("composer.placeholder")
        placeholder.text = theme.strings.string("composer.placeholder")
        placeholder.font = theme.uiFont(.message)
        placeholder.textColor = UIColor(hex: theme.palette.ink2)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textAlignment = .natural
        sendButton.accessibilityLabel = theme.strings.string("composer.send")
        statusLabel.font = theme.uiFont(.secondary, size: 13)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = UIColor(hex: theme.palette.bad)
        refresh()
    }

    // MARK: State

    private func refresh() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !(textView.text ?? "").isEmpty
        let enabled = hasText || (hasPendingAttachments && allChipsReady)
        sendButton.isEnabled = enabled
        sendButton.backgroundColor = UIColor(hex: enabled ? theme.palette.primary : theme.palette.disabledSend)
        sendButton.tintColor = UIColor(hex: enabled ? theme.palette.onPrimary : theme.palette.ink2)
        updateHeight()
    }

    private var allChipsReady = true
    func setChipsReady(_ ready: Bool) { allChipsReady = ready; refresh() }

    private func updateHeight() {
        // Grows to 6 lines, then scrolls.
        let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let maxHeight = ceil(font.lineHeight * 6) + 14
        let width = Swift.max(textView.bounds.width, 120)
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        textView.isScrollEnabled = fitting > maxHeight
        let target = Swift.min(fitting, maxHeight)
        if abs(target - textHeight) > 0.5 {
            textHeight = target
            textHeightConstraint?.constant = target
            setNeedsLayout()
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 { updateHeight() }
    }

    func setStatus(_ text: String?) {
        statusLabel.text = text
        statusLabel.isHidden = (text ?? "").isEmpty
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    func setChips(_ views: [PendingChip]) {
        for view in chips.arrangedSubviews { chips.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { chips.addArrangedSubview(view) }
        hasPendingAttachments = !views.isEmpty
        chipHeight?.constant = views.isEmpty ? 0 : 56
        chipScroll.isHidden = views.isEmpty
        refresh()
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    /// The attach button is off at the limit of files for one message. `canAttach` (from the server) can still hide it.
    func setAttachEnabled(_ enabled: Bool) {
        attachButton.isEnabled = enabled
        attachButton.alpha = enabled ? 1 : 0.4
    }

    func clear() {
        textView.text = ""
        refresh()
    }

    // MARK: Actions

    @objc private func sendTapped() {
        let value = textView.text ?? ""
        onSend?(value)
    }

    @objc private func attachTapped() { onAttach?() }

    func textViewDidChange(_ textView: UITextView) {
        refresh()
        onTextChange?(textView.text ?? "")
    }

    var attachAnchor: UIView { attachButton }
}
#endif
