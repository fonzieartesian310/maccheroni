import Foundation
import MaccheroniCore
import MaccheroniPostprocess

struct ModelDownloadPlan: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case cache(URL)
        case local(URL)
    }

    static let mossModelID = "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8"
    static var defaultCacheRoot: URL {
        resolveCacheRoot()
    }

    static func resolveCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configuredCache = environment["MACCHERONI_BENCHMARK_CACHE"], !configuredCache.isEmpty {
            return URL(fileURLWithPath: configuredCache, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(
            "Library/Caches/Maccheroni/benchmarks",
            isDirectory: true
        )
    }

    let model: ModelDescriptor
    let destination: Destination

    init(
        model: ModelDescriptor,
        cacheRoot: URL = Self.defaultCacheRoot,
        localPostprocessLocation: URL = LocalPostprocessRuntime.local.modelSnapshotURL
    ) {
        self.model = model
        if model.hfModelID == Self.mossModelID {
            destination = .local(cacheRoot.appendingPathComponent(
                "models/moss-transcribe-diarize-0.9b-mlx-int8-\(model.revision)",
                isDirectory: true
            ))
        } else if model == LocalPostprocessBackend.pinnedModel {
            destination = .local(localPostprocessLocation.standardizedFileURL)
        } else {
            destination = .cache(cacheRoot.appendingPathComponent(
                "models/huggingface/hub",
                isDirectory: true
            ))
        }
    }

    var pinnedLocation: URL {
        switch destination {
        case let .local(url):
            url
        case let .cache(url):
            url.appendingPathComponent(
                "models--\(model.hfModelID.replacingOccurrences(of: "/", with: "--"))/snapshots/\(model.revision)",
                isDirectory: true
            )
        }
    }

    var downloadArguments: [String] {
        arguments(command: "download")
    }

    var verifyArguments: [String] {
        arguments(command: "cache verify", verification: true)
    }

    private func arguments(command: String, verification: Bool = false) -> [String] {
        let commandArguments = command.split(separator: " ").map(String.init)
        let locationArguments: [String]
        switch destination {
        case let .cache(url):
            locationArguments = ["--cache-dir", url.path]
        case let .local(url):
            locationArguments = ["--local-dir", url.path]
        }
        return commandArguments + [model.hfModelID, "--revision", model.revision]
            + locationArguments
            + (verification ? ["--fail-on-missing-files"] : [])
            + ["--format", "json"]
    }
}

struct ModelDownloadInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

struct ModelDownloadProcessOutput: Equatable, Sendable {
    let exitStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol ModelDownloadExecuting: Sendable {
    func run(_ invocation: ModelDownloadInvocation) async throws -> ModelDownloadProcessOutput
}

enum ModelDownloadError: Error, Equatable, LocalizedError, Sendable {
    case hfUnavailable
    case launchFailed(String)
    case commandFailed(command: String, exitStatus: Int32, message: String)
    case pinnedLocationMissing(String)

    var errorDescription: String? {
        switch self {
        case .hfUnavailable:
            appString("The Hugging Face command-line tool (hf) is not installed. Install it, then try again.")
        case let .launchFailed(message):
            appString("The Hugging Face command-line tool could not start: \(message)")
        case let .commandFailed(command, exitStatus, message):
            appString("The Hugging Face \(command) command failed (exit \(exitStatus)): \(message)")
        case let .pinnedLocationMissing(path):
            appString("The Hugging Face command finished, but the pinned model location is missing: \(path)")
        }
    }
}

actor ModelDownloadService {
    private let cacheRoot: URL
    private let localPostprocessLocation: URL
    private let executableURL: URL?
    private let executableResolver: @Sendable () -> URL?
    private let executor: any ModelDownloadExecuting
    private let locationExists: @Sendable (URL) -> Bool

    init(
        cacheRoot: URL = ModelDownloadPlan.defaultCacheRoot,
        localPostprocessLocation: URL = LocalPostprocessRuntime.local.modelSnapshotURL,
        executableURL: URL? = nil,
        executableResolver: (@Sendable () -> URL?)? = nil,
        executor: any ModelDownloadExecuting = FoundationModelDownloadExecutor(),
        locationExists: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.cacheRoot = cacheRoot
        self.localPostprocessLocation = localPostprocessLocation.standardizedFileURL
        self.executableURL = executableURL
        self.executableResolver = executableResolver ?? {
            Self.resolveHFExecutable(cacheRoot: cacheRoot)
        }
        self.executor = executor
        self.locationExists = locationExists
    }

    func download(_ model: ModelDescriptor) async throws {
        let plan = ModelDownloadPlan(
            model: model,
            cacheRoot: cacheRoot,
            localPostprocessLocation: localPostprocessLocation
        )
        guard let executableURL = executableURL ?? executableResolver() else {
            throw ModelDownloadError.hfUnavailable
        }

        try await run(plan.downloadArguments, named: "download", with: executableURL)
        try await run(plan.verifyArguments, named: "cache verify", with: executableURL)
        guard locationExists(plan.pinnedLocation) else {
            throw ModelDownloadError.pinnedLocationMissing(plan.pinnedLocation.path)
        }
    }

    nonisolated static func resolveHFExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheRoot: URL = ModelDownloadPlan.defaultCacheRoot,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["MACCHERONI_HF_EXECUTABLE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("hf")
            }
        }
        candidates += [
            homeDirectory.appendingPathComponent(".local/bin/hf"),
            URL(fileURLWithPath: "/opt/homebrew/bin/hf"),
            URL(fileURLWithPath: "/usr/local/bin/hf"),
            cacheRoot.appendingPathComponent("venvs/mlx-audio/bin/hf"),
        ]
        return candidates.first(where: isExecutable)
    }

    private func run(
        _ arguments: [String],
        named command: String,
        with executableURL: URL
    ) async throws {
        let output: ModelDownloadProcessOutput
        do {
            output = try await executor.run(ModelDownloadInvocation(
                executableURL: executableURL,
                arguments: arguments
            ))
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.launchFailed(error.localizedDescription)
        }
        guard output.exitStatus == 0 else {
            let standardError = String(decoding: output.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let standardOutput = String(decoding: output.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelDownloadError.commandFailed(
                command: command,
                exitStatus: output.exitStatus,
                message: standardError.isEmpty ? standardOutput : standardError
            )
        }
    }
}

struct FoundationModelDownloadExecutor: ModelDownloadExecuting {
    func run(_ invocation: ModelDownloadInvocation) async throws -> ModelDownloadProcessOutput {
        try await Task.detached(priority: .userInitiated) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "maccheroni-model-download-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let stdoutURL = scratch.appendingPathComponent("stdout")
            let stderrURL = scratch.appendingPathComponent("stderr")
            guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
                  FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            else {
                throw ModelDownloadError.launchFailed("could not create command output capture files")
            }
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }

            let process = Process()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                throw ModelDownloadError.launchFailed(error.localizedDescription)
            }
            process.waitUntilExit()
            try stdout.synchronize()
            try stderr.synchronize()
            return ModelDownloadProcessOutput(
                exitStatus: process.terminationStatus,
                standardOutput: try Data(contentsOf: stdoutURL),
                standardError: try Data(contentsOf: stderrURL)
            )
        }.value
    }
}
