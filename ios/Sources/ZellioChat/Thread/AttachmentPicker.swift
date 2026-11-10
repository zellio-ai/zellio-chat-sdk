#if canImport(SwiftUI) && canImport(UIKit)
import AVFoundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ZellioChatCore

struct PickedFile {
    var data: Data
    var fileName: String
    var mimeType: String
    var thumbnail: UIImage?
}

enum ImagePrep {
    static let maxBytes = 10 * 1024 * 1024
    /// A photo this large can still be scaled down to fit `maxBytes`. Anything else is stopped at `maxBytes`.
    static let maxShrinkableBytes = 40 * 1024 * 1024

    /// Decodes at most `maxPixelEdge` on the long edge, upright, without decoding the full image first.
    static func decode(_ data: Data, maxPixelEdge: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, maxPixelEdge: maxPixelEdge)
    }

    static func decode(_ source: CGImageSource, maxPixelEdge: Int) -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    /// A very large photo file: scaled down and saved as JPEG. Returns nil if it cannot be made small enough.
    static func shrinkFile(_ url: URL) -> (data: Data, image: UIImage)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = decode(source, maxPixelEdge: 2048),
              let data = jpeg(image) else { return nil }
        return (data, image)
    }

    /// Scales to at most 2048 points on the long edge, then JPEG. Returns nil if it cannot be made small enough.
    static func jpeg(_ image: UIImage) -> Data? {
        var source = image
        let longEdge = Swift.max(image.size.width, image.size.height)
        if longEdge > 2048 {
            let scale = 2048 / longEdge
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            source = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        for quality in [0.85, 0.7, 0.5] as [CGFloat] {
            if let data = source.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }

    static func thumbnail(_ image: UIImage) -> UIImage {
        let side: CGFloat = 112
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scale = Swift.max(side / Swift.max(image.size.width, 1), side / Swift.max(image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }

    static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "pdf": return "application/pdf"
        default: return nil
        }
    }
}

/// Camera, photo library and files. The photo library uses the system picker, so no photo permission is needed.
/// The camera asks for permission only when the customer taps it.
final class AttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    weak var presenter: UIViewController?
    var theme: ChatTheme = .fallback
    var onPicked: ((PickedFile) -> Void)?
    var onProblem: ((ChatError) -> Void)?

    func showSheet(sourceView: UIView) {
        guard let presenter = presenter else { return }
        let strings = theme.strings
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: strings.string("composer.camera"), style: .default) { [weak self] _ in self?.openCamera() })
        }
        sheet.addAction(UIAlertAction(title: strings.string("composer.photos"), style: .default) { [weak self] _ in self?.openPhotos() })
        sheet.addAction(UIAlertAction(title: strings.string("composer.files"), style: .default) { [weak self] _ in self?.openFiles() })
        sheet.addAction(UIAlertAction(title: strings.string("attachment.close"), style: .cancel))
        sheet.overrideUserInterfaceStyle = theme.palette.isDark ? .dark : .light
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        presenter.present(sheet, animated: true)
    }

    // MARK: Camera

    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.presentCamera() } else { self?.showCameraDenied() }
                }
            }
        default:
            showCameraDenied()
        }
    }

    private func presentCamera() {
        guard let presenter = presenter else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func showCameraDenied() {
        guard let presenter = presenter else { return }
        let strings = theme.strings
        let alert = UIAlertController(title: nil, message: strings.string("composer.cameraDenied"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.string("composer.openSettings"), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        alert.addAction(UIAlertAction(title: strings.string("attachment.close"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        deliver(image: image, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }

    // MARK: Photos

    private func openPhotos() {
        guard let presenter = presenter else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            let image = object as? UIImage
            DispatchQueue.main.async {
                guard let image = image else { self?.onProblem?(.network); return }
                self?.deliver(image: image, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
            }
        }
    }

    // MARK: Files

    private func openFiles() {
        guard let presenter = presenter else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf, UTType.image], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension
        guard let mime = ImagePrep.mimeType(forExtension: ext) else {
            onProblem?(.fileTypeDenied)
            return
        }
        // Read off the main thread, and never read a file into memory before its size is known.
        // 10 MB is the most the server takes.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.readPicked(url: url, mime: mime)
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let file): self.onPicked?(file)
                case .failure(let problem): self.onProblem?(problem)
                }
            }
        }
    }

    private static func readPicked(url: URL, mime: String) -> Result<PickedFile, ChatError> {
        let name = url.lastPathComponent
        let isImage = mime.hasPrefix("image/")
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .failure(.network) }
        if size > (isImage ? ImagePrep.maxShrinkableBytes : ImagePrep.maxBytes) { return .failure(.fileTooLarge) }
        if size > ImagePrep.maxBytes {
            guard let shrunk = ImagePrep.shrinkFile(url) else { return .failure(.fileTooLarge) }
            let jpegName = (name as NSString).deletingPathExtension + ".jpg"
            return .success(PickedFile(data: shrunk.data, fileName: jpegName, mimeType: "image/jpeg", thumbnail: ImagePrep.thumbnail(shrunk.image)))
        }
        guard let data = try? Data(contentsOf: url), data.count <= ImagePrep.maxBytes else { return .failure(.network) }
        let thumb = isImage ? ImagePrep.decode(data, maxPixelEdge: 240).map { ImagePrep.thumbnail($0) } : nil
        return .success(PickedFile(data: data, fileName: name, mimeType: mime, thumbnail: thumb))
    }

    private func deliver(image: UIImage, name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = ImagePrep.jpeg(image)
            let thumb = ImagePrep.thumbnail(image)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data else { self.onProblem?(.fileTooLarge); return }
                self.onPicked?(PickedFile(data: data, fileName: name, mimeType: "image/jpeg", thumbnail: thumb))
            }
        }
    }
}

/// Full screen image with pinch zoom. Swipe down to close.
final class ImageViewerController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let closeLabel: String
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private var panStart: CGPoint = .zero

    init(image: UIImage, closeLabel: String) {
        self.image = image
        self.closeLabel = closeLabel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { nil }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.94)
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = closeLabel
        scroll.addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = closeLabel
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44), closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.zoomScale == 1 {
            imageView.frame = scroll.bounds
            scroll.contentSize = scroll.bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard scroll.zoomScale <= 1.01 else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            let progress = Swift.min(1, Swift.max(0, translation.y / 300))
            scroll.transform = CGAffineTransform(translationX: 0, y: Swift.max(0, translation.y))
            view.backgroundColor = UIColor.black.withAlphaComponent(0.94 * (1 - progress))
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 120 || velocity > 900 {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.2) {
                    self.scroll.transform = .identity
                    self.view.backgroundColor = UIColor.black.withAlphaComponent(0.94)
                }
            }
        default:
            break
        }
    }
}

extension ImageViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }
}
#endif
