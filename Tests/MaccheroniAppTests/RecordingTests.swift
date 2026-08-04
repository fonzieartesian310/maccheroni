import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import MaccheroniApp

struct RecordingTests {
    @Test
    func recordingSessionCreatesNewDirectoryAndRefusesArtifactOverwrite() throws {
        let root = try temporaryDirectory()
        let timestamp = Date(timeIntervalSince1970: 1_722_686_400)
        let identifier = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let session = try RecordingStorage.createSessionDirectory(
            in: root,
            date: timestamp,
            identifier: identifier
        )
        #expect(session.lastPathComponent == "recording-20240803-120000-12345678-1234-1234-1234-123456789abc")

        let artifact = try RecordingStorage.reserveNewFile(named: "microphone.caf", in: session)
        try Data("original".utf8).write(to: artifact)
        #expect(throws: RecordingStorageError.self) {
            try RecordingStorage.reserveNewFile(named: "microphone.caf", in: session)
        }
        #expect(try Data(contentsOf: artifact) == Data("original".utf8))
        #expect(throws: RecordingStorageError.self) {
            try RecordingStorage.reserveNewFile(named: "../unsafe.caf", in: session)
        }
    }

    @Test
    func mixerCreatesReadableCombinedFileWithoutChangingSources() throws {
        let directory = try temporaryDirectory()
        let microphoneURL = try syntheticAudio(
            in: directory,
            name: "microphone.caf",
            frequency: 440
        )
        let systemURL = try syntheticAudio(
            in: directory,
            name: "system-audio.caf",
            frequency: 660
        )
        let microphoneHash = try sha256(of: microphoneURL)
        let systemHash = try sha256(of: systemURL)
        let combinedURL = directory.appendingPathComponent(RecordingStorage.transcriptionFileName)

        try RecordingMixer.mix(
            microphoneURL: microphoneURL,
            systemAudioURL: systemURL,
            outputURL: combinedURL
        )

        let combined = try AVAudioFile(forReading: combinedURL)
        #expect(combinedURL.pathExtension == "wav")
        #expect(combined.length > 0)
        #expect(combined.processingFormat.sampleRate == RecordingStorage.sampleRate)
        #expect(combined.processingFormat.channelCount == RecordingStorage.channelCount)
        #expect(try sha256(of: microphoneURL) == microphoneHash)
        #expect(try sha256(of: systemURL) == systemHash)
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @Test
    func timelineWriterPreservesDelayedChannelStartAndMixerAlignment() throws {
        let directory = try temporaryDirectory()
        let microphoneURL = try timelineAudio(
            in: directory,
            name: "microphone.caf",
            startFrame: 0,
            frequency: 440
        )
        let systemURL = try timelineAudio(
            in: directory,
            name: "system-audio.caf",
            startFrame: 2_400,
            frequency: 660
        )
        let microphoneHash = try sha256(of: microphoneURL)
        let systemHash = try sha256(of: systemURL)

        let delayedSystem = try AVAudioFile(forReading: systemURL)
        #expect(delayedSystem.length == 7_200)
        let delayedSamples = try readSamples(from: delayedSystem)
        #expect(delayedSamples[..<2_400].allSatisfy { $0 == 0 })
        #expect(delayedSamples[2_400...].contains { abs($0) > 0.05 })

        let combinedURL = directory.appendingPathComponent(RecordingStorage.transcriptionFileName)
        try RecordingMixer.mix(
            microphoneURL: microphoneURL,
            systemAudioURL: systemURL,
            outputURL: combinedURL
        )
        let combined = try AVAudioFile(forReading: combinedURL)
        #expect(combined.length == 7_200)
        #expect(try sha256(of: microphoneURL) == microphoneHash)
        #expect(try sha256(of: systemURL) == systemHash)
    }

    @Test
    func mixerDoesNotReserveDerivedFileWhenBothPreservedChannelsAreEmpty() throws {
        let directory = try temporaryDirectory()
        let (microphoneURL, microphone) = try RecordingStorage.createAudioFile(
            named: "microphone.caf",
            in: directory
        )
        let (systemURL, systemAudio) = try RecordingStorage.createAudioFile(
            named: "system-audio.caf",
            in: directory
        )
        microphone.close()
        systemAudio.close()
        let microphoneHash = try sha256(of: microphoneURL)
        let systemHash = try sha256(of: systemURL)
        let combinedURL = directory.appendingPathComponent(RecordingStorage.transcriptionFileName)

        #expect(throws: RecordingMixerError.self) {
            try RecordingMixer.mix(
                microphoneURL: microphoneURL,
                systemAudioURL: systemURL,
                outputURL: combinedURL
            )
        }

        #expect(!FileManager.default.fileExists(atPath: combinedURL.path))
        #expect(try sha256(of: microphoneURL) == microphoneHash)
        #expect(try sha256(of: systemURL) == systemHash)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MaccheroniRecordingTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func syntheticAudio(in directory: URL, name: String, frequency: Double) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let format = RecordingStorage.canonicalFormat
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frames: AVAudioFrameCount = 4_800
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let samples = buffer.floatChannelData?[0]
    else {
        fatalError("Could not allocate synthetic PCM fixture")
    }
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        samples[index] = Float(sin(2 * .pi * frequency * Double(index) / RecordingStorage.sampleRate) * 0.1)
    }
    try file.write(from: buffer)
    return url
}

private func timelineAudio(
    in directory: URL,
    name: String,
    startFrame: AVAudioFramePosition,
    frequency: Double
) throws -> URL {
    let (url, file) = try RecordingStorage.createAudioFile(named: name, in: directory)
    let writer = TimelineAudioWriter(file: file)
    try writer.append(syntheticBuffer(frequency: frequency), at: startFrame)
    writer.finish()
    return url
}

private func syntheticBuffer(frequency: Double) throws -> AVAudioPCMBuffer {
    let frames: AVAudioFrameCount = 4_800
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: RecordingStorage.canonicalFormat,
        frameCapacity: frames
    ), let samples = buffer.floatChannelData?[0]
    else {
        throw RecordingError.captureFailed("Could not allocate synthetic PCM fixture")
    }
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        samples[index] = Float(
            sin(2 * .pi * frequency * Double(index) / RecordingStorage.sampleRate) * 0.1
        )
    }
    return buffer
}

private func readSamples(from file: AVAudioFile) throws -> [Float] {
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: RecordingStorage.canonicalFormat,
        frameCapacity: frameCount
    ), let samples = buffer.floatChannelData?[0]
    else {
        throw RecordingError.captureFailed("Could not allocate readback PCM fixture")
    }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
}

private func sha256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
}
