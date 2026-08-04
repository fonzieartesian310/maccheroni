import Foundation
import Testing
@testable import MaccheroniDiarize
import MaccheroniCore

@Suite(.serialized) struct MaccheroniDiarizeTests {
    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        guard let fixture = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missing(name)
        }
        return fixture
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaccheroniDiarizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutable(_ contents: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fixture-command.sh")
        try Data(contents.utf8).write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func writeFile(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
        return file
    }

    private func processCaptureNames() throws -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Maccheroni/diarization/process", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    @Test func community1NormalizesProcessOutputAndPassesRangeHint() async throws {
        let directory = try temporaryDirectory()
        let argumentsURL = directory.appendingPathComponent("arguments.txt")
        let fixture = try fixtureURL("community1-valid.json")
        let script = try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' \"$@\" > '\(argumentsURL.path)'
            cat '\(fixture.path)'
            """,
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: script,
            hfHomeURL: directory,
            timeoutS: 5,
            environment: [:],
            validatesPinnedModel: false
        ))
        let result = try await backend.diarizeWithEvidence(DiarizationRequest(
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav"),
            speakerCountHint: 2...3
        ))
        let timeline = result.timeline

        #expect(timeline.segments.map(\.speaker) == ["0", "1"])
        #expect(timeline.segments.map(\.startS) == [0, 3])
        let fixtureData = try Data(contentsOf: fixture)
        #expect(result.rawJSON == fixtureData)
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        #expect(arguments.contains("--min-speakers\n2\n"))
        #expect(arguments.contains("--max-speakers\n3\n"))
    }

    @Test func community1PromotesMalformedOutputAndProcessFailure() async throws {
        let directory = try temporaryDirectory()
        let malformed = try writeExecutable("#!/bin/sh\nprintf 'not-json'\n", in: directory)
        let backend = Community1Diarizer(configuration: .init(
            executableURL: malformed,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await backend.diarize(DiarizationRequest(
                audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")
            ))
            Issue.record("expected invalid JSON")
        } catch let error as DiarizationError {
            guard case .invalidJSON = error else {
                Issue.record("expected invalidJSON, got \(error)")
                return
            }
        }

        let failure = try writeExecutable("#!/bin/sh\nprintf 'backend unavailable' >&2\nexit 19\n", in: try temporaryDirectory())
        let failingBackend = Community1Diarizer(configuration: .init(
            executableURL: failure,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await failingBackend.diarize(DiarizationRequest(
                audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")
            ))
            Issue.record("expected process failure")
        } catch let error as DiarizationError {
            guard case let .processFailed(exitCode, standardError) = error else {
                Issue.record("expected processFailed, got \(error)")
                return
            }
            #expect(exitCode == 19)
            #expect(standardError.contains("backend unavailable"))
        }
    }

    @Test func community1DrainsLargeProcessOutputBeforeParsingJSON() async throws {
        let directory = try temporaryDirectory()
        let fixture = try fixtureURL("community1-valid.json")
        let script = try writeExecutable(
            """
            #!/bin/sh
            dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\000' x
            cat '\(fixture.path)'
            """,
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: script,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        let timeline = try await backend.diarize(DiarizationRequest(
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")
        ))
        #expect(timeline.segments.count == 2)
    }

    @Test func processAndCoverageFailuresAreExplicit() async throws {
        let audio = repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")

        let noOutputDirectory = try temporaryDirectory()
        let noOutput = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable("#!/bin/sh\nexit 0\n", in: noOutputDirectory),
            hfHomeURL: noOutputDirectory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await noOutput.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected missing output")
        } catch let error as DiarizationError {
            #expect(error == .missingOutput)
        }

        let timeoutDirectory = try temporaryDirectory()
        let capturesBeforeTimeout = try processCaptureNames()
        let timeout = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n",
                in: timeoutDirectory
            ),
            hfHomeURL: timeoutDirectory,
            timeoutS: 0.05,
            validatesPinnedModel: false
        ))
        let timeoutStarted = Date()
        do {
            _ = try await timeout.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected timeout")
        } catch let error as DiarizationError {
            guard case .timedOut = error else {
                Issue.record("expected timedOut, got \(error)")
                return
            }
        }
        #expect(Date().timeIntervalSince(timeoutStarted) < 1)
        #expect(try processCaptureNames() == capturesBeforeTimeout)

        let outOfRangeDirectory = try temporaryDirectory()
        let outOfRangeJSON = try writeFile(
            "{ \"segments\": [{ \"speaker\": 0, \"start\": 0, \"end\": 30 }] }\n",
            named: "out-of-range.json",
            in: outOfRangeDirectory
        )
        let outOfRange = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable("#!/bin/sh\ncat '\(outOfRangeJSON.path)'\n", in: outOfRangeDirectory),
            hfHomeURL: outOfRangeDirectory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await outOfRange.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected out-of-range failure")
        } catch let error as DiarizationError {
            guard case .outputOutOfRange = error else {
                Issue.record("expected outputOutOfRange, got \(error)")
                return
            }
        }

        let truncatedDirectory = try temporaryDirectory()
        let truncatedJSON = try writeFile(
            """
            {
              "model": {
                "hf_id": "FluidInference/speaker-diarization-coreml",
                "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
                "quantization": "CoreML storage Float32 Float16"
              },
              "audio": { "duration_s": 10 },
              "segments": [{ "speaker": "S1", "start_s": 0, "end_s": 1 }]
            }

            """,
            named: "truncated.json",
            in: truncatedDirectory
        )
        let truncated = FluidAudioDiarizer(configuration: .init(
            executableURL: try writeFluidHarnessCopying(truncatedJSON, in: truncatedDirectory),
            modelsRootURL: truncatedDirectory,
            outputRootURL: truncatedDirectory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await truncated.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected truncated coverage")
        } catch let error as DiarizationError {
            guard case .truncatedCoverage = error else {
                Issue.record("expected truncatedCoverage, got \(error)")
                return
            }
        }

        let mismatchDirectory = try temporaryDirectory()
        let mismatchJSON = try writeFile(
            """
            {
              "model": {
                "hf_id": "FluidInference/speaker-diarization-coreml",
                "revision": "0000000000000000000000000000000000000000",
                "quantization": "CoreML storage Float32 Float16"
              },
              "audio": { "duration_s": 28.8898125 },
              "segments": [{ "speaker": "S1", "start_s": 0, "end_s": 1 }]
            }

            """,
            named: "mismatch.json",
            in: mismatchDirectory
        )
        let mismatch = FluidAudioDiarizer(configuration: .init(
            executableURL: try writeFluidHarnessCopying(mismatchJSON, in: mismatchDirectory),
            modelsRootURL: mismatchDirectory,
            outputRootURL: mismatchDirectory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await mismatch.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected model mismatch")
        } catch let error as DiarizationError {
            guard case .modelMismatch = error else {
                Issue.record("expected modelMismatch, got \(error)")
                return
            }
        }
    }

    @Test func fluidAudioCanBeSelectedThroughDiarizerProtocolWithPinnedProvenance() async throws {
        let directory = try temporaryDirectory()
        let fixture = try fixtureURL("fluid-valid.json")
        let script = try writeFluidHarnessCopying(fixture, in: directory)
        let backend: any DiarizerBackend = FluidAudioDiarizer(configuration: .init(
            executableURL: script,
            modelsRootURL: FluidAudioDiarizerConfiguration.defaultModelsRootURL,
            outputRootURL: directory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: true
        ))
        #expect(backend.model.hfModelID == "FluidInference/speaker-diarization-coreml")
        #expect(backend.model.revision.count == 40)
        #expect(backend.model.revision == "1ed7a662fdc7109e36d822db793ee6eebdaf8594")
        #expect(backend.model.quantization == "coreml-fp32+fp16")

        let timeline = try await backend.diarize(DiarizationRequest(
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")
        ))
        #expect(timeline.segments.map(\.speaker) == ["S2", "S1"])
        #expect(timeline.segments.allSatisfy { $0.endS > $0.startS })
    }

    @Test func fluidAudioRejectsUnsupportedSpeakerCountHint() async throws {
        let backend = FluidAudioDiarizer(configuration: .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            modelsRootURL: try temporaryDirectory(),
            outputRootURL: try temporaryDirectory(),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await backend.diarize(DiarizationRequest(
                audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav"),
                speakerCountHint: 2...3
            ))
            Issue.record("expected unsupported speaker count hint")
        } catch let error as DiarizationError {
            #expect(error == .unsupportedSpeakerCountHint)
        }
    }

    @Test func community1RunsPinnedTwoSpeakerFixture() async throws {
        let backend = Community1Diarizer()
        let result = try await backend.diarizeWithEvidence(DiarizationRequest(
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav"),
            speakerCountHint: 2...2
        ))
        let timeline = result.timeline
        let speakers = Set(timeline.segments.map(\.speaker))

        #expect(speakers.count == 2)
        #expect(timeline.segments.count > 0)
        #expect(timeline.segments == timeline.segments.sorted {
            if $0.startS != $1.startS { return $0.startS < $1.startS }
            if $0.endS != $1.endS { return $0.endS < $1.endS }
            return $0.speaker < $1.speaker
        })
        #expect(timeline.segments.allSatisfy { $0.startS >= 0 && $0.endS > $0.startS })
        #expect(result.rawJSON.starts(with: Data("{\n".utf8)))
        #expect(result.normalizationWarnings.count == 1)
        let warning = try #require(result.normalizationWarnings.first)
        #expect(warning.rawEndS == 28.972)
        #expect(warning.normalizedEndS == 28.8898125)
        #expect(abs(warning.deltaS - 0.0821875) < 0.000_001)
        let rawObject = try #require(JSONSerialization.jsonObject(with: result.rawJSON) as? [String: Any])
        let rawSegments = try #require(rawObject["segments"] as? [[String: Any]])
        let rawLast = try #require(rawSegments.last)
        #expect(rawLast["end"] as? Double == warning.rawEndS)
    }
}

private func writeFluidHarnessCopying(_ fixture: URL, in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("fluid-fixture-command.sh")
    let contents = """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '--output' ]; then
        cp '\(fixture.path)' "$2"
        exit 0
      fi
      shift
    done
    exit 64
    """
    try Data(contents.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

private enum FixtureError: Error {
    case missing(String)
}
