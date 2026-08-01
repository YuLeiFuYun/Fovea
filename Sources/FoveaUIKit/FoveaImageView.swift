#if canImport(UIKit)
    import FoveaCore
    import ImageCraftCore
    import UIKit

    /// 控制 UIKit 图像视图在替换期间是否保留上一次成功图像。
    public enum FoveaImageViewRetentionPolicy: Sendable {
        /// 请求身份变化时清除旧图。
        case clearImmediately
        /// 在替代图交付前保留上一次成功图像。
        case retainSuccessfulImageUntilReplacement

        fileprivate var coreRetention: ImageDisplayRetention {
            switch self {
            case .clearImmediately: .clearImmediately
            case .retainSuccessfulImageUntilReplacement: .retainSuccessfulImageUntilReplacement
            }
        }
    }

    /// 描述已加载 UIKit 图像使用的无障碍语义。
    public enum FoveaImageViewAccessibility: Sendable {
        /// 图像仅用于装饰，因此对无障碍系统隐藏。
        case decorative
        /// 公开调用方提供的无障碍标签。
        case label(String)
    }

    /// 具备请求身份栅栏、可选渐进事件单调性和可复用取消语义的 UIKit 图片视图。
    @MainActor
    public final class FoveaImageView: UIImageView {
        /// 视图移出窗口时是否取消活动图像订阅。
        public var automaticallyCancelsWhenRemovedFromWindow = true

        private let displaySession = ImageDisplaySession()
        private var loadTask: Task<Void, Never>?
        private var placeholderImage: UIImage?
        private var retentionPolicy: FoveaImageViewRetentionPolicy = .clearImmediately

        deinit {
            loadTask?.cancel()
        }

        /// 使用显式无障碍与保留策略，开始或替换经过身份检查的加载。
        public func setImage(
            request: ImageRequest,
            loader: any ImageLoading,
            accessibility: FoveaImageViewAccessibility,
            placeholder: UIImage? = nil,
            retention: FoveaImageViewRetentionPolicy = .clearImmediately,
            placeholderDelayNanoseconds: UInt64 = 16_000_000,
            forceReload: Bool = false,
            completion: (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)? =
                nil
        ) {
            apply(accessibility)
            placeholderImage = placeholder
            retentionPolicy = retention
            if !forceReload, displaySession.isCurrentIdentity(request.displayIdentity) { return }
            loadTask?.cancel()
            displaySession.prepareForIdentityChange(
                to: request.displayIdentity,
                retention: retention.coreRetention
            ) { [weak self] phase in
                self?.apply(phase, completion: completion)
            }

            let session = displaySession
            loadTask = Task { @MainActor [weak self, session] in
                await session.load(
                    request: request,
                    loader: loader,
                    placeholderDelayNanoseconds: placeholderDelayNanoseconds,
                    retention: retention.coreRetention,
                    force: forceReload
                ) { [weak self] phase in
                    self?.apply(phase, completion: completion)
                }
            }
        }

        /// 取消活动订阅，并按需清除当前显示图像。
        public func cancelImageRequest(clearImage: Bool = false) {
            loadTask?.cancel()
            loadTask = nil
            displaySession.invalidate(clear: clearImage) { [weak self] phase in
                self?.apply(phase, completion: nil)
            }
        }

        /// 在复用单元格中调用，确保旧请求与旧像素都不会进入下一次展示身份。
        public func prepareForReuse() {
            cancelImageRequest(clearImage: true)
            placeholderImage = nil
        }

        /// 启用自动取消时，取消窗口外工作。
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if automaticallyCancelsWhenRemovedFromWindow, window == nil {
                cancelImageRequest(clearImage: retentionPolicy == .clearImmediately)
            }
        }

        private func apply(_ accessibility: FoveaImageViewAccessibility) {
            switch accessibility {
            case .decorative:
                isAccessibilityElement = false
                accessibilityLabel = nil
            case .label(let label):
                isAccessibilityElement = true
                accessibilityLabel = label
            }
        }

        private func apply(
            _ phase: ImageDisplaySessionPhase,
            completion: (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)?
        ) {
            switch phase {
            case .empty, .loading:
                image = placeholderImage
            case .preview(let decoded), .success(let decoded):
                image = UIImage(
                    cgImage: decoded.cgImage,
                    scale: max(1, traitCollection.displayScale),
                    orientation: .up
                )
                if case .success = phase { completion?(.success(decoded)) }
            case .failure(let failure):
                if retentionPolicy == .clearImmediately { image = placeholderImage }
                completion?(.failure(failure))
            case .cancelled:
                if retentionPolicy == .clearImmediately { image = placeholderImage }
            }
        }
    }
#endif
