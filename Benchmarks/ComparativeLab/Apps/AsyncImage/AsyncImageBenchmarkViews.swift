import SwiftUI

#if FOVEA_SWIFTUI_SURFACE
    import FoveaCore
    @_spi(Benchmarking) import FoveaSwiftUI
    import ImageCraftCore
#endif

struct AsyncImageBenchmarkRootView: View {
    let workloadID: String
    @ObservedObject var model: AsyncImageBenchmarkModel

    var body: some View {
        Group {
            if model.isArmed {
                switch workloadID {
                case "W1-SCROLL-V1":
                    AsyncImageFeedView(model: model)
                case "W2-HERO-V1":
                    AsyncImageHeroView(model: model)
                default:
                    AsyncImageIdentityChurnView(model: model)
                }
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
    }
}

private struct InstrumentedAsyncImage: View {
    let url: URL
    let token: String
    let generation: Int
    let contentMode: ContentMode
    let model: AsyncImageBenchmarkModel

    var body: some View {
        Group {
            #if FOVEA_SWIFTUI_SURFACE
                FoveaResponsiveImage(
                    loader: model.foveaLoader,
                    accessibility: .decorative,
                    contentMode: contentMode == .fit ? .fit : .fill,
                    geometryIsStable: true,
                    loadingPolicy: FoveaImageLoadingPolicy(
                        placeholderDelayNanoseconds: 0,
                        retention: .clearImmediately
                    ),
                    transitionPolicy: FoveaImageTransitionPolicy(opacityDuration: 0),
                    onPreviewAppear: {
                        Task {
                            await model.recorder.succeeded(
                                token: token,
                                generation: generation
                            )
                        }
                    },
                    onSuccessAppear: {
                        Task {
                            await model.recorder.finalized(
                                token: token,
                                generation: generation
                            )
                        }
                    }
                ) { target in
                    try model.foveaRequest(url: url, target: target)
                } placeholder: {
                    ProgressView()
                } failure: { _ in
                    Image(systemName: "exclamationmark.triangle")
                        .onAppear { Task { await model.recorder.failed(token: token) } }
                }
            #else
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .onAppear {
                                Task {
                                    await model.recorder.finalized(
                                        token: token,
                                        generation: generation
                                    )
                                }
                            }
                    case .failure:
                        Image(systemName: "exclamationmark.triangle")
                            .onAppear { Task { await model.recorder.failed(token: token) } }
                    @unknown default:
                        EmptyView()
                    }
                }
            #endif
        }
        .onAppear { Task { await model.recorder.appeared(token: token) } }
        .onDisappear { Task { await model.recorder.disappeared(token: token) } }
    }
}

private struct AsyncImageFeedView: View {
    @ObservedObject var model: AsyncImageBenchmarkModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<1_000, id: \.self) { index in
                        InstrumentedAsyncImage(
                            url: model.assetURL(logicalIndex: index),
                            token: "feed-\(index)-g\(model.feedGeneration)",
                            generation: model.feedGeneration,
                            contentMode: .fill,
                            model: model
                        )
                        .frame(height: 180)
                        .clipped()
                        .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.feedTarget) { target in
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }
}

private struct AsyncImageHeroView: View {
    @ObservedObject var model: AsyncImageBenchmarkModel

    var body: some View {
        InstrumentedAsyncImage(
            url: model.heroURL(),
            token: "hero-\(model.heroName)-g\(model.heroGeneration)",
            generation: model.heroGeneration,
            contentMode: .fit,
            model: model
        )
        .id(model.heroGeneration)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct AsyncImageIdentityChurnView: View {
    @ObservedObject var model: AsyncImageBenchmarkModel

    var body: some View {
        InstrumentedAsyncImage(
            url: model.identityURL(),
            token: "identity-g\(model.identityGeneration)",
            generation: model.identityGeneration,
            contentMode: .fill,
            model: model
        )
        .id(model.identityGeneration)
        .frame(width: 320, height: 240)
        .clipped()
    }
}
