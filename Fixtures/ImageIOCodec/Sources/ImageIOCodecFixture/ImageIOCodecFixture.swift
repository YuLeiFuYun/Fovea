import ImageCraftCore
import ImageCraftImageIO

/// ImageIO 参考后端的跨仓 conformance fixture。
public enum ImageIOCodecFixture {
    /// 返回一个新的、无共享可变配置的参考 codec 实例。
    public static func make() -> any ImageCodec {
        ImageIOImageDecoder()
    }
}
