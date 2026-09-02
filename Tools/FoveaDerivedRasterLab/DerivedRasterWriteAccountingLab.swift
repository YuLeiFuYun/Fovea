import AkashicCore
import CryptoKit
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage

/// package 内部用于默认关闭 derived-raster store 的 logical-write accounting。
///
/// 只测量 Akashic checkpoint 阈值以下一组 fresh unique publication 写入的 application payload/metadata 字节；
/// 不声称等价于 physical NAND、filesystem journal、directory、fsync、copy-on-write 或 device-energy 字节。
enum DerivedRasterWriteAccountingLab {
    private struct Options {
        let output: URL
        let blobCount: Int
        let blobBytes: Int

        init(arguments: ArraySlice<String>) throws {
            var values: [String: String] = [:]
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let key = arguments[index]
                let valueIndex = arguments.index(after: index)
                guard key.hasPrefix("--"), valueIndex < arguments.endIndex else {
                    throw WriteAccountingError.invalidArguments
                }
                values[key] = arguments[valueIndex]
                index = arguments.index(after: valueIndex)
            }
            guard let output = values["--output"],
                let blobCount = values["--blob-count"].flatMap(Int.init),
                let blobBytes = values["--blob-bytes"].flatMap(Int.init),
                (1...128).contains(blobCount),
                (1...16 * 1024 * 1024).contains(blobBytes)
            else { throw WriteAccountingError.invalidArguments }
            self.output = URL(fileURLWithPath: output)
            self.blobCount = blobCount
            self.blobBytes = blobBytes
        }
    }

    private enum WriteAccountingError: Error {
        case invalidArguments
        case accountingInvariant
    }

    private struct Report: Codable {
        let schemaVersion: UInt16
        let evidenceClass: String
        let blobCount: Int
        let blobBytes: Int
        let payloadBytesWritten: Int
        let reservedLogicalBytes: Int
        let cumulativeAliasManifestBytesWritten: Int
        let cumulativeAkashicManifestRecordBytesWritten: Int
        let cumulativeWriteBudgetLedgerBytesWritten: Int
        let accountedLogicalBytesWritten: Int
        let unreservedMetadataBytes: Int
        let accountedToReservedRatio: Double
        let accountedToPayloadRatio: Double
        let finalAliasManifestBytes: Int
        let finalAkashicManifestRecordCount: Int
        let finalAkashicManifestRecordBytes: Int
        let finalWriteBudgetLedgerBytes: Int
        let initializationFileBytes: Int
        let checkpointTriggered: Bool
    }

    static func run(arguments: [String]) async throws {
        let options = try Options(arguments: arguments.dropFirst(2))
        let context = try await makeContext(options: options)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let writes = try await publishAll(options: options, context: context)
        let snapshot = try await accountingSnapshot(
            options: options,
            context: context,
            writes: writes
        )
        try validate(options: options, context: context, writes: writes, snapshot: snapshot)
        let report = makeReport(
            options: options, context: context, writes: writes, snapshot: snapshot)
        try write(report, to: options.output)
    }

    private struct Context {
        let root: URL
        let store: AkashicDerivedRasterStore
        let initializationFileBytes: Int
        let format: DerivedRasterFormatIdentity
        let namespace: StorageNamespaceFingerprint
        let aliasManifest: URL
        let budgetLedger: URL
        let payloadDirectory: URL
    }

    private struct WriteTotals {
        let payloadBytes: Int
        let aliasManifestBytes: Int
        let budgetLedgerBytes: Int
    }

    private struct AccountingSnapshot {
        let recordFiles: [URL]
        let recordBytes: Int
        let reservedBytes: Int
        let finalAliasManifestBytes: Int
        let finalBudgetLedgerBytes: Int
        let accountedBytes: Int
        let unreservedBytes: Int
    }

    private static func makeContext(options: Options) async throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fovea-derived-raster-write-accounting-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let limits = DerivedRasterStoreLimits(
            softTotalBytes: 1024 * 1024 * 1024,
            maximumBlobBytes: max(options.blobBytes, 1),
            maximumWriteBytesPerWindow: 1024 * 1024 * 1024 * 1024,
            writeBudgetWindowNanoseconds: 60_000_000_000
        )
        let store = try await AkashicDerivedRasterStore.open(root: root, limits: limits)
        return Context(
            root: root,
            store: store,
            initializationFileBytes: try totalRegularFileBytes(under: root),
            format: DerivedRasterContainer.formatIdentity,
            namespace: StorageNamespaceFingerprint(namespace: "derived-raster-write-accounting"),
            aliasManifest: root.appendingPathComponent(
                "records/derived-raster-records.json", isDirectory: false
            ),
            budgetLedger: root.appendingPathComponent(
                "write-budget/derived-raster-write-budget.json", isDirectory: false
            ),
            payloadDirectory: root.appendingPathComponent("blobs/blobs", isDirectory: true)
        )
    }

    private static func publishAll(options: Options, context: Context) async throws -> WriteTotals {
        var payloadBytesWritten = 0
        var cumulativeAliasManifestBytesWritten = 0
        var cumulativeWriteBudgetLedgerBytesWritten = 0
        for index in 0..<options.blobCount {
            let container = makeContainer(index: index, byteCount: options.blobBytes)
            let record = try makeRecord(index: index, container: container, context: context)
            try await context.store.commit(container: container, record: record)
            payloadBytesWritten += container.count
            cumulativeAliasManifestBytesWritten += try fileByteCount(context.aliasManifest)
            cumulativeWriteBudgetLedgerBytesWritten += try fileByteCount(context.budgetLedger)
        }
        return WriteTotals(
            payloadBytes: payloadBytesWritten,
            aliasManifestBytes: cumulativeAliasManifestBytesWritten,
            budgetLedgerBytes: cumulativeWriteBudgetLedgerBytesWritten
        )
    }

    private static func accountingSnapshot(
        options: Options,
        context: Context,
        writes: WriteTotals
    ) async throws -> AccountingSnapshot {
        let recordFiles = try regularFiles(under: context.payloadDirectory).filter {
            $0.lastPathComponent.hasPrefix(".manifest-entry-")
                && $0.lastPathComponent.hasSuffix(".json")
        }
        let recordBytes = try recordFiles.reduce(into: 0) { total, url in
            total += try fileByteCount(url)
        }
        let budget = try await DerivedRasterWriteBudgetStore.open(
            root: context.root.appendingPathComponent("write-budget", isDirectory: true)
        )
        let reserved = await budget.reservedBytesForTesting()
        let accounted =
            writes.payloadBytes
            + writes.aliasManifestBytes
            + recordBytes
            + writes.budgetLedgerBytes
        return AccountingSnapshot(
            recordFiles: recordFiles,
            recordBytes: recordBytes,
            reservedBytes: reserved,
            finalAliasManifestBytes: try fileByteCount(context.aliasManifest),
            finalBudgetLedgerBytes: try fileByteCount(context.budgetLedger),
            accountedBytes: accounted,
            unreservedBytes: recordBytes + writes.budgetLedgerBytes
        )
    }

    private static func validate(
        options: Options,
        context: Context,
        writes: WriteTotals,
        snapshot: AccountingSnapshot
    ) throws {
        guard snapshot.reservedBytes == writes.payloadBytes + writes.aliasManifestBytes,
            snapshot.recordFiles.count == options.blobCount,
            snapshot.accountedBytes >= snapshot.reservedBytes,
            try payloadFileBytes(under: context.payloadDirectory) == writes.payloadBytes
        else { throw WriteAccountingError.accountingInvariant }
    }

    private static func makeReport(
        options: Options,
        context: Context,
        writes: WriteTotals,
        snapshot: AccountingSnapshot
    ) -> Report {
        Report(
            schemaVersion: 1,
            evidenceClass: "fresh-unique-derived-publication-application-logical-bytes-only",
            blobCount: options.blobCount,
            blobBytes: options.blobBytes,
            payloadBytesWritten: writes.payloadBytes,
            reservedLogicalBytes: snapshot.reservedBytes,
            cumulativeAliasManifestBytesWritten: writes.aliasManifestBytes,
            cumulativeAkashicManifestRecordBytesWritten: snapshot.recordBytes,
            cumulativeWriteBudgetLedgerBytesWritten: writes.budgetLedgerBytes,
            accountedLogicalBytesWritten: snapshot.accountedBytes,
            unreservedMetadataBytes: snapshot.unreservedBytes,
            accountedToReservedRatio: Double(snapshot.accountedBytes)
                / Double(max(snapshot.reservedBytes, 1)),
            accountedToPayloadRatio: Double(snapshot.accountedBytes)
                / Double(max(writes.payloadBytes, 1)),
            finalAliasManifestBytes: snapshot.finalAliasManifestBytes,
            finalAkashicManifestRecordCount: snapshot.recordFiles.count,
            finalAkashicManifestRecordBytes: snapshot.recordBytes,
            finalWriteBudgetLedgerBytes: snapshot.finalBudgetLedgerBytes,
            initializationFileBytes: context.initializationFileBytes,
            checkpointTriggered: snapshot.recordFiles.count != options.blobCount
        )
    }

    private static func makeContainer(index: Int, byteCount: Int) -> Data {
        var container = Data(repeating: UInt8(index & 0xff), count: byteCount)
        guard !container.isEmpty else { return container }
        withUnsafeBytes(of: UInt64(index).littleEndian) { marker in
            container.replaceSubrange(0..<min(marker.count, container.count), with: marker)
        }
        return container
    }

    private static func makeRecord(
        index: Int,
        container: Data,
        context: Context
    ) throws -> DerivedRasterRecord {
        let suffix = String(index)
        return try DerivedRasterRecord(
            artifactKeyDigest: sha256(Data("artifact:\(suffix)".utf8)),
            baseKeyDigest: sha256(Data("base:\(suffix)".utf8)),
            variantKeyDigest: sha256(Data("variant:\(suffix)".utf8)),
            namespaceFingerprint: context.namespace,
            namespaceGeneration: 1,
            containerContentID: BlobDigest.sha256(of: container).canonicalString,
            containerByteCount: container.count,
            formatIdentifier: context.format.identifier,
            formatSemanticVersion: context.format.semanticVersion,
            pixelLayoutFingerprint: context.format.pixelLayoutFingerprint,
            pixelDigestHex: sha256(Data("pixel:\(suffix)".utf8)),
            pixelWidth: 1,
            pixelHeight: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000 + Double(index))
        )
    }

    private static func write(_ report: Report, to output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileByteCount(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw WriteAccountingError.accountingInvariant
        }
        return size
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else { throw WriteAccountingError.accountingInvariant }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }

    private static func totalRegularFileBytes(under root: URL) throws -> Int {
        try regularFiles(under: root).reduce(into: 0) { total, url in
            total += try fileByteCount(url)
        }
    }

    private static func payloadFileBytes(under root: URL) throws -> Int {
        try regularFiles(under: root).filter { url in
            let name = url.lastPathComponent
            return UUID(uuidString: name) != nil
        }.reduce(into: 0) { total, url in
            total += try fileByteCount(url)
        }
    }
}
