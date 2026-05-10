// Permissions.swift
//
// `meet-record-mac probe-permissions` — report TCC status for the two
// permissions the recorder needs:
//
//   1. Microphone (`AVCaptureDevice.authorizationStatus(for: .audio)`)
//   2. System Audio Recording — the new TCC bucket macOS 14.4
//      introduced for Process Tap (kAudioHardwareCreateProcessTap). There
//      is **no public Apple API to query this status without consuming
//      it**; the only way to learn the result is to actually attempt to
//      create a tap. We therefore do exactly that, and tear it down
//      immediately. If the tap creation succeeds the permission is
//      granted; if it returns kAudioHardwareIllegalOperationError or
//      kAudio_NotPermittedError, the permission is denied (or has not
//      been prompted yet).
//
// Exit code:
//   0 — both permissions granted
//   1 — one or both denied / not-determined / restricted
//
// Output format (single line per permission, both human and machine
// parseable):
//
//   mic: granted
//   system_audio: granted
//   overall: ok
//
// or:
//
//   mic: denied
//   system_audio: not_determined
//   overall: blocked
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

@available(macOS 14.4, *)
enum Permissions {
    enum Status: String, Equatable {
        case granted          // permission affirmatively granted
        case denied           // user denied (or system policy blocks)
        case not_determined   // never been prompted
        case restricted       // parental controls / MDM
        case unknown          // probe failed in an unexpected way
    }

    struct Report: Equatable {
        let mic: Status
        let systemAudio: Status

        var allGranted: Bool { mic == .granted && systemAudio == .granted }
    }

    /// Run both probes and produce a report. Side-effects: the system-
    /// audio probe creates and immediately destroys a tap, which can
    /// trigger the TCC prompt on first use. The microphone probe does
    /// not prompt; it only reads the existing status.
    static func probe() -> Report {
        let mic = probeMic()
        let sys = probeSystemAudio()
        return Report(mic: mic, systemAudio: sys)
    }

    /// Render a probe report for stdout. Stable single-line key:value
    /// fields; the trailing `overall:` line is the one a shell script
    /// can `grep` for.
    static func render(_ r: Report) -> String {
        return """
        mic: \(r.mic.rawValue)
        system_audio: \(r.systemAudio.rawValue)
        overall: \(r.allGranted ? "ok" : "blocked")

        """
    }

    // MARK: - probes

    private static func probeMic() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .not_determined
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    /// Attempt to create + immediately destroy a system-wide Process
    /// Tap. Returns `.granted` on success. Distinguishes denied vs
    /// not_determined where possible from the OSStatus returned.
    ///
    /// `kAudioHardwareIllegalOperationError` (560226676 / 'what')
    /// indicates "we know about Process Tap but you can't use it" — TCC
    /// bucket for System Audio Recording is denied or not yet granted.
    /// Apple does not differentiate "denied" from "not yet prompted" via
    /// OSStatus. We surface it as `.denied` for the simplicity of "is
    /// it currently usable" — calling code that needs the not-determined
    /// case can re-run the probe after the user grants in System Settings.
    private static func probeSystemAudio() -> Status {
        // Build a no-op tap description identical to the one ProcessTap
        // uses in real recording. No process exclusion list = system-wide.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        var tapID: AUAudioObjectID = .init(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        if err == noErr {
            // Created OK — tear it down so we don't leak. The probe
            // itself proves the permission is granted.
            _ = AudioHardwareDestroyProcessTap(tapID)
            return .granted
        }
        // Treat any failure mode as "not currently usable". The user-
        // facing prescription is the same: System Settings → Privacy &
        // Security → System Audio Recording → enable for Terminal /
        // your shell.
        return .denied
    }
}
