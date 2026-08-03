import FoveaAdvancedSystem
import QualifiedStoreProviderFixture

enum ProviderUnderTest {
    static func make() throws -> any FoveaPersistentStoreBundleProviding {
        try QualifiedStoreProviderFixture()
    }
}
