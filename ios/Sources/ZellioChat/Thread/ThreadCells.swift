#if canImport(SwiftUI) && canImport(UIKit)
import UIKit
import ZellioChatCore

/// Rounded rectangle path with a different radius on each corner.
enum CornerPath {
    static func make(_ rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let w = rect.width, h = rect.height
        let tl = min(topLeft, min(w, h) / 2), tr = min(topRight, min(w, h) / 2)
        let br = min(bottomRight, min(w, h) / 2), bl = min(bottomLeft, min(w, h) / 2)
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        return path
    }
}

/// The bubble background. It clips its content (a photo fills the bubble edge to edge).
final class BubbleView: UIView {
    var topLeft: CGFloat = 20 { didSet { setNeedsLayout() } }
    var topRight: CGFloat = 20 { didSet { setNeedsLayout() } }
    var bottomLeft: CGFloat = 20 { didSet { setNeedsLayout() } }
    var bottomRight: CGFloat = 20 { didSet { setNeedsLayout() } }
    private let maskLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.mask = maskLayer
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        maskLayer.path = CornerPath.make(bounds, topLeft: topLeft, topRight: topRight, bottomRight: bottomRight, bottomLeft: bottomLeft).cgPath
    }
}

/// Remembers the real size of images once they loaded, so a row keeps its height when it is drawn again.
enum ImageRatioCache {
    private static var ratios: [String: CGFloat] = [:]
    private static let lock = NSLock()
    static func ratio(_ key: String) -> CGFloat? { lock.lock(); defer { lock.unlock() }; return ratios[key] }
    static func set(_ key: String, _ value: CGFloat) { lock.lock(); ratios[key] = value; lock.unlock() }
}

struct CellContext {
    var theme: ChatTheme
    var tableWidth: CGFloat
    var isPad: Bool
    var onRetry: (String) -> Void
    var onOpenImage: (UIImage, String) -> Void
    var onOpenURL: (URL) -> Void
    var onCopy: (String) -> Void
    var onImageSized: () -> Void
    var onImageExpired: () -> Void
}

// MARK: - Message cell

final class MessageCell: UITableViewCell {
    static let identifier = "MessageCell"

    private let outer = UIStackView()
    private let nameLabel = UILabel()
    private let nameContainer = UIView()
    private var fileStackRef: UIStackView?
    private var deliveryInnerRef: UIStackView?
    private let rowStack = UIStackView()
    private let avatar = UIView()
    private let avatarImage = UIImageView()
    private let avatarInitial = UILabel()
    private let flexible = UIView()
    private let bubble = BubbleView()
    private let content = UIStackView()
    private let imageHolder = UIView()
    private let photo = UIImageView()
    private let photoPlaceholder = UIView()
    private let photoFailed = UIStackView()
    private let photoFailedIcon = UIImageView()
    private let photoFailedLabel = UILabel()
    private let fileRow = UIControl()
    private let fileIcon = UIImageView()
    private let fileName = UILabel()
    private let fileSize = UILabel()
    private let textHolder = UIView()
    private let textView = UITextView()
    private let deliveryRow = UIStackView()
    private let deliveryIcon = UIImageView()
    private let deliveryLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var topGap: NSLayoutConstraint?
    private var bubbleMax: NSLayoutConstraint?
    private var photoHeight: NSLayoutConstraint?
    private var photoWidth: NSLayoutConstraint?
    private var context: CellContext?
    private var row: MessageRow?
    private var imageTask: Task<Void, Never>?
    private var firstImageURL: String?
    private var firstImageFailed = false
    private var currentTheme: ChatTheme?
    private var fileURL: String?
    private var textBottomCollapsed: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        backgroundColor = .clear
        selectionStyle = .none
        contentView.backgroundColor = .clear

        outer.axis = .vertical
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outer)
        let top = outer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2)
        topGap = top
        NSLayoutConstraint.activate([
            top,
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
        ])

        // Name above the first agent message of a group.
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameContainer.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: nameContainer.topAnchor, constant: 10),
            nameLabel.bottomAnchor.constraint(equalTo: nameContainer.bottomAnchor, constant: -4),
            nameLabel.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor, constant: 36),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: nameContainer.trailingAnchor),
        ])

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 8

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 14
        avatar.clipsToBounds = true
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 28), avatar.heightAnchor.constraint(equalToConstant: 28)])
        avatarImage.contentMode = .scaleAspectFill
        avatarImage.translatesAutoresizingMaskIntoConstraints = false
        avatarInitial.textAlignment = .center
        avatarInitial.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(avatarInitial)
        avatar.addSubview(avatarImage)
        NSLayoutConstraint.activate([
            avatarInitial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            avatarInitial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            avatarImage.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            avatarImage.trailingAnchor.constraint(equalTo: avatar.trailingAnchor),
            avatarImage.topAnchor.constraint(equalTo: avatar.topAnchor),
            avatarImage.bottomAnchor.constraint(equalTo: avatar.bottomAnchor),
        ])

        flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        flexible.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.setContentHuggingPriority(.required, for: .horizontal)
        let max = bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        max.priority = .required
        bubbleMax = max
        max.isActive = true

        content.axis = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bubble.topAnchor),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
        ])

        // Photo, edge to edge.
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.isUserInteractionEnabled = true
        photo.translatesAutoresizingMaskIntoConstraints = false
        photoPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        // The failed state sits under the photo view, which stays empty and takes the tap.
        photoFailedIcon.image = UIImage(systemName: "photo")
        photoFailedIcon.contentMode = .scaleAspectFit
        photoFailedLabel.numberOfLines = 0
        photoFailedLabel.textAlignment = .center
        photoFailed.axis = .vertical
        photoFailed.alignment = .center
        photoFailed.spacing = 6
        photoFailed.isHidden = true
        photoFailed.translatesAutoresizingMaskIntoConstraints = false
        photoFailed.addArrangedSubview(photoFailedIcon)
        photoFailed.addArrangedSubview(photoFailedLabel)
        imageHolder.addSubview(photoPlaceholder)
        imageHolder.addSubview(photoFailed)
        imageHolder.addSubview(photo)
        let width = imageHolder.widthAnchor.constraint(equalToConstant: 240)
        let height = imageHolder.heightAnchor.constraint(equalToConstant: 180)
        photoWidth = width
        photoHeight = height
        NSLayoutConstraint.activate([
            width, height,
            photo.leadingAnchor.constraint(equalTo: imageHolder.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: imageHolder.trailingAnchor),
            photo.topAnchor.constraint(equalTo: imageHolder.topAnchor),
            photo.bottomAnchor.constraint(equalTo: imageHolder.bottomAnchor),
            photoPlaceholder.leadingAnchor.constraint(equalTo: imageHolder.leadingAnchor),
            photoPlaceholder.trailingAnchor.constraint(equalTo: imageHolder.trailingAnchor),
            photoPlaceholder.topAnchor.constraint(equalTo: imageHolder.topAnchor),
            photoPlaceholder.bottomAnchor.constraint(equalTo: imageHolder.bottomAnchor),
            photoFailed.centerXAnchor.constraint(equalTo: imageHolder.centerXAnchor),
            photoFailed.centerYAnchor.constraint(equalTo: imageHolder.centerYAnchor),
            photoFailed.leadingAnchor.constraint(greaterThanOrEqualTo: imageHolder.leadingAnchor, constant: 8),
            photoFailedIcon.widthAnchor.constraint(equalToConstant: 28),
            photoFailedIcon.heightAnchor.constraint(equalToConstant: 28),
        ])
        photo.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(photoTapped)))

        // File row.
        fileIcon.contentMode = .center
        fileIcon.layer.cornerRadius = 11
        fileIcon.clipsToBounds = true
        fileIcon.translatesAutoresizingMaskIntoConstraints = false
        let fileText = UIStackView(arrangedSubviews: [fileName, fileSize])
        fileText.axis = .vertical
        fileText.isUserInteractionEnabled = false
        let fileStack = UIStackView(arrangedSubviews: [fileIcon, fileText])
        fileStackRef = fileStack
        fileStack.axis = .horizontal
        fileStack.spacing = 10
        fileStack.alignment = .center
        fileStack.isUserInteractionEnabled = false
        fileStack.translatesAutoresizingMaskIntoConstraints = false
        fileRow.addSubview(fileStack)
        NSLayoutConstraint.activate([
            fileIcon.widthAnchor.constraint(equalToConstant: 40), fileIcon.heightAnchor.constraint(equalToConstant: 40),
            fileStack.topAnchor.constraint(equalTo: fileRow.topAnchor, constant: 9),
            fileStack.bottomAnchor.constraint(equalTo: fileRow.bottomAnchor, constant: -9),
            fileStack.leadingAnchor.constraint(equalTo: fileRow.leadingAnchor, constant: 14),
            fileStack.trailingAnchor.constraint(equalTo: fileRow.trailingAnchor, constant: -14),
            fileRow.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])
        fileRow.addTarget(self, action: #selector(fileTapped), for: .touchUpInside)

        // Text.
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textHolder.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: textHolder.topAnchor, constant: 9),
            textView.bottomAnchor.constraint(equalTo: textHolder.bottomAnchor, constant: -9),
            textView.leadingAnchor.constraint(equalTo: textHolder.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: textHolder.trailingAnchor, constant: -14),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(bubbleTapped(_:)))
        bubble.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(bubblePressed(_:)))
        bubble.addGestureRecognizer(press)

        content.addArrangedSubview(imageHolder)
        content.addArrangedSubview(fileRow)
        content.addArrangedSubview(textHolder)

        // Delivery line.
        deliveryRow.axis = .horizontal
        deliveryRow.spacing = 8
        deliveryRow.alignment = .center
        deliveryIcon.contentMode = .scaleAspectFit
        deliveryIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([deliveryIcon.widthAnchor.constraint(equalToConstant: 14), deliveryIcon.heightAnchor.constraint(equalToConstant: 14)])
        let deliveryInner = UIStackView(arrangedSubviews: [deliveryIcon, deliveryLabel])
        deliveryInnerRef = deliveryInner
        deliveryInner.axis = .horizontal
        deliveryInner.spacing = 4
        deliveryInner.alignment = .center
        retryButton.layer.cornerRadius = 18
        retryButton.layer.borderWidth = 1
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        let deliverySpacer = UIView()
        deliverySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        deliveryRow.addArrangedSubview(deliverySpacer)
        deliveryRow.addArrangedSubview(deliveryInner)
        deliveryRow.addArrangedSubview(retryButton)
        deliveryRow.isLayoutMarginsRelativeArrangement = true
        deliveryRow.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 0, right: 2)

        outer.addArrangedSubview(nameContainer)
        outer.addArrangedSubview(rowStack)
        outer.addArrangedSubview(deliveryRow)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        photo.image = nil
        avatarImage.image = nil
        firstImageURL = nil
        firstImageFailed = false
        photoFailed.isHidden = true
        fileURL = nil
    }

    // MARK: Configure

    func configure(row: MessageRow, context: CellContext) {
        self.row = row
        self.context = context
        let theme = context.theme
        let message = row.message
        let mine = message.from == .visitor
        let rtl = theme.isRTL
        let semantic: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        for view in [contentView, outer, rowStack, deliveryRow, content, textHolder, fileRow] { view.semanticContentAttribute = semantic }
        let extraViews: [UIView?] = [nameContainer, fileStackRef, deliveryInnerRef]
        for view in extraViews.compactMap({ $0 }) { view.semanticContentAttribute = semantic }
        semanticContentAttribute = semantic

        topGap?.constant = row.startsGroup ? CGFloat(Metrics.senderGap(theme.density)) : CGFloat(Metrics.groupGap)

        // Name.
        let showName = row.showsName
        nameContainer.isHidden = !showName
        nameLabel.text = message.agentName
        nameLabel.font = theme.uiFont(.secondary, size: 12.5, weight: .medium)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = UIColor(hex: theme.palette.ink2)
        nameLabel.textAlignment = rtl ? .right : .left

        // Bubble shape and color.
        let radius = CGFloat(Metrics.bubbleRadius(theme.corners))
        let tail = row.endsGroup ? CGFloat(Metrics.tailRadius(theme.corners)) : radius
        bubble.topLeft = radius
        bubble.topRight = radius
        // The tail sits at the bottom corner on the sender's side: end side for the customer, start side for the team.
        let tailOnRight = mine ? !rtl : rtl
        bubble.bottomRight = tailOnRight ? tail : radius
        bubble.bottomLeft = tailOnRight ? radius : tail
        bubble.backgroundColor = UIColor(hex: mine ? theme.palette.customer : theme.palette.agentBubble)
        let ink = UIColor(hex: mine ? theme.palette.onCustomer : theme.palette.ink)

        // Width limit: 78 percent, 520 pt on iPad.
        let limit = context.isPad ? CGFloat(Metrics.maxBubbleWidthPad) : context.tableWidth * CGFloat(Metrics.maxBubbleFraction)
        bubbleMax?.constant = Swift.max(120, Swift.min(limit, context.tableWidth - 28 - 36))

        // Row arrangement: [avatar] bubble [flex]   or   [flex] bubble.
        for view in rowStack.arrangedSubviews { rowStack.removeArrangedSubview(view); view.removeFromSuperview() }
        if mine {
            rowStack.addArrangedSubview(flexible)
            rowStack.addArrangedSubview(bubble)
        } else {
            rowStack.addArrangedSubview(avatar)
            rowStack.addArrangedSubview(bubble)
            rowStack.addArrangedSubview(flexible)
            configureAvatar(message: message, theme: theme, visible: row.endsGroup && theme.showAgentAvatar)
        }

        // Content.
        let images = message.attachments.filter { $0.isImage }
        let files = message.attachments.filter { !$0.isImage }
        currentTheme = theme
        photoFailedIcon.tintColor = ink
        photoFailedLabel.textColor = ink
        photoFailedLabel.font = theme.uiFont(.secondary, size: 13, weight: .medium)
        photoFailedLabel.adjustsFontForContentSizeCategory = true
        photoFailedLabel.text = theme.strings.string("state.retry")
        configurePhoto(images.first, theme: theme)
        if let file = files.first {
            fileRow.isHidden = false
            fileName.text = file.name
            fileName.font = theme.uiFont(.message, size: 14.5, weight: .medium)
            fileName.textColor = ink
            fileName.adjustsFontForContentSizeCategory = true
            fileSize.text = file.size.map { ChatFormat.fileSize($0) }
            fileSize.font = theme.uiFont(.secondary, size: 12.5)
            fileSize.textColor = ink.withAlphaComponent(0.7)
            fileSize.adjustsFontForContentSizeCategory = true
            fileIcon.image = UIImage(systemName: "doc")
            fileIcon.tintColor = UIColor(hex: theme.palette.ink2)
            fileIcon.backgroundColor = mine ? UIColor.white.withAlphaComponent(0.2) : UIColor(hex: theme.palette.bg)
            fileURL = file.url
        } else {
            fileRow.isHidden = true
        }
        if message.text.isEmpty {
            textHolder.isHidden = true
        } else {
            textHolder.isHidden = false
            textView.attributedText = attributed(message.text, theme: theme, ink: ink, mine: mine)
            textView.textAlignment = .natural
        }
        // A photo with a caption: the caption has its own padding below the photo. A photo alone: nothing below.
        bubble.setNeedsLayout()

        // Delivery.
        configureDelivery(row: row, theme: theme, mine: mine)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = accessibilityText(row: row, theme: theme)
        updateAccessibilityActions()
    }

    private func accessibilityText(row: MessageRow, theme: ChatTheme) -> String {
        let strings = theme.strings
        let message = row.message
        let sender = message.from == .visitor ? strings.string("a11y.you") : (message.agentName ?? strings.string("a11y.team"))
        var text = message.text
        if text.isEmpty, let first = message.attachments.first { text = first.isImage ? strings.string("attachment.photo") : (first.name.isEmpty ? strings.string("attachment.file") : first.name) }
        let delivery = message.from == .visitor && row.showsDelivery ? ThreadLayout.deliveryText(message, strings: strings) : nil
        return strings.accessibilitySummary(sender: sender, text: text, time: row.timeLabel, delivery: delivery)
    }

    private func attributed(_ text: String, theme: ChatTheme, ink: UIColor, mine: Bool) -> NSAttributedString {
        let font = theme.uiFont(.message)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = .natural      // each paragraph follows its own direction
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = CGFloat(Metrics.lineHeightMultiple(theme.locale)) / 1.2
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
        // Links: only https, mailto and tel. Underlined.
        let linkColor = mine ? ink : UIColor(hex: theme.palette.link)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            detector.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let match = match, let url = match.url, LinkPolicy.isSafe(url.absoluteString) else { return }
                result.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: linkColor], range: match.range)
            }
        }
        return result
    }

    private func configureAvatar(message: ChatMessage, theme: ChatTheme, visible: Bool) {
        avatar.alpha = visible ? 1 : 0
        avatar.backgroundColor = UIColor(hex: theme.palette.avatarTone)
        let name = message.agentName ?? theme.brandName
        avatarInitial.text = String(name.first ?? "Z").uppercased()
        avatarInitial.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        avatarInitial.textColor = UIColor(hex: theme.palette.avatarInk)
        avatar.isHidden = !theme.showAgentAvatar
        if visible, let url = message.agentAvatarUrl {
            Task { [weak self] in
                guard let image = try? await ImageLoader.shared.load(url) else { return }
                await MainActor.run { if self?.row?.message.agentAvatarUrl == url { self?.avatarImage.image = image } }
            }
        }
    }

    /// The cell is one VoiceOver element, so everything the customer can tap is also an action.
    private func updateAccessibilityActions() {
        guard let theme = currentTheme, let message = row?.message else { return }
        let strings = theme.strings
        var actions: [UIAccessibilityCustomAction] = []
        if message.delivery == .failed {
            actions.append(UIAccessibilityCustomAction(name: strings.string("delivery.retry")) { [weak self] _ in self?.retryTapped(); return true })
        }
        if firstImageURL != nil {
            let name = firstImageFailed ? strings.string("state.retry") : strings.string("attachment.photo")
            actions.append(UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.photoTapped(); return true })
        }
        if fileURL != nil, let name = fileName.text {
            actions.append(UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.fileTapped(); return true })
        }
        accessibilityCustomActions = actions.isEmpty ? nil : actions
    }

    private func configurePhoto(_ attachment: Attachment?, theme: ChatTheme) {
        firstImageFailed = false
        photoFailed.isHidden = true
        guard let attachment = attachment else {
            imageHolder.isHidden = true
            firstImageURL = nil
            return
        }
        imageHolder.isHidden = false
        firstImageURL = attachment.url
        photoPlaceholder.backgroundColor = UIColor(hex: theme.palette.ink2).withAlphaComponent(0.18)
        let width: CGFloat = CGFloat(Metrics.maxImageWidth)
        var ratio: CGFloat = 0.75
        if let w = attachment.width, let h = attachment.height, w > 0, h > 0 { ratio = CGFloat(h) / CGFloat(w) }
        if let known = ImageRatioCache.ratio(attachment.url) { ratio = known }
        photoWidth?.constant = width
        photoHeight?.constant = Swift.min(Swift.max(width * ratio, 100), 320)
        photo.accessibilityLabel = theme.strings.string("attachment.photo")
        photo.isAccessibilityElement = false
        if let cached = ImageLoader.shared.cached(attachment.url) {
            photo.image = cached
            photoPlaceholder.isHidden = true
        } else {
            photo.image = nil
            photoPlaceholder.isHidden = false
            loadPhoto(attachment.url)
        }
    }

    private func loadPhoto(_ url: String) {
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            do {
                let image = try await ImageLoader.shared.load(url)
                await MainActor.run { self?.imageLoaded(image, url: url) }
            } catch ImageLoader.Failure.expired {
                if Task.isCancelled { return }
                // Fresh links replace this one when the page reloads. Until then the row says what to do.
                await MainActor.run {
                    self?.showPhotoFailed(url: url)
                    self?.context?.onImageExpired()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { self?.showPhotoFailed(url: url) }
            }
        }
    }

    /// The row keeps its size. A tap tries again.
    private func showPhotoFailed(url: String) {
        guard firstImageURL == url else { return }
        firstImageFailed = true
        photoFailed.isHidden = false
        updateAccessibilityActions()
    }

    private func imageLoaded(_ image: UIImage, url: String) {
        guard firstImageURL == url else { return }
        photo.image = image
        photoPlaceholder.isHidden = true
        firstImageFailed = false
        photoFailed.isHidden = true
        updateAccessibilityActions()
        if image.size.width > 0 {
            let ratio = image.size.height / image.size.width
            if ImageRatioCache.ratio(url) == nil {
                ImageRatioCache.set(url, ratio)
                context?.onImageSized()
            }
        }
    }

    private func configureDelivery(row: MessageRow, theme: ChatTheme, mine: Bool) {
        let message = row.message
        guard mine, row.showsDelivery, let text = ThreadLayout.deliveryText(message, strings: theme.strings) else {
            deliveryRow.isHidden = true
            return
        }
        deliveryRow.isHidden = false
        deliveryLabel.text = text
        deliveryLabel.font = theme.uiFont(.caption, size: message.delivery == .failed ? 12.5 : 12, weight: message.delivery == .failed ? .medium : .regular)
        deliveryLabel.adjustsFontForContentSizeCategory = true
        deliveryLabel.numberOfLines = 0
        let color: UIColor = message.delivery == .failed ? UIColor(hex: theme.palette.bad) : UIColor(hex: theme.palette.ink2)
        deliveryLabel.textColor = color
        deliveryIcon.tintColor = color
        switch message.delivery {
        case .waiting:
            deliveryIcon.image = UIImage(systemName: "clock")
            deliveryIcon.isHidden = false
        case .failed:
            deliveryIcon.image = UIImage(systemName: "exclamationmark.circle")
            deliveryIcon.isHidden = false
        default:
            deliveryIcon.image = nil
            deliveryIcon.isHidden = true
        }
        let failed = message.delivery == .failed
        retryButton.isHidden = !failed
        retryButton.setTitle(theme.strings.string("delivery.retry"), for: .normal)
        retryButton.titleLabel?.font = theme.uiFont(.secondary, size: 13.5, weight: .medium)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setTitleColor(UIColor(hex: theme.palette.ink), for: .normal)
        retryButton.layer.borderColor = UIColor(hex: theme.palette.line).cgColor
    }

    // MARK: Actions

    @objc private func retryTapped() {
        guard let id = row?.message.clientMessageId else { return }
        context?.onRetry(id)
    }

    @objc private func photoTapped() {
        if firstImageFailed, let url = firstImageURL {
            firstImageFailed = false
            photoFailed.isHidden = true
            updateAccessibilityActions()
            loadPhoto(url)
            return
        }
        guard let image = photo.image, let url = firstImageURL else { return }
        context?.onOpenImage(image, url)
    }

    @objc private func fileTapped() {
        guard let raw = fileURL, LinkPolicy.isSafe(raw), let url = URL(string: raw) else { return }
        context?.onOpenURL(url)
    }

    @objc private func bubbleTapped(_ gesture: UITapGestureRecognizer) {
        guard !textHolder.isHidden else { return }
        let point = gesture.location(in: textView)
        guard textView.bounds.contains(point) else { return }
        let inset = textView.textContainerInset
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let storage = textView.textStorage
        guard storage.length > 0 else { return }
        let index = textView.layoutManager.characterIndex(for: local, in: textView.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length, let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL else { return }
        context?.onOpenURL(url)
    }

    @objc private func bubblePressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let text = row?.message.text, !text.isEmpty else { return }
        context?.onCopy(text)
    }
}

// MARK: - Date and typing cells

final class DateCell: UITableViewCell {
    static let identifier = "DateCell"
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, theme: ChatTheme) {
        label.text = text
        label.font = theme.uiFont(.caption, weight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor(hex: theme.palette.ink2)
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityTraits = .header
    }
}

final class TypingCell: UITableViewCell {
    static let identifier = "TypingCell"
    private let bubble = BubbleView()
    private let dots = [UIView(), UIView(), UIView()]
    private let avatar = UIView()
    private let initial = UILabel()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        stack.axis = .horizontal
        stack.alignment = .bottom
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        avatar.layer.cornerRadius = 14
        avatar.translatesAutoresizingMaskIntoConstraints = false
        initial.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(initial)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 28), avatar.heightAnchor.constraint(equalToConstant: 28),
            initial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor), initial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
        ])
        let dotStack = UIStackView(arrangedSubviews: dots)
        dotStack.axis = .horizontal
        dotStack.spacing = 5
        dotStack.alignment = .center
        dotStack.translatesAutoresizingMaskIntoConstraints = false
        for dot in dots {
            dot.layer.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
        }
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(dotStack)
        NSLayoutConstraint.activate([
            dotStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            dotStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            dotStack.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            bubble.heightAnchor.constraint(equalToConstant: 38),
        ])
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(avatar)
        stack.addArrangedSubview(bubble)
        stack.addArrangedSubview(spacer)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String?, theme: ChatTheme) {
        let rtl = theme.isRTL
        let semantic: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        contentView.semanticContentAttribute = semantic
        stack.semanticContentAttribute = semantic
        avatar.backgroundColor = UIColor(hex: theme.palette.avatarTone)
        avatar.isHidden = !theme.showAgentAvatar
        initial.text = String((name ?? theme.brandName).first ?? "Z").uppercased()
        initial.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        initial.textColor = UIColor(hex: theme.palette.avatarInk)
        let radius = CGFloat(Metrics.bubbleRadius(theme.corners))
        let tail = CGFloat(Metrics.tailRadius(theme.corners))
        bubble.topLeft = radius
        bubble.topRight = radius
        bubble.bottomRight = rtl ? tail : radius
        bubble.bottomLeft = rtl ? radius : tail
        bubble.backgroundColor = UIColor(hex: theme.palette.agentBubble)
        let opacities: [Float] = [0.9, 0.6, 0.35]
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = UIColor(hex: theme.palette.ink2)
            dot.layer.removeAllAnimations()
            dot.alpha = CGFloat(opacities[index])
            if !UIAccessibility.isReduceMotionEnabled {
                // A slow wave. With reduced motion the dots stay still.
                let wave = CABasicAnimation(keyPath: "transform.translation.y")
                wave.fromValue = 0
                wave.toValue = -3
                wave.duration = 0.6
                wave.autoreverses = true
                wave.repeatCount = .infinity
                wave.beginTime = CACurrentMediaTime() + Double(index) * 0.15
                wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.layer.add(wave, forKey: "wave")
            }
        }
        isAccessibilityElement = true
        accessibilityLabel = theme.strings.string("thread.typing")
        accessibilityTraits = .updatesFrequently
    }
}
#endif
