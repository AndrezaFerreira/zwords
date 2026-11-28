import AVFoundation
import CoreMedia
import XCTest
@testable import ZWords

final class AudioConversionTests: XCTestCase {
    /// ReplayKit delivers app audio as big-endian interleaved Int16; make sure it is decoded correctly.
    func testBigEndianInterleavedStereoInt16() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        let samples: [Int16] = [16384, 16384, -16384, -16384, 0, 0, 32767, -32768]
        let sampleBuffer = try makeSampleBuffer(asbd: &asbd, bytes: samples.map { $0.bigEndian }, frames: 4)

        let pcm = try XCTUnwrap(SampleBufferAudio.monoBuffer(from: sampleBuffer))
        XCTAssertEqual(pcm.format.sampleRate, 44_100)
        XCTAssertEqual(pcm.format.channelCount, 1)
        XCTAssertEqual(pcm.frameLength, 4)
        let data = try XCTUnwrap(pcm.floatChannelData?[0])
        XCTAssertEqual(data[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(data[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(data[2], 0, accuracy: 0.0001)
        XCTAssertEqual(data[3], 0, accuracy: 0.001)
    }

    func testLittleEndianMonoFloat() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        let samples: [Float] = [0.25, -0.75, 1]
        let sampleBuffer = try makeSampleBuffer(asbd: &asbd, bytes: samples, frames: 3)
        let pcm = try XCTUnwrap(SampleBufferAudio.monoBuffer(from: sampleBuffer))
        let data = try XCTUnwrap(pcm.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: data, count: 3)), samples)
    }

    private func makeSampleBuffer<T>(asbd: inout AudioStreamBasicDescription, bytes: [T], frames: Int) throws -> CMSampleBuffer {
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                                                      layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                      extensions: nil, formatDescriptionOut: &format), noErr)
        let length = bytes.count * MemoryLayout<T>.stride
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                          blockLength: length, blockAllocator: nil,
                                                          customBlockSource: nil, offsetToData: 0,
                                                          dataLength: length, flags: 0, blockBufferOut: &block), noErr)
        let blockBuffer = try XCTUnwrap(block)
        bytes.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                              offsetIntoDestination: 0, dataLength: length)
        }
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: try XCTUnwrap(format),
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer), noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
