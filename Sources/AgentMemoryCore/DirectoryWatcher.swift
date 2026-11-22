import CoreServices
import Foundation

public final class DirectoryWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let debounceSeconds: TimeInterval
    private let maxWaitSeconds: TimeInterval
    private let ignoredFilenames: Set<String>
    private let onTrigger: @Sendable () -> Void

    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?
    private var firstEventTime: Date?
    private var stopped = false

    public init?(
        paths: [String],
        debounceSeconds: TimeInterval = 15,
        maxWaitSeconds: TimeInterval = 60,
        ignoredFilenames: Set<String> = [],
        label: String = "agent.memory.fsevents",
        onTrigger: @escaping @Sendable () -> Void
    ) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        self.queue = DispatchQueue(label: label)
        self.debounceSeconds = debounceSeconds
        self.maxWaitSeconds = maxWaitSeconds
        self.ignoredFilenames = ignoredFilenames
        self.onTrigger = onTrigger

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else {
            return nil
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    deinit {
        stop()
    }

    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            debounceItem?.cancel()
            debounceItem = nil
            firstEventTime = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    private func handleEvents(_ paths: [String]) {
        guard !stopped else { return }
        let relevant = paths.contains { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return !ignoredFilenames.contains(name)
        }
        guard relevant else { return }

        let now = Date()
        if firstEventTime == nil { firstEventTime = now }
        let elapsed = now.timeIntervalSince(firstEventTime ?? now)
        let remainingMax = max(0, maxWaitSeconds - elapsed)
        let delay = min(debounceSeconds, remainingMax)

        debounceItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.firstEventTime = nil
            self.debounceItem = nil
            self.onTrigger()
        }
        debounceItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
        guard let info, numEvents > 0 else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let count = CFArrayGetCount(cfArray)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for index in 0..<count {
            if let ptr = CFArrayGetValueAtIndex(cfArray, index) {
                let cfString = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
                paths.append(cfString as String)
            }
        }
        watcher.handleEvents(paths)
    }
}
