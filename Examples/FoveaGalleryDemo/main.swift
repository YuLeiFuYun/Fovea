#if os(macOS)
  import FoveaCore
  import FoveaHTTP
  import FoveaSwiftUI
  import FoveaSystem
  import ImageCraftCore
  import SwiftUI

  private let demoAppID = "dev.fovea.gallery-demo"
  private let demoNamespace = SecurityNamespaceID.publicNamespace(appID: demoAppID)

  @main
  struct FoveaGalleryDemoApp: App {
    var body: some Scene {
      WindowGroup("Fovea Gallery Demo") {
        GalleryRootView()
          .frame(minWidth: 860, minHeight: 620)
      }
    }
  }

  @MainActor
  private final class GalleryModel: ObservableObject {
    enum NetworkMode: String, CaseIterable, Identifiable {
      case interactive
      case conservative

      var id: String { rawValue }
      var title: String {
        switch self {
        case .interactive: "交互"
        case .conservative: "节流"
        }
      }
      var policy: ImageRequestNetworkPolicy {
        switch self {
        case .interactive: .interactive
        case .conservative: .conservative
        }
      }
    }

    @Published private(set) var pipeline: FoveaPipeline?
    @Published private(set) var startupFailure: String?
    @Published var networkMode: NetworkMode = .interactive
    @Published var requestGeneration: UInt64 = 0

    private var isStarting = false

    func start() async {
      guard pipeline == nil, !isStarting else { return }
      isStarting = true
      defer { isStarting = false }
      do {
        let root = try FileManager.default.url(
          for: .cachesDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        ).appendingPathComponent("FoveaGalleryDemo", isDirectory: true)
        let diagnostics = BoundedDiagnosticsSink(capacity: 2_048)
        let system = try await FoveaSystemPipeline.open(
          cacheRoot: root,
          configuration: PipelineConfiguration(
            memoryCostLimit: 96 * 1024 * 1024,
            maximumTransportBytes: 16 * 1024 * 1024,
            maximumConcurrentFetches: 4,
            maximumConcurrentDecodes: 2,
            maximumDecodeWorkingSetBytes: 160 * 1024 * 1024
          ),
          diagnostics: diagnostics,
          profileAccessPolicy: .allowOnly([
            ProfileAccessScope(namespace: demoNamespace, authorizationContext: .public)
          ]),
          transportPolicy: URLSessionTransportPolicy(
            waitsForConnectivity: true,
            requestTimeoutSeconds: 20,
            resourceTimeoutSeconds: 60,
            maximumConnectionsPerHost: 4
          )
        )
        pipeline = system.pipeline
        startupFailure = nil
      } catch {
        startupFailure = String(describing: error)
      }
    }

    func reload() {
      requestGeneration &+= 1
    }

    func purgeMemory() async {
      _ = await pipeline?.purgeMemoryCache()
      reload()
    }

    func revokePublicNamespace() async {
      do {
        try await pipeline?.revoke(namespace: demoNamespace)
        reload()
      } catch {
        startupFailure = String(describing: error)
      }
    }
  }

  private struct DemoImage: Identifiable {
    let id: String
    let title: String
    let url: URL
    let contentMode: ImageContentMode

    static let gallery: [DemoImage] = [
      DemoImage(
        id: "picsum-landscape",
        title: "响应式远景",
        url: URL(string: "https://picsum.photos/seed/fovea-gallery-landscape/1200/800")!,
        contentMode: .fill
      ),
      DemoImage(
        id: "picsum-portrait",
        title: "响应式人像比例",
        url: URL(string: "https://picsum.photos/seed/fovea-gallery-portrait/720/1080")!,
        contentMode: .fill
      ),
      DemoImage(
        id: "httpbin-png",
        title: "PNG 与透明度路径",
        url: URL(string: "https://httpbin.org/image/png")!,
        contentMode: .fit
      ),
      DemoImage(
        id: "httpbin-jpeg",
        title: "JPEG 与颜色路径",
        url: URL(string: "https://httpbin.org/image/jpeg")!,
        contentMode: .fit
      ),
      DemoImage(
        id: "intentional-404",
        title: "结构化失败与重试",
        url: URL(string: "https://httpbin.org/status/404")!,
        contentMode: .fit
      ),
    ]
  }

  private struct GalleryRootView: View {
    @StateObject private var model = GalleryModel()

    private let columns = [
      GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)
    ]

    var body: some View {
      NavigationView {
        Group {
          if let pipeline = model.pipeline {
            ScrollView {
              LazyVGrid(columns: columns, spacing: 16) {
                ForEach(DemoImage.gallery) { item in
                  GalleryCard(
                    item: item,
                    pipeline: pipeline,
                    networkPolicy: model.networkMode.policy,
                    generation: model.requestGeneration
                  )
                }
              }
              .padding(20)
            }
          } else if let failure = model.startupFailure {
            VStack(spacing: 12) {
              Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
              Text("Pipeline 启动失败").font(.headline)
              Text(failure)
                .font(.caption.monospaced())
                .multilineTextAlignment(.center)
            }
            .padding(24)
          } else {
            ProgressView("正在打开安全组合根…")
          }
        }
        .navigationTitle("Fovea Gallery")
        .toolbar {
          ToolbarItemGroup {
            Picker("网络", selection: $model.networkMode) {
              ForEach(GalleryModel.NetworkMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
            .pickerStyle(.segmented)
            Button("重载") { model.reload() }
            Button("清内存") { Task { await model.purgeMemory() } }
            Button("撤销 namespace") { Task { await model.revokePublicNamespace() } }
          }
        }
      }
      .task { await model.start() }
    }
  }

  private struct GalleryCard: View {
    let item: DemoImage
    let pipeline: FoveaPipeline
    let networkPolicy: ImageRequestNetworkPolicy
    let generation: UInt64

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        FoveaResponsiveImage(
          loader: pipeline,
          accessibility: .label(Text(item.title)),
          contentMode: item.contentMode,
          geometryIsStable: true
        ) { target in
          try ImageRequest.publicImage(
            url: item.url,
            logicalSource: LogicalSourceID("demo:\(item.id):\(generation)"),
            resolvedTarget: target,
            appID: demoAppID,
            priority: .userInitiated,
            networkPolicy: networkPolicy
          )
        } placeholder: {
          ZStack {
            Rectangle().fill(.quaternary)
            ProgressView()
          }
        } failure: { context in
          VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(context.failure.reasonCode)
              .font(.caption.monospaced())
              .multilineTextAlignment(.center)
            if context.recoveryAction == .retry {
              Button("重试") { context.retry() }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        Text(item.title).font(.headline)
        Text(item.url.host ?? "")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .background(.background)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .shadow(radius: 2, y: 1)
    }
  }
#else
  import Foundation

  @main
  enum FoveaGalleryDemoUnsupported {
    static func main() {
      print("FoveaGalleryDemo 当前仅作为 macOS SwiftUI 示例运行。")
    }
  }
#endif
