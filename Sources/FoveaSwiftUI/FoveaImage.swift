import FoveaCore
import ImageCraftCore
import SwiftUI

public enum FoveaImagePhase {
  case empty
  case loading
  case success(DecodedImage)
  case failure(any Error)
  case cancelled
}

public enum FoveaImageAccessibility {
  case decorative
  case label(Text)
}

@MainActor
public final class FoveaImageModel: ObservableObject {
  @Published public private(set) var phase: FoveaImagePhase = .empty
  private var token = UUID()

  public init() {}

  public func load(request: ImageRequest, pipeline: FoveaPipeline) async {
    let current = UUID()
    token = current
    phase = .loading
    do {
      let image = try await pipeline.image(for: request)
      guard token == current else { return }
      phase = .success(image)
    } catch is CancellationError {
      guard token == current else { return }
      phase = .cancelled
    } catch {
      guard token == current else { return }
      phase = .failure(error)
    }
  }

  public func invalidate() {
    token = UUID()
    phase = .empty
  }
}

public struct FoveaImage<Placeholder: View, Failure: View>: View {
  private let request: ImageRequest
  private let pipeline: FoveaPipeline
  private let accessibility: FoveaImageAccessibility
  private let placeholder: () -> Placeholder
  private let failure: (any Error) -> Failure
  @StateObject private var model = FoveaImageModel()

  public init(
    request: ImageRequest,
    pipeline: FoveaPipeline,
    accessibility: FoveaImageAccessibility,
    @ViewBuilder placeholder: @escaping () -> Placeholder,
    @ViewBuilder failure: @escaping (any Error) -> Failure
  ) {
    self.request = request
    self.pipeline = pipeline
    self.accessibility = accessibility
    self.placeholder = placeholder
    self.failure = failure
  }

  public var body: some View {
    content
      .task(id: requestIdentity) {
        await model.load(request: request, pipeline: pipeline)
      }
      .onDisappear { model.invalidate() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .empty, .loading, .cancelled:
      placeholder()
    case .success(let decoded):
      renderedImage(decoded)
    case .failure(let error):
      failure(error)
    }
  }

  @ViewBuilder
  private func renderedImage(_ decoded: DecodedImage) -> some View {
    switch accessibility {
    case .decorative:
      Image(decorative: decoded.cgImage, scale: 1).resizable()
    case .label(let label):
      Image(decoded.cgImage, scale: 1, label: label).resizable()
    }
  }

  private var requestIdentity: String { request.displayIdentity }
}

extension FoveaImage where Placeholder == ProgressView<EmptyView, EmptyView>, Failure == EmptyView {
  public init(
    request: ImageRequest,
    pipeline: FoveaPipeline,
    accessibility: FoveaImageAccessibility
  ) {
    self.init(request: request, pipeline: pipeline, accessibility: accessibility) {
      ProgressView()
    } failure: { _ in
      EmptyView()
    }
  }
}
