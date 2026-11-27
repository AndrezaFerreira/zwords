import AVFoundation
import CoreMedia

/// Converts ReplayKit / Core Media audio into mono Float32 PCM buffers.
/// ReplayKit app audio is frequently big-endian, interleaved Int16, which
/// AVAudioFormat cannot describe directly, so the conversion is done by hand.
enum SampleBufferAudio {
    static func monoBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0 else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard bits == 16 || bits == 32 else { return nil }
        let bytesPerSample = bits / 8

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: asbd.mSampleRate,
                                          channels: 1,
                                          interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = output.floatChannelData?[0]
        else { return nil }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let list = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)

        @inline(__always)
        func sample(_ raw: UnsafeRawPointer, _ index: Int) -> Float {
            let offset = index * bytesPerSample
            if bits == 16 {
                var value = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                if isBigEndian { value = value.byteSwapped }
                return Float(Int16(bitPattern: value)) / 32768
            }
            var value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            if isBigEndian { value = value.byteSwapped }
            if isFloat { return Float(bitPattern: value) }
            return Float(Int32(bitPattern: value)) / 2_147_483_648
        }

        let frames = Int(frameCount)
        let scale = 1 / Float(channels)
        if isNonInterleaved {
            for frame in 0..<frames { destination[frame] = 0 }
            for buffer in buffers.prefix(channels) {
                guard let data = buffer.mData else { continue }
                let available = Int(buffer.mDataByteSize) / bytesPerSample
                for frame in 0..<min(frames, available) {
                    destination[frame] += sample(data, frame) * scale
                }
            }
        } else {
            guard let data = buffers.first?.mData else { return nil }
            let available = Int(buffers[0].mDataByteSize) / (bytesPerSample * channels)
            let usable = min(frames, available)
            for frame in 0..<usable {
                var sum: Float = 0
                for channel in 0..<channels { sum += sample(data, frame * channels + channel) }
                destination[frame] = sum * scale
            }
            for frame in usable..<frames { destination[frame] = 0 }
        }
        output.frameLength = AVAudioFrameCount(frames)
        return output
    }
}
