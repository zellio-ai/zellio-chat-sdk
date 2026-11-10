#if canImport(SwiftUI) && canImport(UIKit)
import UIKit

/// The small banner for a new message while the chat is closed and the app is open.
/// It hides after 4 s, swipe up closes it, a tap opens the chat.
final class InAppBannerController {
    private var view: BannerView?
    private var hideTask: DispatchWorkItem?

    func show(name: String, brand: String, text: String, avatarURL: String?, theme: ChatTheme, in window: UIWindow?, onTap: @escaping () -> Void) {
        guard let window = window else { return }
        hide(animated: false)
        let banner = BannerView(name: name, text: text, avatarURL: avatarURL, theme: theme)
        banner.semanticContentAttribute = theme.isRTL ? .forceRightToLeft : .forceLeftToRight
        banner.onTap = { [weak self] in
            self?.hide(animated: true)
            onTap()
        }
        banner.onSwipeUp = { [weak self] in self?.hide(animated: true) }
        banner.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(banner)
        let guide = window.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
        ])
        // On a phone the banner fills the width between the margins.
        let wide = banner.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12)
        wide.priority = .defaultHigh
        wide.isActive = true
        window.layoutIfNeeded()
        view = banner
        let reduced = UIAccessibility.isReduceMotionEnabled
        banner.alpha = 0
        banner.transform = reduced ? .identity : CGAffineTransform(translationX: 0, y: -banner.bounds.height - 20)
        UIView.animate(withDuration: reduced ? 0.01 : 0.28, delay: 0, options: .curveEaseOut) {
            banner.alpha = 1
            banner.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: "\(name). \(text)")
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let banner = view else { return }
        view = nil
        guard animated else {
            banner.removeFromSuperview()
            return
        }
        let reduced = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduced ? 0.01 : 0.22, animations: {
            banner.alpha = 0
            if !reduced { banner.transform = CGAffineTransform(translationX: 0, y: -banner.bounds.height - 20) }
        }, completion: { _ in banner.removeFromSuperview() })
    }
}

private final class BannerView: UIView {
    var onTap: () -> Void = {}
    var onSwipeUp: () -> Void = {}

    init(name: String, text: String, avatarURL: String?, theme: ChatTheme) {
        super.init(frame: .zero)
        let palette = theme.palette
        backgroundColor = theme.uiColor(palette.bg)
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.borderWidth = 1
        layer.borderColor = theme.uiColor(palette.line).cgColor

        let avatar = UIImageView()
        avatar.backgroundColor = theme.uiColor(palette.avatarTone)
        avatar.layer.cornerRadius = 18
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.isAccessibilityElement = false
        let initial = UILabel()
        initial.text = String(name.prefix(1)).uppercased()
        initial.font = theme.uiFont(.secondary, size: 15, weight: .semibold)
        initial.textColor = theme.uiColor(palette.avatarInk)
        initial.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(initial)
        NSLayoutConstraint.activate([
            initial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
        ])
        if let urlString = avatarURL {
            Task { [weak avatar, weak initial] in
                if let image = try? await ImageLoader.shared.load(urlString) {
                    await MainActor.run {
                        avatar?.image = image
                        initial?.isHidden = true
                    }
                }
            }
        }

        let title = UILabel()
        title.text = name
        title.font = theme.uiFont(.secondary, size: 14, weight: .semibold)
        title.textColor = theme.uiColor(palette.ink)
        title.adjustsFontForContentSizeCategory = true
        let body = UILabel()
        body.text = text
        body.font = theme.uiFont(.secondary, size: 13.5)
        body.textColor = theme.uiColor(palette.ink2)
        body.numberOfLines = 2
        body.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 2
        let row = UIStackView(arrangedSubviews: [avatar, stack])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(name). \(text)"
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        swipe.direction = .up
        addGestureRecognizer(swipe)
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func tapped() { onTap() }
    @objc private func swiped() { onSwipeUp() }
    override func accessibilityActivate() -> Bool {
        onTap()
        return true
    }
}
#endif
