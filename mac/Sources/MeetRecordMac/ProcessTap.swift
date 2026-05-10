// ProcessTap.swift
//
// System-audio capture via Core Audio Process Tap + Aggregate Device.
//
// Adapted under MIT license from RecapAI/Recap:
//   https://github.com/RecapAI/Recap/blob/main/Recap/Audio/Capture/Tap/ProcessTap.swift
// Original copyright (c) 2025 Rawand Ahmed Shaswar. See NOTICE in repo root.
//
// Scope:
//   * M3:    system-wide tap (default, all output processes).
//   * M5:    per-app tap via bundle ID (`--system app:<bundle-id>`).
//
// The IO block hands buffers to a caller-supplied closure; this file does
// not concern itself with file output, mixing, or resampling.
//
// SPDX-License-Identifier: GPL-3.0-or-later (this adaptation)
// Original Recap source: MIT

import Foundation
import AudioToolbox
import CoreAudio
import OSLog

/// What sources to tap.
enum TapTarget: Equatable {
    /// All output processes ("system-wide"). Default.
    case systemWide
    /// Only the process whose `kAudioProcessPropertyBundleID` matches.
    /// Lookup is case-sensitive (matches macOS bundle-ID semantics).
    case bundleID(String)
}

@available(macOS 14.4, *)
final class ProcessTap {
    typealias IOBlockHandler = (AudioBufferList, AudioStreamBasicDescription) -> Void

    private let logger = Logger(subsystem: "tools.pretyflaco.meetrecordmac", category: "ProcessTap")
    private let queue = DispatchQueue(label: "tools.pretyflaco.meetrecordmac.processtap", qos: .userInitiated)

    private(set) var streamDescription: AudioStreamBasicDescription?

    private var tapID: AudioObjectID = .init(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = .init(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var ioHandler: IOBlockHandler?

    /// Activate a process tap (system-wide or per-app) and start delivering
    /// audio to `handler`. `handler` is called on a background queue; it
    /// must not block.
    func start(target: TapTarget = .systemWide, handler: @escaping IOBlockHandler) throws {
        self.ioHandler = handler

        // 1. Build the tap description. System-wide is "global tap with
        //    no exclusions"; per-app uses `stereoMixdownOfProcesses` with
        //    a single AudioObjectID resolved from the requested bundle ID.
        let tapDesc: CATapDescription
        switch target {
        case .systemWide:
            tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .bundleID(let bid):
            let pid = try Self.processObjectID(forBundleID: bid)
            tapDesc = CATapDescription(stereoMixdownOfProcesses: [pid])
        }
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        var tap: AUAudioObjectID = .init(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDesc, &tap)
        guard err == noErr else {
            throw ProcessTapError.coreAudio("AudioHardwareCreateProcessTap failed: \(err)")
        }
        self.tapID = tap

        // 2. Read the tap's stream format so the caller knows the sample rate
        //    + channel count without guessing.
        self.streamDescription = try readTapStreamDescription(tap)

        // 3. Build a private Aggregate Device that includes the system default
        //    output as its main subdevice and the tap as a sub-tap. This is
        //    Recap's pattern; it gives drift-compensated capture while playback
        //    continues on the user's speakers.
        let systemOutputID = try Self.defaultSystemOutputDevice()
        let outputUID = try Self.deviceUID(systemOutputID)
        let aggregateUID = UUID().uuidString

        let aggName: String
        switch target {
        case .systemWide: aggName = "MeetRecordMac-SystemTap"
        case .bundleID(let b): aggName = "MeetRecordMac-Tap-\(b)"
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                ]
            ],
        ]

        var aggDevice: AudioObjectID = .init(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggDevice)
        guard err == noErr else {
            throw ProcessTapError.coreAudio("AudioHardwareCreateAggregateDevice failed: \(err)")
        }
        self.aggregateDeviceID = aggDevice

        // 4. Wire an I/O proc and start. We capture self weakly so deallocation
        //    while the queue is mid-callback doesn't crash.
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggDevice, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self = self,
                  let handler = self.ioHandler,
                  let asbd = self.streamDescription else { return }
            handler(inInputData.pointee, asbd)
        }
        guard err == noErr, let procID = procID else {
            throw ProcessTapError.coreAudio("AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
        }
        self.deviceProcID = procID

        err = AudioDeviceStart(aggDevice, procID)
        guard err == noErr else {
            throw ProcessTapError.coreAudio("AudioDeviceStart failed: \(err)")
        }
    }

    /// Stop and tear down the tap + aggregate device.
    func stop() {
        if aggregateDeviceID != .init(kAudioObjectUnknown), let procID = deviceProcID {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.deviceProcID = nil
        }
        if aggregateDeviceID != .init(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            self.aggregateDeviceID = .init(kAudioObjectUnknown)
        }
        if tapID != .init(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
            self.tapID = .init(kAudioObjectUnknown)
        }
        self.ioHandler = nil
    }

    deinit { stop() }

    // MARK: - Private helpers (lifted from Recap's CoreAudioUtils)

    private func readTapStreamDescription(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard err == noErr else {
            throw ProcessTapError.coreAudio("Read tap format failed: \(err)")
        }
        return asbd
    }

    private static func defaultSystemOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceID: AudioObjectID = .init(kAudioObjectUnknown)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard err == noErr else {
            throw ProcessTapError.coreAudio("Read default system output failed: \(err)")
        }
        return deviceID
    }

    private static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let err = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid = uid else {
            throw ProcessTapError.coreAudio("Read device UID failed: \(err)")
        }
        return uid as String
    }

    // MARK: - Per-app lookup (M5)

    /// Walk `kAudioHardwarePropertyProcessObjectList` and return the
    /// AudioObjectID of the first process whose bundle ID matches
    /// `bundleID`. Throws `ProcessTapError.processNotFound` if no
    /// matching process is currently running with audio activity
    /// (Process Tap only knows about processes that have actually
    /// touched the audio HAL since boot — newly-launched apps that
    /// haven't played any audio yet may not appear here).
    static func processObjectID(forBundleID bundleID: String) throws -> AudioObjectID {
        let processes = try readProcessObjectList()
        for pid in processes {
            if let bid = try? readProcessBundleID(pid), bid == bundleID {
                return pid
            }
        }
        throw ProcessTapError.processNotFound(bundleID: bundleID)
    }

    private static func readProcessObjectList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard err == noErr else {
            throw ProcessTapError.coreAudio("process object list size query failed: \(err)")
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &ids
        )
        guard err == noErr else {
            throw ProcessTapError.coreAudio("process object list query failed: \(err)")
        }
        return ids
    }

    private static func readProcessBundleID(_ id: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let err = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let s = cfStr else {
            // Some process objects (e.g. coreaudiod itself, system
            // services) don't expose a bundle ID. Treat as no-match.
            throw ProcessTapError.coreAudio("process bundle ID read failed: \(err)")
        }
        return s as String
    }
}

enum ProcessTapError: Error, CustomStringConvertible {
    case coreAudio(String)
    case processNotFound(bundleID: String)

    var description: String {
        switch self {
        case .coreAudio(let s): return "CoreAudio error: \(s)"
        case .processNotFound(let bid):
            return "ProcessTap: no audio-active process found with bundle ID \(bid.debugDescription). " +
                   "Process Tap can only target processes that have already touched the audio HAL — " +
                   "make sure the app is running and has played at least one audio frame."
        }
    }
}
