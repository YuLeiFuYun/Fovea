#if canImport(AppKit)
  import AppKit
  import FoveaCore
  import ImageCraftCore

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

  /// 具备请求身份栅栏、渐进图像单调性和窗口移除取消语义的 AppKit 图片视图。
  @MainActor
  public final class FoveaImageView: NSImageView {
    public var automaticallyCancelsWhenRemovedFromWindow = true

    private let displaySession = ImageDisplaySession()
    private var loadTask: Task<Void, Never>?
    private var placeholderImage: NSImage?
    private var retentionPolicy: FoveaImageViewRetentionPolicy = .clearImmediately

    deinit {
      loadTask?.cancel()
    }

    public func setImage(
      request: ImageRequest,
      loader: any ImageLoading,
      accessibility: FoveaImageViewAccessibility,
      placeholder: NSImage? = nil,
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

    /// 在复用视图中调用，确保旧请求与旧像素都不会进入下一次展示身份。
    public override func prepareForReuse() {
      super.prepareForReuse()
      cancelImageRequest(clearImage: true)
      placeholderImage = nil
    }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if automaticallyCancelsWhenRemovedFromWindow, window == nil {
        cancelImageRequest(clearImage: retentionPolicy == .clearImmediately)
      }
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      apply(displaySession.phase, completion: nil)
    }

    private func apply(_ accessibility: FoveaImageViewAccessibility) {
      switch accessibility {
      case .decorative:
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
      case .label(let label):
        setAccessibilityElement(true)
        setAccessibilityLabel(label)
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
        let scale = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        image = NSImage(
          cgImage: decoded.cgImage,
          size: NSSize(
            width: CGFloat(decoded.pixelWidth) / scale,
            height: CGFloat(decoded.pixelHeight) / scale
          )
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
