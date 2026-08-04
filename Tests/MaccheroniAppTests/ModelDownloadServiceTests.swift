import Foundation
import MaccheroniCore
import MaccheroniPostprocess
import Testing
@testable import MaccheroniApp

struct ModelDownloadServiceTests {
    @Test
    func cacheRootUsesTheConfiguredBenchmarkCacheOrTheMaccheroniDefault() {
        #expect(ModelDownloadPlan.resolveCacheRoot(
            environment: ["MACCHERONI_BENCHMARK_CACHE": "/tmp/maccheroni-models"],
            homeDirectory: URL(fileURLWithPath: "/unused-home", isDirectory: true)
        ).path == "/tmp/maccheroni-models")
        #expect(ModelDownloadPlan.resolveCacheRoot(
            environment: ["MACCHERONI_BENCHMARK_CACHE": ""],
            homeDirectory: URL(fileURLWithPath: "/test-home", isDirectory: true)
        ).path == "/test-home/Library/Caches/Maccheroni/benchmarks")
    }

    @Test
    func downloadsAndVerifiesGeneralModelAtItsPinnedCacheSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = descriptor(id: "example/general-model")
        let plan = ModelDownloadPlan(model: model, cacheRoot: root)
        let executor = DownloadExecutor(createPinnedLocationAfterInvocation: 1, location: plan.pinnedLocation)
        let service = ModelDownloadService(
            cacheRoot: root,
            executableURL: URL(fileURLWithPath: "/tests/hf"),
            executor: executor
        )

        try await service.download(model)

        let invocations = await executor.recordedInvocations()
        #expect(invocations.map(\.arguments) == [
            ["download", "example/general-model", "--revision", model.revision, "--cache-dir", root.appendingPathComponent("models/huggingface/hub").path, "--format", "json"],
            ["cache", "verify", "example/general-model", "--revision", model.revision, "--cache-dir", root.appendingPathComponent("models/huggingface/hub").path, "--fail-on-missing-files", "--format", "json"],
        ])
        #expect(invocations.allSatisfy { !$0.arguments.contains("--force") })
    }

    @Test
    func usesPinnedMossLocalDirectoryForDownloadAndVerification() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = descriptor(id: ModelDownloadPlan.mossModelID)
        let plan = ModelDownloadPlan(model: model, cacheRoot: root)
        let executor = DownloadExecutor(createPinnedLocationAfterInvocation: 1, location: plan.pinnedLocation)
        let service = ModelDownloadService(
            cacheRoot: root,
            executableURL: URL(fileURLWithPath: "/tests/hf"),
            executor: executor
        )

        try await service.download(model)

        let invocations = await executor.recordedInvocations()
        let location = root.appendingPathComponent("models/moss-transcribe-diarize-0.9b-mlx-int8-\(model.revision)").path
        #expect(invocations.map(\.arguments) == [
            ["download", ModelDownloadPlan.mossModelID, "--revision", model.revision, "--local-dir", location, "--format", "json"],
            ["cache", "verify", ModelDownloadPlan.mossModelID, "--revision", model.revision, "--local-dir", location, "--fail-on-missing-files", "--format", "json"],
        ])
    }

    @Test
    func downloadsPinnedLocalPostprocessModelToTheRuntimeSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("postprocess-snapshot", isDirectory: true)
        let model = LocalPostprocessBackend.pinnedModel
        let plan = ModelDownloadPlan(
            model: model,
            cacheRoot: root,
            localPostprocessLocation: location
        )
        let executor = DownloadExecutor(
            createPinnedLocationAfterInvocation: 1,
            location: plan.pinnedLocation
        )
        let service = ModelDownloadService(
            cacheRoot: root,
            localPostprocessLocation: location,
            executableURL: URL(fileURLWithPath: "/tests/hf"),
            executor: executor
        )

        try await service.download(model)

        #expect(plan.pinnedLocation == location.standardizedFileURL)
        #expect(await executor.recordedInvocations().map(\.arguments) == [
            ["download", model.hfModelID, "--revision", model.revision,
             "--local-dir", location.path, "--format", "json"],
            ["cache", "verify", model.hfModelID, "--revision", model.revision,
             "--local-dir", location.path, "--fail-on-missing-files", "--format", "json"],
        ])
    }

    @Test
    func propagatesDownloadFailureWithoutRunningVerify() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = DownloadExecutor(outputs: [
            ModelDownloadProcessOutput(exitStatus: 7, standardOutput: Data(), standardError: Data("network unavailable".utf8)),
        ])
        let service = ModelDownloadService(
            cacheRoot: root,
            executableURL: URL(fileURLWithPath: "/tests/hf"),
            executor: executor
        )

        await #expect(throws: ModelDownloadError.commandFailed(command: "download", exitStatus: 7, message: "network unavailable")) {
            try await service.download(descriptor(id: "example/failure"))
        }
        #expect(await executor.recordedInvocations().count == 1)
    }

    @Test
    func succeedsOnlyWhenThePinnedLocationExistsAfterVerification() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = descriptor(id: "example/missing-location")
        let executor = DownloadExecutor()
        let service = ModelDownloadService(
            cacheRoot: root,
            executableURL: URL(fileURLWithPath: "/tests/hf"),
            executor: executor
        )

        await #expect(throws: ModelDownloadError.pinnedLocationMissing(
            ModelDownloadPlan(model: model, cacheRoot: root).pinnedLocation.path
        )) {
            try await service.download(model)
        }
        let invocations = await executor.recordedInvocations()
        #expect(invocations.map { Array($0.arguments.prefix(2)) } == [
            ["download", "example/missing-location"],
            ["cache", "verify"],
        ])
    }

    private func descriptor(id: String) -> ModelDescriptor {
        ModelDescriptor(
            role: .asr,
            hfModelID: id,
            revision: "0123456789abcdef0123456789abcdef01234567",
            quantization: "int8"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private actor DownloadExecutor: ModelDownloadExecuting {
    private let outputs: [ModelDownloadProcessOutput]
    private let createPinnedLocationAfterInvocation: Int?
    private let location: URL?
    private var invocations: [ModelDownloadInvocation] = []

    init(
        outputs: [ModelDownloadProcessOutput] = [
            ModelDownloadProcessOutput(exitStatus: 0, standardOutput: Data(), standardError: Data()),
            ModelDownloadProcessOutput(exitStatus: 0, standardOutput: Data(), standardError: Data()),
        ],
        createPinnedLocationAfterInvocation: Int? = nil,
        location: URL? = nil
    ) {
        self.outputs = outputs
        self.createPinnedLocationAfterInvocation = createPinnedLocationAfterInvocation
        self.location = location
    }

    func run(_ invocation: ModelDownloadInvocation) throws -> ModelDownloadProcessOutput {
        let index = invocations.count
        invocations.append(invocation)
        if index == createPinnedLocationAfterInvocation, let location {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        }
        return outputs[index]
    }

    func recordedInvocations() -> [ModelDownloadInvocation] {
        invocations
    }
}
