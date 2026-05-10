// Devices.swift
//
// `meet-record-mac devices [--json]` — enumerate Core Audio input
// devices on the host. The output's `uid` field is the same value that
// `--mic <uid>` accepts in record mode, so a user (or the Python parent)
// can pipeline `devices --json` → pick a UID → pass it back as `--mic`.
//
// Implementation walks `kAudioHardwarePropertyDevices` from the system
// object. For each device we read:
//   - kAudioDevicePropertyDeviceUID    (string, stable across reboots)
//   - kAudioDevicePropertyDeviceNameCFString (human label)
//   - kAudioDevicePropertyStreams      (input scope) — non-empty means
//     the device exposes an input stream (i.e. is a mic-capable device).
//
// Devices with no input streams (pure outputs like AirPods) are skipped.
// The current default input device is flagged with `is_default: true`.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AudioToolbox
import CoreAudio

/// One row of `devices` output.
struct DeviceListing: Equatable, Encodable {
    /// Stable across reboots. This is what `--mic <uid>` accepts.
    let uid: String
    /// Human-readable name (e.g. "MacBook Pro Microphone").
    let name: String
    /// True iff this device is the current default input.
    let is_default: Bool
}

@available(macOS 14.4, *)
enum Devices {
    /// Enumerate input-capable devices. May throw if the system object
    /// query itself fails; an empty list (no inputs at all, very rare)
    /// is returned cleanly.
    static func listInputs() throws -> [DeviceListing] {
        let allDevices = try readAllDeviceIDs()
        let defaultInput = try? readDefaultInputDeviceID()
        var rows: [DeviceListing] = []
        for id in allDevices {
            guard hasInputStreams(deviceID: id) else { continue }
            guard let uid = try? readDeviceUID(id),
                  let name = try? readDeviceName(id) else { continue }
            let isDefault = (defaultInput == id)
            rows.append(DeviceListing(uid: uid, name: name, is_default: isDefault))
        }
        // Stable sort: default first, then alpha by name.
        rows.sort { lhs, rhs in
            if lhs.is_default != rhs.is_default { return lhs.is_default }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return rows
    }

    /// Render rows as the format expected by the chosen output mode.
    /// Returns the string ready to be written to stdout (terminated
    /// with a single newline).
    static func render(_ rows: [DeviceListing], json: Bool) -> String {
        if json {
            // We hand-format the JSON to keep field ordering stable
            // (uid, name, is_default) and avoid the `Encodable` default
            // alphabetic ordering quirks. Cheap; no dependency on
            // JSONEncoder's output_formatting.
            var s = "[\n"
            for (i, r) in rows.enumerated() {
                s += "  {\n"
                s += "    \"uid\": \(jsonString(r.uid)),\n"
                s += "    \"name\": \(jsonString(r.name)),\n"
                s += "    \"is_default\": \(r.is_default ? "true" : "false")\n"
                s += "  }"
                if i != rows.count - 1 { s += "," }
                s += "\n"
            }
            s += "]\n"
            return s
        } else {
            if rows.isEmpty {
                return "(no input devices found)\n"
            }
            // Two-column padded layout: "[default] name (uid)".
            var s = ""
            for r in rows {
                let prefix = r.is_default ? "* " : "  "
                s += "\(prefix)\(r.name)\n    \(r.uid)\n"
            }
            return s
        }
    }

    /// JSON-quote a string with the minimum escaping needed for the
    /// characters we expect to see in a UID or device name. AudioToolbox
    /// strings are CFString-safe; in practice only `"` and `\` need
    /// escaping for our render path. Quotes the result.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.asciiValue.map({ $0 < 0x20 }) ?? false {
                    out += String(format: "\\u%04x", c.asciiValue!)
                } else {
                    out.append(c)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Core Audio property helpers

    private static func readAllDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard err == noErr else {
            throw DevicesError.coreAudio("device list size query failed: \(err)")
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &ids
        )
        guard err == noErr else {
            throw DevicesError.coreAudio("device list query failed: \(err)")
        }
        return ids
    }

    private static func readDefaultInputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id
        )
        guard err == noErr else {
            throw DevicesError.coreAudio("default input device query failed: \(err)")
        }
        return id
    }

    /// Returns true iff the device exposes at least one input stream.
    private static func hasInputStreams(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard err == noErr else { return false }
        return dataSize > 0
    }

    private static func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        try readCFString(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func readDeviceName(_ deviceID: AudioObjectID) throws -> String {
        try readCFString(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func readCFString(
        _ id: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let err = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let s = cfStr else {
            throw DevicesError.coreAudio("CFString read failed: \(err)")
        }
        return s as String
    }
}

enum DevicesError: Error, CustomStringConvertible {
    case coreAudio(String)
    var description: String {
        switch self {
        case .coreAudio(let s): return "Devices: CoreAudio: \(s)"
        }
    }
}
