import AVFoundation
import Darwin
import Foundation
import MaccheroniCore

public enum VoiceActivityKind: String, Codable, Equatable, Sendable {
    case speech
    case silence
}

public struct VoiceActivityRegion: Codable, Equatable, Sendable {
    public var startS: Double
    public var endS: Double
    public var kind: VoiceActivityKind

    public init(startS: Double, endS: Double, kind: VoiceActivityKind) {
        self.startS = startS
        self.endS = endS
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case startS = "start_s"
        case endS = "end_s"
    }
}

public struct VoiceActivityMap: Codable, Equatable, Sendable {
    public var durationS: Double
    public var regions: [VoiceActivityRegion]

    public init(durationS: Double, regions: [VoiceActivityRegion]) throws {
        guard durationS >= 0 else { throw VoiceActivityError.invalidMap("duration is negative") }
        var previousEnd = 0.0
        for region in regions {
            guard region.startS >= 0, region.endS > region.startS, region.endS <= durationS + 0.01 else {
                throw VoiceActivityError.invalidMap("region is outside the input duration")
            }
            guard region.startS >= previousEnd else {
                throw VoiceActivityError.invalidMap("regions overlap or are unsorted")
            }
            previousEnd = region.endS
        }
        self.durationS = durationS
        self.regions = regions
    }

    public var silenceRegions: [VoiceActivityRegion] {
        regions.filter { $0.kind == .silence }
    }
}

public protocol VoiceActivityDetecting: Sendable {
    func detect(audioURL: URL) async throws -> VoiceActivityMap
}

public enum VoiceActivityError: Error, Equatable, Sendable {
    case speechSileroUnavailable(executableURL: URL, modelCacheURL: URL)
    case timedOut(timeoutS: TimeInterval)
    case executionFailed(exitCode: Int32, message: String)
    case invalidOutput(String)
    case invalidMap(String)
}

/// The pinned local CoreML model selected by `speech vad-stream --engine coreml` in speech 0.0.23.
public struct SileroVADProvenance: Equatable, Sendable {
    public static let hfModelID = "aufklarer/Silero-VAD-v6.2.1-CoreML"
    public static let revision = "523876545a57961474fee9df913e833e130560b8"
    public static let quantization = "coreml-float16"

    public init() {}

    public var model: ModelDescriptor {
        ModelDescriptor(
            role: .vad,
            hfModelID: Self.hfModelID,
            revision: Self.revision,
            quantization: Self.quantization
        )
    }
}

/// Executes the installed `speech vad-stream` Silero VAD path. It never substitutes an energy VAD.
public struct SpeechSileroVADAdapter: VoiceActivityDetecting, Sendable {
    public let executableURL: URL
    public let modelCacheURL: URL
    public let revisionMarkerURL: URL
    public let provenance: SileroVADProvenance
    public let runtime: BackendDescriptor
    public let timeoutS: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/speech"),
        modelCacheURL: URL = Self.defaultModelCacheURL(),
        revisionMarkerURL: URL = Self.defaultRevisionMarkerURL(),
        runtime: BackendDescriptor = BackendDescriptor(name: "speech", version: "0.0.23"),
        timeoutS: TimeInterval = 300,
        provenance: SileroVADProvenance = .init()
    ) {
        self.executableURL = executableURL
        self.modelCacheURL = modelCacheURL
        self.revisionMarkerURL = revisionMarkerURL
        self.runtime = runtime
        self.timeoutS = timeoutS
        self.provenance = provenance
    }

    public static func defaultModelCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/qwen3-speech/models/aufklarer")
            .appendingPathComponent("Silero-VAD-v6.2.1-CoreML/silero_vad.mlmodelc")
    }

    public static func defaultRevisionMarkerURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--aufklarer--Silero-VAD-v6.2.1-CoreML")
            .appendingPathComponent("refs/main")
    }

    public func detect(audioURL: URL) async throws -> VoiceActivityMap {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: executableURL.path),
                fileManager.fileExists(atPath: modelCacheURL.path),
                let cachedRevision = try? String(contentsOf: revisionMarkerURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                cachedRevision == provenance.model.revision else {
            throw VoiceActivityError.speechSileroUnavailable(
                executableURL: executableURL,
                modelCacheURL: modelCacheURL
            )
        }

        let process = Process()
        let captures = try ProcessCaptureFiles.create()
        defer { captures.remove() }
        process.executableURL = executableURL
        process.arguments = [
            "vad-stream", audioURL.path,
            "--engine", "coreml",
            "--model", provenance.model.hfModelID,
            "--json",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["HF_HUB_OFFLINE": "1"],
            uniquingKeysWith: { _, offlineValue in offlineValue }
        )
        process.standardOutput = captures.standardOutput
        process.standardError = captures.standardError
        try process.run()
        guard waitForExit(process, timeoutS: timeoutS) else {
            terminate(process)
            throw VoiceActivityError.timedOut(timeoutS: timeoutS)
        }
        try captures.closeForReading()

        let stderr = String(data: try Data(contentsOf: captures.standardErrorURL), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw VoiceActivityError.executionFailed(
                exitCode: process.terminationStatus,
                message: stderr
            )
        }
        let outputText = String(data: try Data(contentsOf: captures.standardOutputURL), encoding: .utf8) ?? ""
        do {
            let speech = try JSONDecoder().decode(
                [SpeechInterval].self,
                from: try jsonArrayData(from: outputText)
            )
            let input = try AVAudioFile(forReading: audioURL)
            let durationS = Double(input.length) / input.processingFormat.sampleRate
            return try makeActivityMap(speech: speech, durationS: durationS)
        } catch {
            if let voiceActivityError = error as? VoiceActivityError {
                throw voiceActivityError
            }
            throw VoiceActivityError.invalidOutput(
                "speech vad-stream did not emit valid Silero JSON: \(error)"
            )
        }
    }

    private func jsonArrayData(from output: String) throws -> Data {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let arrayStart = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[" }) else {
            throw VoiceActivityError.invalidOutput("No JSON array found in speech output.")
        }
        return Data(lines[arrayStart...].joined(separator: "\n").utf8)
    }

    private func waitForExit(_ process: Process, timeoutS: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeoutS))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func terminate(_ process: Process) {
        process.terminate()
        if waitForExit(process, timeoutS: 0.25) { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, timeoutS: 0.25)
    }

    private func makeActivityMap(
        speech: [SpeechInterval],
        durationS: Double
    ) throws -> VoiceActivityMap {
        var regions: [VoiceActivityRegion] = []
        var cursor = 0.0
        for interval in speech {
            guard interval.start >= cursor - 0.000_001,
                    interval.end > interval.start,
                    interval.end <= durationS + 0.01 else {
                throw VoiceActivityError.invalidOutput("Speech intervals are unsorted, overlapping, or outside audio duration.")
            }
            let start = max(0, interval.start)
            let end = min(durationS, interval.end)
            if start > cursor {
                regions.append(VoiceActivityRegion(startS: cursor, endS: start, kind: .silence))
            }
            regions.append(VoiceActivityRegion(startS: start, endS: end, kind: .speech))
            cursor = end
        }
        if cursor < durationS {
            regions.append(VoiceActivityRegion(startS: cursor, endS: durationS, kind: .silence))
        }
        return try VoiceActivityMap(durationS: durationS, regions: regions)
    }

    private struct SpeechInterval: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
    }
}

private final class ProcessCaptureFiles: @unchecked Sendable {
    let standardOutputURL: URL
    let standardErrorURL: URL
    let standardOutput: FileHandle
    let standardError: FileHandle

    private init(
        standardOutputURL: URL,
        standardErrorURL: URL,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.standardOutputURL = standardOutputURL
        self.standardErrorURL = standardErrorURL
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    static func create() throws -> ProcessCaptureFiles {
        let directory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString.lowercased()
        let standardOutputURL = directory.appendingPathComponent("maccheroni-vad-\(identifier).stdout")
        let standardErrorURL = directory.appendingPathComponent("maccheroni-vad-\(identifier).stderr")
        guard FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil),
                FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil) else {
            throw VoiceActivityError.invalidOutput("Could not create VAD process capture files.")
        }
        return try ProcessCaptureFiles(
            standardOutputURL: standardOutputURL,
            standardErrorURL: standardErrorURL,
            standardOutput: FileHandle(forWritingTo: standardOutputURL),
            standardError: FileHandle(forWritingTo: standardErrorURL)
        )
    }

    func closeForReading() throws {
        try standardOutput.close()
        try standardError.close()
    }

    func remove() {
        try? standardOutput.close()
        try? standardError.close()
        try? FileManager.default.removeItem(at: standardOutputURL)
        try? FileManager.default.removeItem(at: standardErrorURL)
    }
}
