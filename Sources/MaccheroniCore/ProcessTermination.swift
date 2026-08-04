import Darwin
import Foundation

public struct ProcessTerminationTiming: Equatable, Sendable {
    public var gracePeriodS: TimeInterval
    public var pollIntervalS: TimeInterval
    public var exitWaitS: TimeInterval

    public init(
        gracePeriodS: TimeInterval = 0.5,
        pollIntervalS: TimeInterval = 0.05,
        exitWaitS: TimeInterval = 1.0
    ) {
        self.gracePeriodS = max(0, gracePeriodS)
        self.pollIntervalS = max(0.001, pollIntervalS)
        self.exitWaitS = max(0, exitWaitS)
    }

    public static let `default` = ProcessTerminationTiming()
}

public enum ProcessTerminationResult: Equatable, Sendable {
    case alreadyExited
    case terminatedAfterSIGTERM
    case terminatedAfterSIGKILL
    case signalFailed(errno: Int32)
    case exitWaitTimedOut
}

public enum ProcessTerminator {
    /// Terminates the exact root PID and descendants that `libproc` reports beneath it.
    ///
    /// This intentionally never uses process groups, executable names, `pkill`, or `killall`.
    /// Each discovered PID is paired with its start time, so a recycled PID is not signalled.
    public static func terminate(
        processID: Int32,
        isRunning: @escaping @Sendable () -> Bool,
        timing: ProcessTerminationTiming = .default
    ) async -> ProcessTerminationResult {
        await Task.detached(priority: .userInitiated) {
            guard processID > 0, isRunning(), let root = processIdentity(for: processID) else {
                return .alreadyExited
            }

            var owned = [Int32: ProcessNode]()
            recordTree(root, parent: nil, depth: 0, into: &owned)
            guard !owned.isEmpty else { return .alreadyExited }

            var termSignalled = Set<ProcessIdentity>()
            if let failure = signalOwned(
                SIGTERM,
                owned: owned,
                excluding: &termSignalled
            ) {
                return .signalFailed(errno: failure)
            }

            let termDeadline = Date().addingTimeInterval(timing.gracePeriodS)
            while true {
                refreshOwnedTree(root: root, owned: &owned)
                if liveNodes(in: owned).isEmpty {
                    return .terminatedAfterSIGTERM
                }
                guard Date() < termDeadline else { break }
                if let failure = signalOwned(
                    SIGTERM,
                    owned: owned,
                    excluding: &termSignalled
                ) {
                    return .signalFailed(errno: failure)
                }
                await sleep(upTo: termDeadline, timing: timing)
            }

            // Take one final child-first snapshot immediately before escalation.
            refreshOwnedTree(root: root, owned: &owned)
            var killSignalled = Set<ProcessIdentity>()
            if let failure = signalOwned(
                SIGKILL,
                owned: owned,
                excluding: &killSignalled
            ) {
                return .signalFailed(errno: failure)
            }

            let exitDeadline = Date().addingTimeInterval(timing.exitWaitS)
            while true {
                refreshOwnedTree(root: root, owned: &owned)
                if liveNodes(in: owned).isEmpty {
                    return .terminatedAfterSIGKILL
                }
                guard Date() < exitDeadline else { return .exitWaitTimedOut }
                await sleep(upTo: exitDeadline, timing: timing)
            }
        }.value
    }

    private struct ProcessIdentity: Hashable, Sendable {
        let processID: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct ProcessMetadata: Sendable {
        let identity: ProcessIdentity
        let parentProcessID: Int32
    }

    private struct ProcessNode: Sendable {
        let identity: ProcessIdentity
        let parentProcessID: Int32?
        let depth: Int
    }

    private static func processIdentity(for processID: Int32) -> ProcessIdentity? {
        processMetadata(for: processID)?.identity
    }

    private static func processMetadata(for processID: Int32) -> ProcessMetadata? {
        var info = proc_bsdinfo()
        let byteCount = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard byteCount == MemoryLayout<proc_bsdinfo>.size, info.pbi_pid == processID else {
            return nil
        }
        return ProcessMetadata(
            identity: ProcessIdentity(
                processID: processID,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            parentProcessID: Int32(info.pbi_ppid)
        )
    }

    private static func isLive(_ identity: ProcessIdentity) -> Bool {
        processIdentity(for: identity.processID) == identity
    }

    private static func directChildren(of parentProcessID: Int32) -> [Int32] {
        allProcessIDs().filter { processMetadata(for: $0)?.parentProcessID == parentProcessID }
    }

    private static func allProcessIDs() -> [Int32] {
        var capacity = 1_024
        while true {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let byteCount = processIDs.withUnsafeMutableBufferPointer { buffer in
                proc_listpids(
                    UInt32(PROC_ALL_PIDS),
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count * MemoryLayout<pid_t>.stride)
                )
            }
            guard byteCount > 0 else { return [] }
            let count = min(Int(byteCount) / MemoryLayout<pid_t>.stride, processIDs.count)
            if count < processIDs.count {
                return Array(processIDs.prefix(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
    }

    private static func recordTree(
        _ identity: ProcessIdentity,
        parent: Int32?,
        depth: Int,
        into owned: inout [Int32: ProcessNode]
    ) {
        guard isLive(identity), owned[identity.processID] == nil else { return }
        owned[identity.processID] = ProcessNode(
            identity: identity,
            parentProcessID: parent,
            depth: depth
        )
        for childProcessID in directChildren(of: identity.processID) {
            guard let child = processIdentity(for: childProcessID) else { continue }
            recordTree(child, parent: identity.processID, depth: depth + 1, into: &owned)
        }
    }

    private static func refreshOwnedTree(
        root: ProcessIdentity,
        owned: inout [Int32: ProcessNode]
    ) {
        if owned[root.processID] == nil, isLive(root) {
            recordTree(root, parent: nil, depth: 0, into: &owned)
        }
        let parents = owned.values.sorted { $0.depth < $1.depth }
        for parent in parents where isLive(parent.identity) {
            for childProcessID in directChildren(of: parent.identity.processID) {
                guard owned[childProcessID] == nil,
                      let child = processIdentity(for: childProcessID) else {
                    continue
                }
                recordTree(
                    child,
                    parent: parent.identity.processID,
                    depth: parent.depth + 1,
                    into: &owned
                )
            }
        }
    }

    private static func liveNodes(in owned: [Int32: ProcessNode]) -> [ProcessNode] {
        owned.values.filter { isLive($0.identity) }
    }

    private static func signalOwned(
        _ signal: Int32,
        owned: [Int32: ProcessNode],
        excluding signalled: inout Set<ProcessIdentity>
    ) -> Int32? {
        for node in liveNodes(in: owned).sorted(by: childFirst) where !signalled.contains(node.identity) {
            let result = Darwin.kill(node.identity.processID, signal)
            let signalErrno = errno
            if result == 0 || signalErrno == ESRCH {
                signalled.insert(node.identity)
                continue
            }
            return signalErrno
        }
        return nil
    }

    private static func childFirst(_ lhs: ProcessNode, _ rhs: ProcessNode) -> Bool {
        if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
        return lhs.identity.processID < rhs.identity.processID
    }

    private static func sleep(upTo deadline: Date, timing: ProcessTerminationTiming) async {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return }
        let seconds = min(timing.pollIntervalS, remaining)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
