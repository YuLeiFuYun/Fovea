import ImageCraftCore
import ImageIOCodecFixture

enum CodecUnderTest {
    static func make() -> any ImageCodec {
        ImageIOCodecFixture.make()
    }
}
