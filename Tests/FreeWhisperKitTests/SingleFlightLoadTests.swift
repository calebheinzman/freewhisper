import Foundation
import Testing

@testable import FreeWhisperKit

/// The bug these cover: dictation pinned on "Transcribing…" forever.
///
/// `AppCoordinator.start()` preloads the dictation model while the hotkey is
/// already live. Press it during that window and a second `prepare()` runs
/// concurrently with the first. Both engines guarded with `guard manager == nil`,
/// which reads correct and is not — actors are reentrant, so the actor is
/// released across the `await` that does the loading and the field stays nil for
/// its whole duration. Two concurrent CoreML loads of the same weights followed,
/// and nothing bounded the wait.
///
/// The engines themselves need real model files, so these exercise a stand-in
/// with the same shape: the structure being tested is the guard, not CoreML.
@Suite("Concurrent model loading")
struct SingleFlightLoadTests {
    /// Mirrors the fixed `prepare` in FluidAudioEngine and WhisperKitEngine.
    actor Engine {
        private(set) var loadCount = 0
        private var loaded: String?
        private var loading: Task<String, any Error>?

        func prepare() async throws {
            if loaded != nil { return }
            if let loading {
                loaded = try await loading.value
                return
            }
            let task = Task.detached { [self] in
                await self.bump()
                try await Task.sleep(for: .milliseconds(50))
                return "weights"
            }
            loading = task
            do {
                loaded = try await task.value
                loading = nil
            } catch {
                loading = nil
                throw error
            }
        }

        private func bump() { loadCount += 1 }
        func isLoaded() -> Bool { loaded != nil }
    }

    /// The regression. Before the fix this reported 8.
    @Test("concurrent prepare calls load the weights exactly once")
    func concurrentPrepareLoadsOnce() async throws {
        let engine = Engine()
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await engine.prepare() }
            }
            while let _ = try? await group.next() {}
        }
        #expect(await engine.loadCount == 1)
        #expect(await engine.isLoaded())
    }

    @Test("a caller arriving mid-load waits for it rather than starting another")
    func lateCallerJoinsInFlightLoad() async throws {
        let engine = Engine()
        async let first: Void = engine.prepare()
        try await Task.sleep(for: .milliseconds(10))   // land inside the load
        async let second: Void = engine.prepare()
        _ = try await (first, second)
        #expect(await engine.loadCount == 1)
    }

    @Test("preparing again after a completed load does no work")
    func repeatedPrepareIsFree() async throws {
        let engine = Engine()
        try await engine.prepare()
        try await engine.prepare()
        #expect(await engine.loadCount == 1)
    }
}
