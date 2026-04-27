import CoreAudio
import AudioToolbox
import Foundation

/// Manages a single audio tap on a group of related processes (e.g. all Chrome helpers).
/// Creates a CATapDescription with ALL process IDs, so one slider controls all of them.
@available(macOS 14.2, *)
final class ProcessTap {
    let bundleID: String

    /// Target volume (0.0 = silent, 1.0 = unity).
    var targetVolume: Float = 1.0

    /// Whether this tap is muted.
    var isMuted: Bool = false

    /// Effective gain applied (considering mute state).
    var effectiveGain: Float {
        isMuted ? 0.0 : targetVolume
    }

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    // Volume ramping state (accessed from audio thread)
    private var currentVolume: Float = 1.0
    private let rampTime: Float = 0.030 // 30ms ramp to avoid clicks

    init(bundleID: String) {
        self.bundleID = bundleID
    }

    deinit {
        stop()
    }

    /// Start tapping all processes in the group.
    func start(objectIDs: [AudioObjectID]) throws {
        guard !isRunning, !objectIDs.isEmpty else { return }

        // Step 1: Create tap description with ALL process IDs
        let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        desc.name = "AnyMix-\(bundleID)"
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        // Step 2: Create process tap
        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr else {
            throw TapError.createTapFailed(status)
        }
        self.tapID = newTapID

        // Step 3: Get default output device UID
        let outputUID = try getDefaultOutputDeviceUID()

        // Step 4: Create aggregate device
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AnyMix-\(bundleID)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
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

        // Step 5: Get sample rate for ramp coefficient
        let sampleRate = getSampleRate(aggregateDeviceID)
        let rampCoefficient: Float = 1.0 - exp(-1.0 / (Float(sampleRate) * rampTime))

        // Step 6: Create IOProc
        var procID: AudioDeviceIOProcID?
        let tapSelf = Unmanaged.passUnretained(self).toOpaque()

        status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { [rampCoefficient] _, inInputData, _, outOutputData, _ in
            let tap = Unmanaged<ProcessTap>.fromOpaque(tapSelf).takeUnretainedValue()

            let targetGain = tap.effectiveGain
            var currentVol = tap.currentVolume

            let inputBufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            let outputBufferList = UnsafeMutableAudioBufferListPointer(outOutputData)

            for i in 0..<min(inputBufferList.count, outputBufferList.count) {
                let inputBuffer = inputBufferList[i]
                let outputBuffer = outputBufferList[i]

                guard let inData = inputBuffer.mData?.assumingMemoryBound(to: Float.self),
                      let outData = outputBuffer.mData?.assumingMemoryBound(to: Float.self)
                else { continue }

                let frameCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

                for frame in 0..<frameCount {
                    currentVol += (targetGain - currentVol) * rampCoefficient
                    outData[frame] = inData[frame] * currentVol
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

        // Step 7: Start
        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.startFailed(status)
        }

        isRunning = true
    }

    /// Stop the tap and clean up all resources in reverse order.
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
        guard status == noErr else {
            throw TapError.noOutputDevice
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid else {
            throw TapError.noOutputDevice
        }
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

    // MARK: - Errors

    enum TapError: Error, LocalizedError {
        case createTapFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case createIOProcFailed(OSStatus)
        case startFailed(OSStatus)
        case noOutputDevice

        var errorDescription: String? {
            switch self {
            case .createTapFailed(let s): return "Failed to create process tap (OSStatus: \(s))"
            case .createAggregateFailed(let s): return "Failed to create aggregate device (OSStatus: \(s))"
            case .createIOProcFailed(let s): return "Failed to create IOProc (OSStatus: \(s))"
            case .startFailed(let s): return "Failed to start audio device (OSStatus: \(s))"
            case .noOutputDevice: return "No default output device found"
            }
        }
    }
}
