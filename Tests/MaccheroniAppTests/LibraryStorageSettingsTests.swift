import Foundation
import MaccheroniPostprocess
import Testing
@testable import MaccheroniApp

struct LibraryStorageSettingsTests {
    @Test
    func resolvesDefaultDirectoriesWhenThereAreNoOverrides() {
        let applicationSupport = URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true)

        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: applicationSupport,
            environment: [:],
            recordingsPath: nil,
            runsPath: nil
        )

        #expect(repository.root.path == "/fixtures/Application Support/Maccheroni")
        #expect(repository.recordingsRoot.path == "/fixtures/Application Support/Maccheroni/Recordings")
        #expect(repository.runsRoot.path == "/fixtures/Application Support/Maccheroni/Runs")
    }

    @Test
    func resolvesAbsoluteStoredDirectoriesAndStandardizesThem() {
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true),
            environment: [:],
            recordingsPath: "/fixtures/recordings/../recordings-final",
            runsPath: "/fixtures/runs/../runs-final"
        )

        #expect(repository.recordingsRoot.path == "/fixtures/recordings-final")
        #expect(repository.runsRoot.path == "/fixtures/runs-final")
    }

    @Test
    func environmentRootTakesPrecedenceOverStoredDirectories() {
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true),
            environment: [LibraryStorageSettings.libraryRootEnvironmentKey: "/fixture-override/library"],
            recordingsPath: "/stored/recordings",
            runsPath: "/stored/runs"
        )

        #expect(repository.root.path == "/fixture-override/library")
        #expect(repository.recordingsRoot.path == "/fixture-override/library/Recordings")
        #expect(repository.runsRoot.path == "/fixture-override/library/Runs")
    }

    @Test
    func ignoresBlankAndRelativeStoredDirectories() {
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true),
            environment: [LibraryStorageSettings.libraryRootEnvironmentKey: "   "],
            recordingsPath: "   ",
            runsPath: "relative/runs"
        )

        #expect(repository.recordingsRoot.path == "/fixtures/Application Support/Maccheroni/Recordings")
        #expect(repository.runsRoot.path == "/fixtures/Application Support/Maccheroni/Runs")
    }

    @Test
    func modelRegistryIncludesTheOnlyVerifiedLocalPostprocessModel() {
        let descriptors = ModelRegistry.descriptors(in: [])

        #expect(descriptors == [LocalPostprocessBackend.pinnedModel])
        #expect(ModelRegistry.localPostprocessModelSelection.contains(
            LocalPostprocessBackend.pinnedModel.hfModelID
        ))
    }
}
