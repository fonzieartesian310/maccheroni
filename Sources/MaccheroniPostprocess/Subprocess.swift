import Foundation
import MaccheroniCore

public struct SubprocessInvocation: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var standardInput: Data
    public var environment: [String: String]
    public var currentDirectoryURL: URL?
    public var timeoutS: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        timeoutS: TimeInterval = 600
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeoutS = timeoutS
    }
}

public struct SubprocessOutput: Equatable, Sendable {
    public var exitStatus: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(exitStatus: Int32, standardOutput: Data, standardError: Data) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol SubprocessExecuting: Sendable {
    func run(_ invocation: SubprocessInvocation) async throws -> SubprocessOutput
}

public struct FoundationSubprocessExecutor: SubprocessExecuting {
    private let terminationTiming: ProcessTerminationTiming

    public init(terminationTiming: ProcessTerminationTiming = .default) {
        self.terminationTiming = terminationTiming
    }

    public func run(_ invocation: SubprocessInvocation) async throws -> SubprocessOutput {
        let terminationTiming = terminationTiming
        let task = Task.detached {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "maccheroni-postprocess-subprocess-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: scratch,
                    withIntermediateDirectories: false
                )
            } catch {
                throw PostprocessError.launchFailed(
                    "could not create subprocess scratch directory: \(error.localizedDescription)"
                )
            }
            defer { try? FileManager.default.removeItem(at: scratch) }
            let inputURL = scratch.appendingPathComponent("stdin")
            let outputURL = scratch.appendingPathComponent("stdout")
            let errorURL = scratch.appendingPathComponent("stderr")
            try invocation.standardInput.write(to: inputURL, options: .withoutOverwriting)
            try Data().write(to: outputURL, options: .withoutOverwriting)
            try Data().write(to: errorURL, options: .withoutOverwriting)
            let input = try FileHandle(forReadingFrom: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            let errorOutput = try FileHandle(forWritingTo: errorURL)
            defer {
                try? input.close()
                try? output.close()
                try? errorOutput.close()
            }
            let process = Process()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorOutput
            process.currentDirectoryURL = invocation.currentDirectoryURL
            if !invocation.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, supplied in supplied }
            }
            do {
                try process.run()
            } catch {
                throw PostprocessError.launchFailed("could not launch \(invocation.executableURL.path): \(error.localizedDescription)")
            }
            let liveness = SubprocessLiveness(process)
            let deadline = Date().addingTimeInterval(invocation.timeoutS)
            while process.isRunning, Date() < deadline {
                if Task.isCancelled {
                    _ = await ProcessTerminator.terminate(
                        processID: process.processIdentifier,
                        isRunning: { liveness.process.isRunning },
                        timing: terminationTiming
                    )
                    throw CancellationError()
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    _ = await ProcessTerminator.terminate(
                        processID: process.processIdentifier,
                        isRunning: { liveness.process.isRunning },
                        timing: terminationTiming
                    )
                    throw CancellationError()
                }
            }
            if process.isRunning {
                _ = await ProcessTerminator.terminate(
                    processID: process.processIdentifier,
                    isRunning: { liveness.process.isRunning },
                    timing: terminationTiming
                )
                throw PostprocessError.backendFailed(
                    "subprocess timed out after \(Int(invocation.timeoutS)) seconds"
                )
            }
            output.synchronizeFile()
            errorOutput.synchronizeFile()
            return SubprocessOutput(
                exitStatus: process.terminationStatus,
                standardOutput: try Data(contentsOf: outputURL),
                standardError: try Data(contentsOf: errorURL)
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private final class SubprocessLiveness: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
