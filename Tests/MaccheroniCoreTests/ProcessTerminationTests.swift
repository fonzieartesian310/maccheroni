import Darwin
import Foundation
import Testing
@testable import MaccheroniCore

struct ProcessTerminationTests {
    @Test
    func terminatesOnlyTheExactRootDescendantChain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try launchProcessChain(in: root, rootIgnoresTERM: true)
        let sentinel = try launchSentinel()
        defer {
            killOwnedProcess(fixture.rootPID)
            fixture.process.terminate()
            for processID in (try? recordedProcessIDs(at: fixture.pidURL)) ?? [] {
                killOwnedProcess(processID)
            }
            killOwnedProcess(sentinel.processIdentifier)
            sentinel.terminate()
        }

        let chain = try await waitForProcessIDs(at: fixture.pidURL, count: 3)
        #expect(chain.first == fixture.rootPID)
        #expect(isAlive(sentinel.processIdentifier))

        let startedAt = Date()
        let result = await ProcessTerminator.terminate(
            processID: fixture.rootPID,
            isRunning: { fixture.process.isRunning },
            timing: ProcessTerminationTiming(gracePeriodS: 0.02, pollIntervalS: 0.005, exitWaitS: 1.0)
        )

        #expect(result == .terminatedAfterSIGKILL)
        #expect(Date().timeIntervalSince(startedAt) < 1.5)
        for processID in chain {
            #expect(try await waitForAbsence(of: processID, timeoutS: 1.0))
        }
        #expect(isAlive(sentinel.processIdentifier))
    }

    @Test
    func killsReparentedDescendantsWhenRootExitsAfterSIGTERM() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try launchProcessChain(in: root, rootIgnoresTERM: false)
        let sentinel = try launchSentinel()
        defer {
            killOwnedProcess(fixture.rootPID)
            fixture.process.terminate()
            for processID in (try? recordedProcessIDs(at: fixture.pidURL)) ?? [] {
                killOwnedProcess(processID)
            }
            killOwnedProcess(sentinel.processIdentifier)
            sentinel.terminate()
        }

        let chain = try await waitForProcessIDs(at: fixture.pidURL, count: 3)
        let result = await ProcessTerminator.terminate(
            processID: fixture.rootPID,
            isRunning: { fixture.process.isRunning },
            timing: ProcessTerminationTiming(gracePeriodS: 0.02, pollIntervalS: 0.005, exitWaitS: 1.0)
        )

        #expect(result == .terminatedAfterSIGKILL)
        for processID in chain {
            #expect(try await waitForAbsence(of: processID, timeoutS: 1.0))
        }
        #expect(isAlive(sentinel.processIdentifier))
    }

    private func launchProcessChain(
        in root: URL,
        rootIgnoresTERM: Bool
    ) throws -> (rootPID: Int32, process: Process, pidURL: URL) {
        let script = root.appendingPathComponent("process-chain.py")
        let pidURL = root.appendingPathComponent("chain-pids")
        try Data("""
        #!/usr/bin/python3
        import os
        import signal
        import subprocess
        import sys

        pid_path = sys.argv[1]
        role = sys.argv[2]
        if role != 'root' or sys.argv[3] == 'ignore-root-term':
            signal.signal(signal.SIGTERM, lambda _signal, _frame: None)
        with open(pid_path, 'a') as pid_file:
            pid_file.write(f'{os.getpid()}\\n')
            pid_file.flush()
        if role != 'grandchild':
            next_role = 'child' if role == 'root' else 'grandchild'
            subprocess.Popen([sys.executable, __file__, pid_path, next_role, sys.argv[3]])
        while True:
            signal.pause()
        """.utf8).write(to: script, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = script
        process.arguments = [pidURL.path, "root", rootIgnoresTERM ? "ignore-root-term" : "default-root-term"]
        try process.run()
        return (process.processIdentifier, process, pidURL)
    }

    private func launchSentinel() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func waitForProcessIDs(at url: URL, count: Int) async throws -> [Int32] {
        for _ in 0 ..< 100 {
            let processIDs = (try? recordedProcessIDs(at: url)) ?? []
            if processIDs.count == count { return processIDs }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProcessTerminationTestTimeout()
    }

    private func recordedProcessIDs(at url: URL) throws -> [Int32] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private func waitForAbsence(of processID: Int32, timeoutS: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutS)
        while isAlive(processID), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return !isAlive(processID)
    }

    private func isAlive(_ processID: Int32) -> Bool {
        let result = Darwin.kill(processID, 0)
        let probeErrno = errno
        return result == 0 || probeErrno == EPERM
    }

    private func killOwnedProcess(_ processID: Int32) {
        guard processID > 0, isAlive(processID) else { return }
        _ = Darwin.kill(processID, SIGKILL)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccheroni-process-termination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private struct ProcessTerminationTestTimeout: Error {}
