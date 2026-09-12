import Foundation

@MainActor
enum MacPlaybackShutdownBarrier {
    private final class Completion {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: value)
        }
    }

    static func wait(for tasks: [Task<Void, Never>], timeout: TimeInterval) async -> Bool {
        guard !tasks.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            Task {
                for task in tasks { await task.value }
                completion.finish(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, min(timeout, 60)) * 1_000_000_000))
                completion.finish(false)
            }
        }
    }
}
