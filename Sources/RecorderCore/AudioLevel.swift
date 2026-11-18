import Accelerate
import CoreMedia

public enum AudioLevel {
    /// RMS of an LPCM buffer mapped to 0...1 (-60 dBFS → 0, 0 dBFS → 1). Handles Float32 and Int16.
    public static func normalizedRMS(_ buffer: CMSampleBuffer) -> Float {
        guard let asbd = buffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var sumOfSquares: Float = 0
        var count = 0

        try? buffer.withAudioBufferList { list, _ in
            for audioBuffer in list {
                guard let data = audioBuffer.mData else { continue }
                if isFloat && asbd.mBitsPerChannel == 32 {
                    let n = Int(audioBuffer.mDataByteSize) / 4
                    var ms: Float = 0
                    vDSP_measqv(data.assumingMemoryBound(to: Float.self), 1, &ms, vDSP_Length(n))
                    sumOfSquares += ms * Float(n); count += n
                } else if !isFloat && asbd.mBitsPerChannel == 16 {
                    let n = Int(audioBuffer.mDataByteSize) / 2
                    let p = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<n { let s = Float(p[i]) / 32768; sumOfSquares += s * s }
                    count += n
                }
            }
        }
        guard count > 0 else { return 0 }
        let db = 20 * log10(max(sqrt(sumOfSquares / Float(count)), 1e-6))
        return max(0, min(1, (db + 60) / 60))
    }
}
