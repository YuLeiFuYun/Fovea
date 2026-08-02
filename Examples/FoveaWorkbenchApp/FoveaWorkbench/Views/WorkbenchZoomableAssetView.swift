import SwiftUI

/// 用于商品详情和照片查看器的可缩放真实图片检查页。
struct WorkbenchZoomableAssetView: View {
    let asset: WorkbenchRemoteAsset

    @State private var scale: CGFloat = 1
    @State private var accumulatedScale: CGFloat = 1
    @State private var revision = UUID()

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    WorkbenchRemoteAssetImage(
                        asset: asset,
                        revision: revision,
                        contentMode: .fit,
                        accessibilityIdentifier: "zoom.image"
                    )
                    .frame(
                        width: proxy.size.width * max(1, scale),
                        height: proxy.size.height * max(1, scale)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(5, max(1, accumulatedScale * value))
                            }
                            .onEnded { _ in
                                accumulatedScale = scale
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            accumulatedScale = scale
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Label("双击或捏合缩放", systemImage: "hand.pinch")
                Spacer()
                Text(String(format: "%.1f×", scale)).monospacedDigit()
                Button("复位") {
                    scale = 1
                    accumulatedScale = 1
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Color.black.opacity(0.96).ignoresSafeArea())
        .foregroundColor(.white)
        .navigationTitle(asset.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
