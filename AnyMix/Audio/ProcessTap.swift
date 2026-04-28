import CoreAudio
import AudioToolbox
import Foundation

@available(macOS 14.2, *)
final class ProcessTap {
    let pid: pid_t

    var targetVolume: Float = 1.0
    var isMuted: Bool = false

    var effectiveGain: Float {
        isMuted ? 0.0 : targetVolume
    }

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.anymix.tap", qos: .userInitiated)

    private var currentVolume: Float = 1.0
    private let rampTime: Float = 0.030

    init(pid: pid_t) {
        self.pid = pid
    }

    deinit {
        stop()
    }

    func start(objectID: AudioObjectID) throws {
        guard !isRunning else { return }

        // 1. Create tap description — exactly like FineTune
        let desc = CATapDescription(stereoMixdownOfProcesses: [objectID])
        desc.name = "AnyMix-\(pid)"
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true

        // 2. Create process tap
        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr else {
            throw TapError.createTapFailed(status)
        }
        self.tapID = newTapID

        // 3. Get default output device UID
        let outputUID = try getDefaultOutputDeviceUID()

        // 4. Create aggregate device — matching FineTune's config
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AnyMix-\(pid)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceClockDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: outputUID,
                    kAudioSubDeviceDriftCompensationKey as String: false
                ]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &newAggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.createAggregateFailed(status)
        }
        self.aggregateDeviceID = newAggregateID

        // 5. Wait for device to become alive (like FineTune's waitUntilReady)
        for _ in 0..<20 {
            if isDeviceAlive(newAggregateID) { break }
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }

        let sampleRate = getSampleRate(aggregateDeviceID)
        let rampCoefficient: Float = 1.0 - exp(-1.0 / (Float(sampleRate) * rampTime))

        // 6. Create IOProc with dispatch queue (like FineTune)
        var procID: AudioDeviceIOProcID?
        let tapSelf = Unmanaged.passUnretained(self).toOpaque()

        status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            queue
        ) { [rampCoefficient] _, inInputData, _, outOutputData, _ in
            let tap = Unmanaged<ProcessTap>.fromOpaque(tapSelf).takeUnretainedValue()
            let targetGain = tap.effectiveGain
            var currentVol = tap.currentVolume

            let inBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBufs = UnsafeMutableAudioBufferListPointer(outOutputData)

            let inCount = inBufs.count
            let outCount = outBufs.count

            // Buffer offset — tap input may be after device output buffers
            // (FineTune: inputIndex = inputBufferCount - outputBufferCount + outputIndex)
            let offset = inCount > outCount ? inCount - outCount : 0

            for outIdx in 0..<outCount {
                let inIdx = offset + outIdx
                let outBuf = outBufs[outIdx]
                guard let outData = outBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let outFrames = Int(outBuf.mDataByteSize) / MemoryLayout<Float>.size

                if inIdx < inCount,
                   let inData = inBufs[inIdx].mData?.assumingMemoryBound(to: Float.self) {
                    let inFrames = Int(inBufs[inIdx].mDataByteSize) / MemoryLayout<Float>.size
                    let count = min(outFrames, inFrames)

                    for f in 0..<count {
                        currentVol += (targetGain - currentVol) * rampCoefficient
                        var s = inData[f] * currentVol
                        if s > 1.0 { s = tanhf(s) }
                        else if s < -1.0 { s = -tanhf(-s) }
                        outData[f] = s
                    }
                    for f in count..<outFrames { outData[f] = 0 }
                } else {
                    memset(outBuf.mData, 0, Int(outBuf.mDataByteSize))
                }
            }

            tap.currentVolume = currentVol
        }

        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.createIOProcFailed(status)
        }
        self.ioProcID = procID

        // 7. Start
        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.startFailed(status)
        }

        isRunning = true
        AnyMixLogger.log("Tap running pid=\(pid) vol=\(targetVolume)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Helpers

    private func isDeviceAlive(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        return alive != 0
    }

    private func getDefaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { throw TapError.noOutputDevice }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid else { throw TapError.noOutputDevice }
        return cf.takeUnretainedValue() as String
    }

    private func getSampleRate(_ deviceID: AudioObjectID) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 44100.0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return sampleRate
    }

    enum TapError: Error, LocalizedError {
        case createTapFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case createIOProcFailed(OSStatus)
        case startFailed(OSStatus)
        case noOutputDevice

        var errorDescription: String? {
            switch self {
            case .createTapFailed(let s): return "Create tap failed (\(s))"
            case .createAggregateFailed(let s): return "Create aggregate failed (\(s))"
            case .createIOProcFailed(let s): return "Create IOProc failed (\(s))"
            case .startFailed(let s): return "Start failed (\(s))"
            case .noOutputDevice: return "No output device"
            }
        }
    }
}
