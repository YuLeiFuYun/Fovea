#if canImport(UIKit)
  import FoveaCore
  import ImageCraftCore
  import UIKit

  public enum FoveaImageViewRetentionPolicy: Sendable {
    case clearImmediately
    case retainSuccessfulImageUntilReplacement

    fileprivate var coreRetention: ImageDisplayRetention {
      switch self {
      case .clearImmediately: .clearImmediately
      case .retainSuccessfulImageUntilReplacement: .retainSuccessfulImageUntilReplacement
      }
    }
  }

  public enum FoveaImageViewAccessibility: Sendable {
    case decorative
    case label(String)
  }

  /// 具备请求身份栅栏、渐进图像单调性和可复用取消语义的 UIKit 图片视图。
  @MainActor
  public final class FoveaImageView: UIImageView {
    public var automaticallyCancelsWhenRemovedFromWindow = true

    private let displaySession = ImageDisplaySession()
    private var loadTask: Task<Void, Never>?
    private var placeholderImage: UIImage?
    private var retentionPolicy: FoveaImageViewRetentionPolicy = .clearImmediately

    deinit {
      loadTask?.cancel()
    }

    public func setImage(
      request: ImageRequest,
      loader: any ImageLoading,
      accessibility: FoveaImageViewAccessibility,
      placeholder: UIImage? = nil,
      retention: FoveaImageViewRetentionPolicy = .clearImmediately,
      placeholderDelayNanoseconds: UInt64 = 16_000_000,
      forceReload: Bool = false,
      completion: (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)? = nil
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
