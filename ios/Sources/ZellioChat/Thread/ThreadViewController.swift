#if canImport(SwiftUI) && canImport(UIKit)
import UIKit
import ZellioChatCore

struct ThreadServices {
    var canAttach: Bool
    var greeting: String
    var soundEnabled: Bool
    var upload: (Data, String, String, @escaping @Sendable (Double) -> Void) async throws -> Attachment
}

private final class PendingUpload {
    let id = UUID().uuidString
    let file: PickedFile
    let chip: PendingChip
    var attachment: Attachment?
    var failed = false
    var task: Task<Void, Never>?

    init(file: PickedFile) {
        self.file = file
        self.chip = PendingChip(id: UUID().uuidString, thumbnail: file.thumbnail, fileName: file.fileName)
    }
}

/// The thread, as a UITableView in a UIViewController.
///
/// Why not SwiftUI List: on iOS 15 a List cannot keep the newest message anchored at the bottom when the
/// keyboard opens, cannot prepend older messages without a jump, and cannot dismiss the keyboard by drag while
/// the composer follows it. A UITableView with the composer as `inputAccessoryView` does all three natively.
///
/// iPad: an input accessory view sits at the bottom of the window, outside the form sheet. There the composer
/// is a subview on the keyboard layout guide.
final class ThreadViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    /// One message carries at most this many files on the client. The server allows 5; Android uses 4 too.
    static let maxAttachmentsPerMessage = 4

    private let controller: ThreadController
    private var theme: ChatTheme
    private var services: ThreadServices

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composer = ComposerBar()
    private let picker = AttachmentPicker()
    private let pill = UIButton(type: .system)
    private let olderSpinner = UIActivityIndicatorView(style: .medium)
    private let centerStack = UIStackView()
    private let centerSpinner = UIActivityIndicatorView(style: .medium)
    private let centerLabel = UILabel()
    private let centerButton = UIButton(type: .system)
    private let toast = UILabel()
    private var pillBottom: NSLayoutConstraint?

    private var rows: [ThreadRow] = []
    private var snapshot = ThreadSnapshot()
    private var heights: [String: CGFloat] = [:]
    private var lastIncoming = 0
    private var overlapBase: CGFloat = 0
    private var overlap: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var uploads: [PendingUpload] = []
    private var started = false
    private var tornDown = false
    private var autoDismissTask: Task<Void, Never>?
    private let embedsComposer = UIDevice.current.userInterfaceIdiom == .pad

    init(controller: ThreadController, theme: ChatTheme, services: ThreadServices) {
        self.controller = controller
        self.theme = theme
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { !embedsComposer }
    override var inputAccessoryView: UIView? { embedsComposer ? nil : composer }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.allowsSelection = false
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.alwaysBounceVertical = true
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.identifier)
        tableView.register(DateCell.self, forCellReuseIdentifier: DateCell.identifier)
        tableView.register(TypingCell.self, forCellReuseIdentifier: TypingCell.identifier)
        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 8))
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        olderSpinner.hidesWhenStopped = true
        olderSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(olderSpinner)
        NSLayoutConstraint.activate([
            olderSpinner.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            olderSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 14
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerLabel.numberOfLines = 0
        centerLabel.textAlignment = .center
        centerButton.layer.cornerRadius = 24
        centerButton.layer.borderWidth = 1
        centerButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 26, bottom: 0, right: 26)
        centerButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        centerButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        centerStack.addArrangedSubview(centerSpinner)
        centerStack.addArrangedSubview(centerLabel)
        centerStack.addArrangedSubview(centerButton)
        view.addSubview(centerStack)
        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        pill.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        pill.layer.cornerRadius = 20
        pill.setImage(UIImage(systemName: "arrow.down"), for: .normal)
        pill.isHidden = true
        pill.addTarget(self, action: #selector(pillTapped), for: .touchUpInside)
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)
        let bottom = pill.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        pillBottom = bottom
        NSLayoutConstraint.activate([bottom, pill.centerXAnchor.constraint(equalTo: view.centerXAnchor), pill.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])

        toast.alpha = 0
        toast.textAlignment = .center
        toast.layer.cornerRadius = 14
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            toast.heightAnchor.constraint(equalToConstant: 32),
        ])

        if embedsComposer {
            composer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(composer)
            NSLayoutConstraint.activate([
                composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            ])
        }

        composer.onSend = { [weak self] text in self?.sendTapped(text) }
        composer.onAttach = { [weak self] in self?.attachTapped() }
        composer.onTextChange = { [weak self] text in
            guard let self = self else { return }
            let controller = self.controller
            Task { await controller.saveDraft(text) }
        }
        composer.onHeightChange = { [weak self] in self?.composerHeightChanged() }
        picker.presenter = self
        picker.onPicked = { [weak self] file in self?.startUpload(file) }
        picker.onProblem = { [weak self] problem in self?.showProblem(problem) }

        applyTheme()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contentSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)

        let controller = self.controller
        Task {
            await controller.setObserver { [weak self] snap in
                DispatchQueue.main.async { self?.apply(snap) }
            }
            let draft = await controller.draft()
            await MainActor.run { [weak self] in self?.composer.text = draft }
            await controller.start()
        }
        started = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed { teardown() }
    }

    /// Called when the screen goes away: stop the controller, cancel uploads, release the accessory view.
    func teardown() {
        if tornDown { return }
        tornDown = true
        NotificationCenter.default.removeObserver(self)
        for upload in uploads { upload.task?.cancel() }
        composer.resignFirstResponder()
        resignFirstResponder()
        let controller = self.controller
        Task { await controller.stop() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Theme

    func update(theme: ChatTheme, services: ThreadServices) {
        let themeChanged = self.theme.palette != theme.palette || self.theme.locale != theme.locale || self.theme.fontName != theme.fontName
        self.theme = theme
        self.services = services
        if isViewLoaded {
            applyTheme()
            if themeChanged { heights.removeAll(); tableView.reloadData() }
        }
    }

    private func applyTheme() {
        let semantic: UISemanticContentAttribute = theme.isRTL ? .forceRightToLeft : .forceLeftToRight
        view.semanticContentAttribute = semantic
        tableView.semanticContentAttribute = semantic
        view.backgroundColor = UIColor(hex: theme.palette.bg)
        tableView.backgroundColor = .clear
        overrideUserInterfaceStyle = theme.palette.isDark ? .dark : .light
        composer.overrideUserInterfaceStyle = theme.palette.isDark ? .dark : .light
        composer.apply(theme: theme, canAttach: services.canAttach)
        picker.theme = theme
        let strings = theme.strings
        olderSpinner.color = UIColor(hex: theme.palette.ink2)
        olderSpinner.accessibilityLabel = strings.string("thread.loadingOlder")
        centerSpinner.color = UIColor(hex: theme.palette.ink2)
        centerLabel.font = theme.uiFont(.message)
        centerLabel.adjustsFontForContentSizeCategory = true
        centerLabel.textColor = UIColor(hex: theme.palette.ink2)
        centerButton.setTitle(strings.string("state.retry"), for: .normal)
        centerButton.titleLabel?.font = theme.uiFont(.message, size: 15.5, weight: .medium)
        centerButton.setTitleColor(UIColor(hex: theme.palette.ink), for: .normal)
        centerButton.layer.borderColor = UIColor(hex: theme.palette.line).cgColor
        pill.backgroundColor = UIColor(hex: theme.palette.primary)
        pill.tintColor = UIColor(hex: theme.palette.onPrimary)
        pill.setTitle("  " + strings.string("thread.newMessage"), for: .normal)
        pill.setTitleColor(UIColor(hex: theme.palette.onPrimary), for: .normal)
        pill.titleLabel?.font = theme.uiFont(.secondary, size: 13.5, weight: .semibold)
        pill.titleLabel?.adjustsFontForContentSizeCategory = true
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.2
        pill.layer.shadowRadius = 8
        pill.layer.shadowOffset = CGSize(width: 0, height: 4)
        toast.font = theme.uiFont(.secondary, size: 13, weight: .medium)
        toast.backgroundColor = UIColor(hex: theme.palette.ink)
        toast.textColor = UIColor(hex: theme.palette.bg)
    }

    @objc private func contentSizeChanged() {
        heights.removeAll()
        tableView.reloadData()
    }

    // MARK: Layout and keyboard

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if abs(view.bounds.width - lastWidth) > 0.5 {
            lastWidth = view.bounds.width
            heights.removeAll()
            tableView.reloadData()
        }
        // The layout guide moves the composer. The last row stays above it.
        if embedsComposer { setOverlap(view.bounds.maxY - composer.frame.minY, duration: 0, options: []) }
        updateTopInset()
    }

    /// Short conversations sit at the bottom, like the canvas.
    private func updateTopInset() {
        let free = tableView.bounds.height - tableView.contentSize.height - tableView.contentInset.bottom
        let top = Swift.max(0, free)
        if abs(tableView.contentInset.top - top) > 0.5 {
            tableView.contentInset.top = top
        }
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard !embedsComposer, isViewLoaded, view.window != nil else { return }
        let info = note.userInfo ?? [:]
        guard let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let local = view.convert(end, from: view.window)
        let newOverlap = Swift.max(0, view.bounds.maxY - local.minY)
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        // The frame includes the composer. Keep the part that is the keyboard alone.
        overlapBase = Swift.max(0, newOverlap - composerHeight)
        setOverlap(newOverlap, duration: duration, options: options)
    }

    private var composerHeight: CGFloat { composer.bounds.height }

    private func composerHeightChanged() {
        // The composer grew or shrank (more lines, a thumbnail row). Keep the bottom where it was.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isViewLoaded else { return }
            if self.embedsComposer { self.view.setNeedsLayout(); return }
            self.setOverlap(self.overlapBase + self.composerHeight, duration: 0.15, options: .curveEaseOut)
        }
    }

    private func setOverlap(_ value: CGFloat, duration: Double, options: UIView.AnimationOptions) {
        let delta = value - overlap
        if abs(delta) < 0.5 { return }
        let wasAtBottom = isNearBottom
        overlap = value
        let apply = {
            self.tableView.contentInset.bottom = value
            self.tableView.verticalScrollIndicatorInsets.bottom = value
            self.pillBottom?.constant = -(value + 12)
            if wasAtBottom && !self.rows.isEmpty {
                let y = Swift.max(-self.tableView.contentInset.top, self.tableView.contentSize.height + value - self.tableView.bounds.height)
                self.tableView.contentOffset = CGPoint(x: 0, y: y)
            }
            self.view.layoutIfNeeded()
        }
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: apply)
    }

    // MARK: Snapshot

    private var isNearBottom: Bool {
        let maxOffset = tableView.contentSize.height + tableView.contentInset.bottom - tableView.bounds.height
        if maxOffset <= -tableView.contentInset.top { return true }
        return tableView.contentOffset.y >= maxOffset - 60
    }

    private func apply(_ snap: ThreadSnapshot) {
        if tornDown { return }
        let previous = snapshot
        snapshot = snap
        let newRows = ThreadLayout.rows(messages: snap.messages, typing: snap.typing, typingName: snap.typingName, now: Date(), locale: theme.locale)
        let wasAtBottom = isNearBottom
        let incoming = snap.incomingCount - lastIncoming
        lastIncoming = snap.incomingCount
        updateRows(newRows, wasAtBottom: wasAtBottom, animateTail: incoming > 0 || previous.messages.count < snap.messages.count)

        if snap.isLoadingOlder { olderSpinner.startAnimating() } else { olderSpinner.stopAnimating() }
        updateCenter()

        if incoming > 0 {
            if services.soundEnabled { Haptics.incomingSound() }
            Haptics.incomingTick()
            announce(snap)
            if !wasAtBottom { showPill() }
        }
        if let error = snap.error, case .rateLimited = error {
            composer.setStatus(theme.strings.string("state.rateLimited"))
        }
        let failedNow = snap.messages.filter { $0.delivery == .failed }.count
        let failedBefore = previous.messages.filter { $0.delivery == .failed }.count
        if failedNow > failedBefore { Haptics.failure() }
    }

    private func announce(_ snap: ThreadSnapshot) {
        guard let last = snap.messages.last(where: { $0.from == .agent }) else { return }
        let sender = last.agentName ?? theme.strings.string("a11y.team")
        let text = theme.strings.string("thread.newMessage") + ", " + sender
        let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func updateRows(_ newRows: [ThreadRow], wasAtBottom: Bool, animateTail: Bool) {
        let oldIds = rows.map { $0.id }
        let newIds = newRows.map { $0.id }

        if oldIds == newIds {
            var changed: [IndexPath] = []
            for index in newRows.indices where rows[index] != newRows[index] { changed.append(IndexPath(row: index, section: 0)) }
            rows = newRows
            if !changed.isEmpty {
                UIView.performWithoutAnimation {
                    self.tableView.reloadRows(at: changed, with: .none)
                    self.tableView.layoutIfNeeded()
                }
                if wasAtBottom { scrollToBottom(animated: false) }
            }
            return
        }

        if oldIds.isEmpty {
            rows = newRows
            tableView.reloadData()
            tableView.layoutIfNeeded()
            updateTopInset()
            scrollToBottom(animated: false)
            DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
            return
        }

        // Older messages added above: keep what the customer reads in the same place.
        if let first = oldIds.first, let offset = newIds.firstIndex(of: first), offset > 0, Array(newIds[offset...].prefix(oldIds.count)) == oldIds {
            let oldHeight = tableView.contentSize.height
            let oldOffset = tableView.contentOffset.y
            rows = newRows
            UIView.performWithoutAnimation {
                self.tableView.reloadData()
                self.tableView.layoutIfNeeded()
                let grown = self.tableView.contentSize.height - oldHeight
                self.tableView.contentOffset = CGPoint(x: 0, y: oldOffset + grown)
            }
            return
        }

        // Appended at the end.
        if newIds.count > oldIds.count, Array(newIds.prefix(oldIds.count)) == oldIds {
            let start = oldIds.count
            rows = newRows
            let paths = (start..<newRows.count).map { IndexPath(row: $0, section: 0) }
            UIView.performWithoutAnimation {
                self.tableView.insertRows(at: paths, with: .none)
                self.tableView.layoutIfNeeded()
            }
            updateTopInset()
            if wasAtBottom {
                scrollToBottom(animated: !MotionPolicy.reduced)
                if animateTail { animateAppearance(of: paths) }
            }
            return
        }

        // Anything else: draw again and keep the bottom if the customer was there.
        rows = newRows
        UIView.performWithoutAnimation {
            self.tableView.reloadData()
            self.tableView.layoutIfNeeded()
        }
        updateTopInset()
        if wasAtBottom { scrollToBottom(animated: false) }
    }

    /// A new row slides up 8 pt with a fade, in 180 ms, ease out. With reduced motion: fade only.
    private func animateAppearance(of paths: [IndexPath]) {
        for path in paths {
            guard let cell = tableView.cellForRow(at: path), !(cell is DateCell) else { continue }
            let reduced = MotionPolicy.reduced
            cell.alpha = 0
            if !reduced { cell.transform = CGAffineTransform(translationX: 0, y: 8) }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                cell.alpha = 1
                cell.transform = .identity
            })
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard !rows.isEmpty else { return }
        tableView.layoutIfNeeded()
        let y = Swift.max(-tableView.contentInset.top, tableView.contentSize.height + tableView.contentInset.bottom - tableView.bounds.height)
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        pill.isHidden = true
    }

    private func updateCenter() {
        let strings = theme.strings
        let hasRows = !rows.isEmpty
        if hasRows {
            centerStack.isHidden = true
            return
        }
        centerStack.isHidden = false
        if snapshot.isLoading {
            centerSpinner.startAnimating()
            centerSpinner.isHidden = false
            centerLabel.text = strings.string("state.loading")
            centerButton.isHidden = true
        } else if let error = snapshot.error {
            centerSpinner.stopAnimating()
            centerSpinner.isHidden = true
            switch error {
            case .rateLimited: centerLabel.text = strings.string("state.rateLimited")
            case .loginNeeded: centerLabel.text = strings.string("state.loginNeeded")
            case .unavailable: centerLabel.text = strings.string("state.unavailable")
            default: centerLabel.text = strings.string("state.loadFailed")
            }
            centerButton.isHidden = (error == .loginNeeded || error == .unavailable)
        } else {
            centerSpinner.stopAnimating()
            centerSpinner.isHidden = true
            centerLabel.text = services.greeting
            centerButton.isHidden = true
        }
    }

    private func showPill() {
        guard !MotionPolicy.reduced else { pill.isHidden = false; return }
        pill.alpha = 0
        pill.isHidden = false
        UIView.animate(withDuration: 0.18) { self.pill.alpha = 1 }
    }

    @objc private func pillTapped() { scrollToBottom(animated: true) }

    @objc private func retryLoad() {
        let controller = self.controller
        Task { await controller.retryLoad() }
    }

    // MARK: Sending

    private func sendTapped(_ text: String) {
        if uploads.contains(where: { $0.attachment == nil && !$0.failed }) { return }
        let attachments = uploads.compactMap { $0.attachment }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty { return }
        Haptics.sendTap()
        composer.clear()
        composer.setStatus(nil)
        uploads.removeAll()
        composer.setChips([])
        composer.setAttachEnabled(true)
        let controller = self.controller
        Task {
            await controller.send(text: trimmed, attachments: attachments)
            await controller.saveDraft("")
        }
        // The customer's own message always brings the list to the bottom.
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: true) }
    }

    private func attachTapped() {
        if uploads.count >= ThreadViewController.maxAttachmentsPerMessage { return }
        picker.showSheet(sourceView: composer.attachAnchor)
    }

    private func startUpload(_ file: PickedFile) {
        if uploads.count >= ThreadViewController.maxAttachmentsPerMessage { return }
        let upload = PendingUpload(file: file)
        uploads.append(upload)
        upload.chip.apply(.uploading(0))
        upload.chip.addAction(UIAction { [weak self, weak upload] _ in
            guard let self = self, let upload = upload else { return }
            upload.task?.cancel()
            self.uploads.removeAll { $0 === upload }
            self.refreshChips()
        }, for: .touchUpInside)
        refreshChips()
        let chip = upload.chip
        let uploader = services.upload
        upload.task = Task { [weak self, weak upload] in
            do {
                let attachment = try await uploader(file.data, file.fileName, file.mimeType) { progress in
                    DispatchQueue.main.async { chip.apply(.uploading(progress)) }
                }
                await MainActor.run {
                    upload?.attachment = attachment
                    chip.apply(.ready)
                    self?.refreshChips()
                }
            } catch {
                let mapped = ErrorPolicy.map(error)
                await MainActor.run {
                    if mapped == .cancelled { return }
                    upload?.failed = true
                    chip.apply(.failed)
                    self?.showProblem(mapped)
                    self?.refreshChips()
                }
            }
        }
    }

    private func refreshChips() {
        composer.setAttachEnabled(uploads.count < ThreadViewController.maxAttachmentsPerMessage)
        composer.setChips(uploads.map { $0.chip })
        composer.setChipsReady(!uploads.contains { $0.attachment == nil && !$0.failed } && !uploads.contains { $0.failed })
    }

    private func showProblem(_ error: ChatError) {
        let strings = theme.strings
        switch error {
        case .fileTooLarge: composer.setStatus(strings.string("attachment.tooLarge"))
        case .fileTypeDenied: composer.setStatus(strings.string("attachment.typeDenied"))
        case .filesDisabled:
            services.canAttach = false
            composer.apply(theme: theme, canAttach: false)
        default: composer.setStatus(strings.string("attachment.failed"))
        }
        Haptics.failure()
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.composer.setStatus(nil) }
        }
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    private func cellContext() -> CellContext {
        CellContext(
            theme: theme,
            tableWidth: tableView.bounds.width,
            isPad: traitCollection.userInterfaceIdiom == .pad,
            onRetry: { [weak self] id in
                guard let self = self else { return }
                let controller = self.controller
                Task { await controller.retry(clientMessageId: id) }
            },
            onOpenImage: { [weak self] image, _ in
                guard let self = self else { return }
                let viewer = ImageViewerController(image: image, closeLabel: self.theme.strings.string("attachment.close"))
                self.present(viewer, animated: true)
            },
            onOpenURL: { url in
                // Only https, mailto and tel. The system asks before it dials or writes.
                guard LinkPolicy.isSafe(url.absoluteString) else { return }
                UIApplication.shared.open(url)
            },
            onCopy: { [weak self] text in
                UIPasteboard.general.string = text
                self?.showToast()
            },
            onImageSized: { [weak self] in
                guard let self = self else { return }
                let wasAtBottom = self.isNearBottom
                UIView.performWithoutAnimation {
                    self.heights.removeAll()
                    self.tableView.beginUpdates()
                    self.tableView.endUpdates()
                }
                if wasAtBottom { self.scrollToBottom(animated: false) }
            },
            onImageExpired: { [weak self] in
                guard let self = self else { return }
                let controller = self.controller
                Task { await controller.reloadAfterExpiredAttachment() }
            }
        )
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        switch row {
        case .date(_, let label):
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DateCell.identifier, for: indexPath) as? DateCell else { return UITableViewCell() }
            cell.configure(text: label, theme: theme)
            return cell
        case .typing(let name):
            guard let cell = tableView.dequeueReusableCell(withIdentifier: TypingCell.identifier, for: indexPath) as? TypingCell else { return UITableViewCell() }
            cell.configure(name: name, theme: theme)
            return cell
        case .message(let message):
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.identifier, for: indexPath) as? MessageCell else { return UITableViewCell() }
            cell.configure(row: message, context: cellContext())
            return cell
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < rows.count else { return 64 }
        return heights[rows[indexPath.row].id] ?? 64
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < rows.count else { return }
        heights[rows[indexPath.row].id] = cell.frame.height
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isNearBottom { pill.isHidden = true }
        if scrollView.contentOffset.y < -scrollView.contentInset.top + 120, snapshot.hasOlder, !snapshot.isLoadingOlder, scrollView.isTracking || scrollView.isDecelerating {
            let controller = self.controller
            Task { await controller.loadOlder() }
        }
    }

    private func showToast() {
        toast.text = "  " + theme.strings.string("common.copied") + "  "
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIView.animate(withDuration: 0.15, animations: { self.toast.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.0, options: [], animations: { self.toast.alpha = 0 })
        }
    }
}
#endif
