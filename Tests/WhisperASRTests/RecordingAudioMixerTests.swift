import XCTest
import AVFoundation
@testable import WhisperASR

final class RecordingAudioMixerTests: XCTestCase {
    func testMicrophoneOnlyTimelineSavesContinuousM4AIncludingPartialTail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var mixer = RecordingAudioMixer()
        // A short tone follows silence; there are deliberately no system buffers.
        let tone = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.2 }
        mixer.append(tone, at: 0.1, source: .microphone)
        let totalFrames = 12037
        while mixer.nextFrame < totalFrames {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            let position = mixer.nextFrame
            let samples = mixer.render(frameCount: min(960, totalFrames - position))
            let buffer = try XCTUnwrap(AudioRecorder.makeAudioBuffer(samples, frame: position))
            XCTAssertTrue(input.append(buffer), "\(String(describing: writer.error))")
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 48000)
        XCTAssertEqual(Double(file.length) / 48000, Double(totalFrames) / 48000, accuracy: 0.025)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let data = try XCTUnwrap(pcm.floatChannelData?[0])
        let peak = (4800..<min(9600, Int(pcm.frameLength))).map { abs(data[$0]) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
    }

    func testMicrophoneContinuesWhenSystemAudioStopsAndReturns() {
        var mixer = RecordingAudioMixer()
        let block = RecordingAudioMixer.blockSize
        mixer.append(Array(repeating: 0.2, count: block), at: 0, source: .system)
        mixer.append(Array(repeating: 0.3, count: block * 3), at: 0, source: .microphone)
        mixer.append(Array(repeating: 0.1, count: block), at: 0.04, source: .system)
        XCTAssertEqual(mixer.render(frameCount: block), Array(repeating: 0.5, count: block))
        XCTAssertEqual(mixer.render(frameCount: block), Array(repeating: 0.3, count: block))
        XCTAssertEqual(mixer.render(frameCount: block), Array(repeating: 0.4, count: block))
        XCTAssertEqual(mixer.render(frameCount: block), Array(repeating: 0, count: block))
    }

    func testArrivalOrderDoesNotChangeTimestampAlignment() {
        var mixer = RecordingAudioMixer()
        mixer.append([0.3, 0.4], at: 4.0 / 48000, source: .microphone)
        mixer.append([0.1, 0.2], at: 2.0 / 48000, source: .system)
        XCTAssertEqual(mixer.render(frameCount: 6), [0, 0, 0.1, 0.2, 0.3, 0.4])
    }

    func testLateAudioIsTrimmedInsteadOfMovingSpeechForward() {
        var mixer = RecordingAudioMixer()
        _ = mixer.render(frameCount: 4)
        mixer.append([0.1, 0.2, 0.3, 0.4], at: 2.0 / 48000, source: .microphone)
        mixer.append([0.9], at: 0, source: .system)
        XCTAssertEqual(mixer.render(frameCount: 4), [0.3, 0.4, 0, 0])
    }

    func testPreStartAudioAndFinalPartialBlock() {
        var mixer = RecordingAudioMixer()
        mixer.append([0.1, 0.2, 0.3, 0.4], at: -2.0 / 48000, source: .microphone)
        XCTAssertEqual(mixer.render(frameCount: 3), [0.3, 0.4, 0])
        XCTAssertEqual(mixer.nextFrame, 3)
    }

    func testOverlappingCallbacksFromOneSourceAreNotDoubled() {
        var mixer = RecordingAudioMixer()
        mixer.append([0.2, 0.2, 0.2], at: 0, source: .system)
        mixer.append([0.2, 0.2], at: 2.0 / 48000, source: .system)
        XCTAssertEqual(mixer.render(frameCount: 4), [0.2, 0.2, 0.2, 0.2])
    }

    func testLoudSimultaneousSourcesAreLimitedWithoutHardClipping() {
        var mixer = RecordingAudioMixer()
        mixer.append([0.8, 0.4, -0.8], at: 0, source: .system)
        mixer.append([0.8, 0.4, -0.8], at: 0, source: .microphone)
        let samples = mixer.render(frameCount: 3)
        XCTAssertEqual(samples[0], 0.98, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.49, accuracy: 0.0001)
        XCTAssertEqual(samples[2], -0.98, accuracy: 0.0001)
    }

    func testInvalidAndFarFutureTimestampsDoNotPolluteTimeline() {
        var mixer = RecordingAudioMixer()
        mixer.append([1], at: .nan, source: .system)
        mixer.append([1], at: .infinity, source: .microphone)
        mixer.append([1], at: 600, source: .microphone)
        mixer.append([.nan, .infinity, 0.2], at: 0, source: .system)
        XCTAssertEqual(mixer.render(frameCount: 3), [0, 0, 0.2])
    }
}
