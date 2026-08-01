import AkashicCore
import Foundation
import FoveaStorage

package actor NamespaceRegistry {
    private struct State: Sendable {
        var generation: NamespaceGeneration
        var isExhausted: Bool
        var activeRevocations: Int
    }

    private struct PendingAdvance: Sendable {
        let token: UUID
        let generation: NamespaceGeneration
        let task: Task<NamespaceGeneration, any Error>
    }

    private let maximumTrackedNamespaces: Int
    private let persistence: (any NamespaceGenerationPersisting)?
    private var states: [StorageNamespaceFingerprint: State]
    private var pendingAdvances: [StorageNamespaceFingerprint: PendingAdvance] = [:]

    package static func open(
        maximumTrackedNamespaces: Int,
        persistence: any NamespaceGenerationPersisting
    ) async throws -> NamespaceRegistry {
        do {
            let persisted = try await persistence.load(maximumCount: maximumTrackedNamespaces)
            return NamespaceRegistry(
                maximumTrackedNamespaces: maximumTrackedNamespaces,
                persistedGenerations: persisted.mapValues(NamespaceGeneration.init),
                persistence: persistence
            )
        } catch {
            throw PipelineFailure.namespaceGenerationPersistenceFailed
        }
    }

    package init(
        maximumTrackedNamespaces: Int = 4_096,
        initialGenerations: [SecurityNamespaceID: NamespaceGeneration] = [:]
    ) {
        let persisted = Dictionary(
            uniqueKeysWithValues: initialGenerations.map {
                (StorageNamespaceFingerprint(namespace: $0.key.value), $0.value)
            }
        )
        self.maximumTrackedNamespaces = max(
            persisted.count,
            min(1_000_000, max(1, maximumTrackedNamespaces))
        )
        self.persistence = nil
        self.states = Self.makeStates(from: persisted, exhaustMaximum: false)
    }

    package init(
        maximumTrackedNamespaces: Int,
        persistedGenerations: [StorageNamespaceFingerprint: NamespaceGeneration],
        persistence: any NamespaceGenerationPersisting
    ) {
        self.maximumTrackedNamespaces = max(
            persistedGenerations.count,
            min(1_000_000, max(1, maximumTrackedNamespaces))
        )
        self.persistence = persistence
        self.states = Self.makeStates(from: persistedGenerations, exhaustMaximum: true)
    }

    package func generation(
        for namespace: SecurityNamespaceID
    ) throws -> NamespaceGeneration {
        let fingerprint = Self.fingerprint(for: namespace)
        if let existing = states[fingerprint] {
            guard !existing.isExhausted, existing.activeRevocations == 0 else {
                throw PipelineFailure.namespaceRevoked
            }
            return existing.generation
        }
        try admit(fingerprint)
        return NamespaceGeneration(0)
    }

    /// 为不需要持有清理屏障的调用方原子推进 namespace generation。
    /// 管线撤销应使用 `beginRevocation(_:)` 与 `finishRevocation(_:generation:)`，
    /// 以保证新工作不会与持久化清理重叠。
    @discardableResult
    package func revoke(
        _ namespace: SecurityNamespaceID
    ) async throws -> NamespaceGeneration {
        let generation = try await beginRevocation(namespace)
        finishRevocation(namespace, generation: generation)
        return generation
    }

    /// 返回前先持久推进 generation，并在所有并发撤销 lease 完成清理前保持 namespace 不可用。
    /// 并发调用共享一次持久推进；即使发布后、清理前崩溃，重启后旧 generation 也不会复活。
    @discardableResult
    package func beginRevocation(
        _ namespace: SecurityNamespaceID
    ) async throws -> NamespaceGeneration {
        let fingerprint = Self.fingerprint(for: namespace)
        if states[fingerprint] == nil { try admit(fingerprint, stage: .revocation) }
        guard let state = states[fingerprint] else {
            throw PipelineFailure.internalFailure(stage: .revocation)
        }
        if state.isExhausted { return state.generation }
        if state.activeRevocations > 0 {
            return try acquireConcurrentCleanupLease(for: fingerprint, state: state)
        }
        if let pending = pendingAdvances[fingerprint] {
            return try await joinPendingAdvance(pending, for: fingerprint)
        }
        return try await startAdvance(for: fingerprint, state: state)
    }

    private func acquireConcurrentCleanupLease(
        for fingerprint: StorageNamespaceFingerprint,
        state: State
    ) throws -> NamespaceGeneration {
        guard state.activeRevocations < Int.max else {
            throw PipelineFailure.resourceLimit(
                stage: .revocation,
                reasonCode: "namespace-revocation-capacity-exceeded"
            )
        }
        var updated = state
        updated.activeRevocations += 1
        states[fingerprint] = updated
        return updated.generation
    }

    private func startAdvance(
        for fingerprint: StorageNamespaceFingerprint,
        state: State
    ) async throws -> NamespaceGeneration {
        guard state.generation.value < UInt64.max else {
            var exhausted = state
            exhausted.isExhausted = true
            states[fingerprint] = exhausted
            return exhausted.generation
        }

        let next = NamespaceGeneration(state.generation.value + 1)
        let token = UUID()
        let persistence = self.persistence
        let task = Task<NamespaceGeneration, any Error> {
            if let persistence {
                try await persistence.persist(next.value, for: fingerprint)
            }
            return next
        }
        let pending = PendingAdvance(token: token, generation: next, task: task)
        pendingAdvances[fingerprint] = pending
        return try await joinPendingAdvance(pending, for: fingerprint)
    }

    /// 释放一个撤销清理 lease。generation 不匹配或已结束的 lease 会被忽略，
    /// 因而错误路径可以无条件调用，而不会重新开放更新的 generation。
    package func finishRevocation(
        _ namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) {
        let fingerprint = Self.fingerprint(for: namespace)
        guard var state = states[fingerprint],
            state.generation == generation,
            state.activeRevocations > 0
        else { return }
        state.activeRevocations -= 1
        states[fingerprint] = state
    }

    package func trackedNamespaceCount() -> Int {
        states.count
    }

    package func activeRevocationCount(for namespace: SecurityNamespaceID) -> Int {
        states[Self.fingerprint(for: namespace)]?.activeRevocations ?? 0
    }

    package func isActive(
        _ generation: NamespaceGeneration,
        for namespace: SecurityNamespaceID
    ) -> Bool {
        guard let state = states[Self.fingerprint(for: namespace)] else {
            return generation == NamespaceGeneration(0)
        }
        return !state.isExhausted
            && state.activeRevocations == 0
            && state.generation == generation
    }

    private func joinPendingAdvance(
        _ pending: PendingAdvance,
        for fingerprint: StorageNamespaceFingerprint
    ) async throws -> NamespaceGeneration {
        do {
            let generation = try await pending.task.value
            guard generation == pending.generation else {
                throw PipelineFailure.internalFailure(stage: .revocation)
            }
            return try completeAdvance(
                token: pending.token,
                generation: generation,
                for: fingerprint
            )
        } catch let failure as PipelineFailure {
            discardPendingAdvance(token: pending.token, for: fingerprint)
            throw failure
        } catch {
            discardPendingAdvance(token: pending.token, for: fingerprint)
            throw PipelineFailure.namespaceGenerationPersistenceFailed
        }
    }

    private func completeAdvance(
        token: UUID,
        generation: NamespaceGeneration,
        for fingerprint: StorageNamespaceFingerprint
    ) throws -> NamespaceGeneration {
        guard var state = states[fingerprint] else {
            throw PipelineFailure.internalFailure(stage: .revocation)
        }

        if pendingAdvances[fingerprint]?.token == token {
            pendingAdvances.removeValue(forKey: fingerprint)
        }

        if state.generation.value < generation.value {
            state.generation = generation
            state.activeRevocations = 1
        } else if state.generation == generation {
            guard state.activeRevocations < Int.max else {
                throw PipelineFailure.resourceLimit(
                    stage: .revocation,
                    reasonCode: "namespace-revocation-capacity-exceeded"
                )
            }
            state.activeRevocations += 1
        } else {
            throw PipelineFailure.internalFailure(stage: .revocation)
        }
        states[fingerprint] = state
        return generation
    }

    private func discardPendingAdvance(
        token: UUID,
        for fingerprint: StorageNamespaceFingerprint
    ) {
        guard pendingAdvances[fingerprint]?.token == token else { return }
        pendingAdvances.removeValue(forKey: fingerprint)
    }

    private func admit(
        _ fingerprint: StorageNamespaceFingerprint,
        stage: PipelineFailure.Stage = .requestValidation
    ) throws {
        guard states.count < maximumTrackedNamespaces else {
            throw PipelineFailure.resourceLimit(
                stage: stage,
                reasonCode: "namespace-registry-capacity-exceeded"
            )
        }
        states[fingerprint] = State(
            generation: NamespaceGeneration(0),
            isExhausted: false,
            activeRevocations: 0
        )
    }

    private static func makeStates(
        from generations: [StorageNamespaceFingerprint: NamespaceGeneration],
        exhaustMaximum: Bool
    ) -> [StorageNamespaceFingerprint: State] {
        generations.mapValues {
            State(
                generation: $0,
                isExhausted: exhaustMaximum && $0.value == UInt64.max,
                activeRevocations: 0
            )
        }
    }

    private static func fingerprint(
        for namespace: SecurityNamespaceID
    ) -> StorageNamespaceFingerprint {
        StorageNamespaceFingerprint(namespace: namespace.value)
    }
}
