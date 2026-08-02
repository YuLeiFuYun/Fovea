import Dispatch
import Foundation

struct WorkbenchStoragePruneResult: Equatable, Sendable {
    let removedProfileCount: Int
    let failedOperationCount: Int
}

/// 把目录枚举、mtime 读取和递归删除隔离到专用串行队列，避免阻塞主线程或 Swift 协作式执行器。
/// 返回值只包含计数，不把缓存路径或底层错误文本带入用户可见状态。
enum WorkbenchStorageMaintenance {
    private static let queue = DispatchQueue(
        label: "dev.fovea.workbench.storage-maintenance",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    static func pruneObsoleteStorageProfiles(
        cacheRoot: URL,
        preserving identifiers: Set<String>,
        maximumRetained: Int = 4
    ) async -> WorkbenchStoragePruneResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: pruneSynchronously(
                        cacheRoot: cacheRoot,
                        preserving: identifiers,
                        maximumRetained: maximumRetained
                    )
                )
            }
        }
    }

    private static func pruneSynchronously(
        cacheRoot: URL,
        preserving identifiers: Set<String>,
        maximumRetained: Int
    ) -> WorkbenchStoragePruneResult {
        var removed = 0
        var failures = 0
        for role in WorkbenchPipelineRole.allCases {
            let result = pruneRole(
                root: cacheRoot.appendingPathComponent(role.rawValue, isDirectory: true),
                preserving: identifiers,
                maximumRetained: max(0, maximumRetained)
            )
            removed += result.removedProfileCount
            failures += result.failedOperationCount
        }
        return WorkbenchStoragePruneResult(
            removedProfileCount: removed,
            failedOperationCount: failures
        )
    }

    private static func pruneRole(
        root: URL,
        preserving identifiers: Set<String>,
        maximumRetained: Int
    ) -> WorkbenchStoragePruneResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return WorkbenchStoragePruneResult(
                removedProfileCount: 0,
                failedOperationCount: 0
            )
        }

        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            return WorkbenchStoragePruneResult(
                removedProfileCount: 0,
                failedOperationCount: 1
            )
        }

        var metadataFailures = 0
        let profiles = candidates.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix("store-v2-") else { return nil }
            do {
                let values = try url.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            } catch {
                metadataFailures += 1
                return nil
            }
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.lastPathComponent < rhs.0.lastPathComponent
        }

        let retained = Set(
            profiles.prefix(maximumRetained).map { $0.0.lastPathComponent }
        ).union(identifiers)
        var removed = 0
        var removalFailures = 0
        for (url, _) in profiles where !retained.contains(url.lastPathComponent) {
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                removalFailures += 1
            }
        }
        return WorkbenchStoragePruneResult(
            removedProfileCount: removed,
            failedOperationCount: metadataFailures + removalFailures
        )
    }
}
