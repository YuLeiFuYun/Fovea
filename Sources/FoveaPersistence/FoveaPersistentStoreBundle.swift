import AkashicCore
import FoveaHTTP
import FoveaStorage

/// package 内部持久化 provider 身份；公共高级契约由 FoveaAdvancedSystem 拥有。
package struct FoveaPersistentStoreProviderIdentity: Hashable, Sendable {
    package static let currentContractVersion: UInt16 = 1

    package let identifier: String
    package let implementationVersion: UInt32
    package let contractVersion: UInt16
    package let compatibilityFingerprint: String

    package init(
        identifier: String,
        implementationVersion: UInt32,
        contractVersion: UInt16 = Self.currentContractVersion,
        compatibilityFingerprint: String
    ) throws {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCompatibility = compatibilityFingerprint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !normalizedIdentifier.isEmpty,
            normalizedIdentifier.utf8.count <= 256,
            normalizedIdentifier.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }
            ),
            implementationVersion > 0,
            contractVersion == Self.currentContractVersion,
            !normalizedCompatibility.isEmpty,
            normalizedCompatibility.utf8.count <= 1_024,
            normalizedCompatibility.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7f
            })
        else {
            throw AkashicError.invalidIdentity
        }
        self.identifier = normalizedIdentifier
        self.implementationVersion = implementationVersion
        self.contractVersion = contractVersion
        self.compatibilityFingerprint = normalizedCompatibility
    }

    package init(
        validatedIdentifier identifier: String,
        implementationVersion: UInt32,
        compatibilityFingerprint: String
    ) {
        self.identifier = identifier
        self.implementationVersion = implementationVersion
        self.contractVersion = Self.currentContractVersion
        self.compatibilityFingerprint = compatibilityFingerprint
    }

    package var cacheFingerprint: String {
        "\(identifier)#impl=\(implementationVersion)#contract=\(contractVersion)#compat=\(compatibilityFingerprint)"
    }
}

/// package 内部不可变 bundle；系统组合根只接受该完整值，不接受三个裸 store 参数。
package struct FoveaPersistentStoreBundle: Sendable {
    package let providerIdentity: FoveaPersistentStoreProviderIdentity
    package let generation: StoreGenerationDescriptor
    package let encoded: any OriginalEncodedMaintaining & AnyObject
    package let records: any RepresentationRecordMaintaining
    package let namespaceGenerations: any NamespaceGenerationPersisting
    private let lifetimeAnchor: any Sendable

    package init(
        providerIdentity: FoveaPersistentStoreProviderIdentity,
        generation: StoreGenerationDescriptor,
        encoded: any OriginalEncodedMaintaining & AnyObject,
        records: any RepresentationRecordMaintaining,
        namespaceGenerations: any NamespaceGenerationPersisting,
        lifetimeAnchor: any Sendable
    ) throws {
        guard generation.compatibilityFingerprint == providerIdentity.compatibilityFingerprint
        else {
            throw AkashicError.invalidIdentity
        }
        self.providerIdentity = providerIdentity
        self.generation = generation
        self.encoded = encoded
        self.records = records
        self.namespaceGenerations = namespaceGenerations
        self.lifetimeAnchor = lifetimeAnchor
    }
}
