import AVFAudio
import Foundation

enum RecordingStorageError: Error, LocalizedError {
    case outputAlreadyExists(URL)
    case invalidArtifactName(String)

    var errorDescription: String? {
        switch self {
        case let .outputAlreadyExists(url):
            appString("Maccheroni will not overwrite an existing recording artifact: \(url.lastPathComponent).")
        case let .invalidArtifactName(name):
            appString("The recording artifact name is unsafe: \(name).")
        }
    }
}

enum RecordingMixerError: Error, LocalizedError {
    case unreadableInput(URL)
    case unsupportedFormat(URL)
    case emptyInputs
    case outputUnreadable(URL)

    var errorDescription: String? {
        switch self {
        case let .unreadableInput(url):
            appString("Could not read recording artifact \(url.lastPathComponent).")
        case let .unsupportedFormat(url):
            appString("Recording artifact \(url.lastPathComponent) is not canonical 48 kHz mono PCM.")
        case .emptyInputs:
            appString("Both recording channels were empty; the combined recording was retained but cannot be transcribed.")
        case let .outputUnreadable(url):
            appString("The derived combined recording could not be read after writing: \(url.lastPathComponent).")
        }
    }
}

enum RecordingStorage {
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 1
    static let transcriptionFileName = "combined.wav"

    static var canonicalFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    static func createSessionDirectory(
        in root: URL,
        date: Date = Date(),
        identifier: UUID = UUID()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent(
            "recording-\(formatter.string(from: date))-\(identifier.uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    static func reserveNewFile(named name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty,
              !(name as NSString).isAbsolutePath,
              !name.split(separator: "/").contains("..")
        else {
            throw RecordingStorageError.invalidArtifactName(name)
        }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingStorageError.outputAlreadyExists(url)
        }
        do {
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                throw RecordingStorageError.outputAlreadyExists(url)
            }
            throw error
        }
        return url
    }

    static func createAudioFile(named name: String, in directory: URL) throws -> (URL, AVAudioFile) {
        let url = try reserveNewFile(named: name, in: directory)
        let file = try AVAudioFile(
            forWriting: url,
            settings: canonicalFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        return (url, file)
    }
}

enum RecordingMixer {
    static func mix(
        microphoneURL: URL,
        systemAudioURL: URL,
        outputURL: URL
    ) throws {
        let microphone = try audioFile(at: microphoneURL)
        let systemAudio = try audioFile(at: systemAudioURL)
        try validateCanonicalFormat(microphone, at: microphoneURL)
        try validateCanonicalFormat(systemAudio, at: systemAudioURL)
        let frameCount = max(microphone.length, systemAudio.length)
        guard frameCount > 0 else { throw RecordingMixerError.emptyInputs }

        let outputDirectory = outputURL.deletingLastPathComponent()
        let reserved = try RecordingStorage.reserveNewFile(
            named: outputURL.lastPathComponent,
            in: outputDirectory
        )
        try mixIntoReservedFile(
            microphone: microphone,
            systemAudio: systemAudio,
            frameCount: frameCount,
            outputURL: reserved
        )
    }

    private static func mixIntoReservedFile(
        microphone: AVAudioFile,
        systemAudio: AVAudioFile,
        frameCount: AVAudioFramePosition,
        outputURL: URL
    ) throws {
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: RecordingStorage.canonicalFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let blockSize: AVAudioFrameCount = 8_192
        var written: AVAudioFramePosition = 0

        while written < frameCount {
            let requested = min(blockSize, AVAudioFrameCount(frameCount - written))
            let microphoneBuffer = try nextBuffer(from: microphone, frameCount: requested)
            let systemBuffer = try nextBuffer(from: systemAudio, frameCount: requested)
            guard let mixed = AVAudioPCMBuffer(
                pcmFormat: RecordingStorage.canonicalFormat,
                frameCapacity: requested
            ), let mixedSamples = mixed.floatChannelData?[0]
            else {
                throw RecordingMixerError.outputUnreadable(outputURL)
            }
            mixed.frameLength = requested
            let microphoneSamples = microphoneBuffer.floatChannelData?[0]
            let systemSamples = systemBuffer.floatChannelData?[0]
            for index in 0 ..< Int(requested) {
                let microphoneSample = index < Int(microphoneBuffer.frameLength)
                    ? microphoneSamples?[index] ?? 0
                    : 0
                let systemSample = index < Int(systemBuffer.frameLength)
                    ? systemSamples?[index] ?? 0
                    : 0
                if microphoneSample != 0, systemSample != 0 {
                    mixedSamples[index] = (microphoneSample + systemSample) * 0.5
                } else {
                    mixedSamples[index] = microphoneSample + systemSample
                }
            }
            try output.write(from: mixed)
            written += AVAudioFramePosition(requested)
        }
        output.close()

        let verification = try AVAudioFile(forReading: outputURL)
        guard verification.length > 0 else {
            throw RecordingMixerError.outputUnreadable(outputURL)
        }
    }

    private static func audioFile(at url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw RecordingMixerError.unreadableInput(url)
        }
    }

    private static func validateCanonicalFormat(_ file: AVAudioFile, at url: URL) throws {
        let format = file.processingFormat
        guard format.sampleRate == RecordingStorage.sampleRate,
              format.channelCount == RecordingStorage.channelCount,
              format.commonFormat == .pcmFormatFloat32
        else {
            throw RecordingMixerError.unsupportedFormat(url)
        }
    }

    private static func nextBuffer(
        from file: AVAudioFile,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: RecordingStorage.canonicalFormat,
            frameCapacity: frameCount
        ) else {
            throw RecordingMixerError.outputUnreadable(file.url)
        }
        let remaining = max(0, file.length - file.framePosition)
        if remaining > 0 {
            try file.read(
                into: buffer,
                frameCount: min(frameCount, AVAudioFrameCount(remaining))
            )
        }
        return buffer
    }
}
