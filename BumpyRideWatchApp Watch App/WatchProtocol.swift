// WatchProtocol.swift
//
// Shared message types between the iOS BumpyRide app and the
// BumpyRideWatchApp companion watchOS app.
//
// ╔══════════════════════════════════════════════════════════════════╗
// ║ ⚠️  THIS FILE EXISTS IN TWO LOCATIONS                            ║
// ║                                                                  ║
// ║   BumpyRide/WatchProtocol.swift                  (iOS target)    ║
// ║   BumpyRideWatchApp Watch App/WatchProtocol.swift (watch target) ║
// ║                                                                  ║
// ║ Keep them BYTE-FOR-BYTE IDENTICAL.  When editing one, copy the   ║
// ║ entire file to the other.  A grep across both should always show ║
// ║ the same content.                                                ║
// ║                                                                  ║
// ║ This duplication is the v1 trade-off for keeping the targets     ║
// ║ self-contained with synchronized groups.  Once shared code grows ║
// ║ past ~3 files, promote to a local Swift Package.                 ║
// ╚══════════════════════════════════════════════════════════════════╝

import Foundation

/// Snapshot of recorder state pushed from iOS to the watch (~1 Hz via
/// `WCSession.updateApplicationContext`).  Watch UI renders directly
/// from the latest snapshot — there's no per-tick computation on the
/// watch side, just display.
///
/// All fields are populated even when not actively recording (state ==
/// .idle), with zero values, so the watch never has to deal with
/// optionals.  Equatable + Sendable so the watch side can drive a
/// SwiftUI `@Observable` cleanly.
struct WatchSnapshot: Codable, Equatable, Sendable {
    /// Recorder lifecycle state mirrored from iOS's `RideRecorder.State`.
    /// Re-declared here (rather than imported) because the watch target
    /// doesn't have access to the iOS types, and a wire-format enum is
    /// what we'd want anyway for forward compatibility.
    enum RecorderState: String, Codable, Sendable {
        case idle
        case recording
        case paused
        case finished
    }

    let state: RecorderState
    /// Seconds since ride start.  Watch can display this directly as
    /// HH:MM:SS without having to know iOS's `startedAt` timestamp.
    /// Updated at the snapshot's emission time; watch can extrapolate
    /// between snapshots if smooth display is wanted.
    let elapsedSeconds: TimeInterval
    let distanceMeters: Double
    /// Most recent bumpiness sample (live RMS).  Useful for a real-time
    /// readout if we ever want one; the page 2/3 carousel uses max + avg
    /// instead per the v1.6 design.
    let currentBumpiness: Double
    let maxBumpiness: Double
    let averageBumpiness: Double
    /// Set true by iOS after a save initiated from the watch's Stop
    /// command has completed and persisted.  Watch uses it to drive the
    /// "Saved" toast and then return to idle.  Default false.
    let pendingSaveAcknowledged: Bool

    /// Sentinel "nothing happening" snapshot.  Watch UI shows this on
    /// first launch before any real snapshot has arrived.
    static let idle = WatchSnapshot(
        state: .idle,
        elapsedSeconds: 0,
        distanceMeters: 0,
        currentBumpiness: 0,
        maxBumpiness: 0,
        averageBumpiness: 0,
        pendingSaveAcknowledged: false
    )
}

/// Commands sent watch → iOS.  Encoded with associated values (e.g.
/// `.stop(autoSave: true)`) so the wire format carries everything the
/// iOS side needs without ambiguity.  Sendable + Codable for both
/// WCSession transports (`sendMessage` real-time and
/// `transferUserInfo` queued fallback).
enum WatchCommand: Codable, Equatable, Sendable {
    /// Connectivity health check.  Round-trip reply confirms iOS is
    /// reachable.  Used by the watch's session manager to drive the
    /// "Phone connected ✓ / ✗" status.
    case ping
    /// User-tapped "Pause" on the watch.
    case pause
    /// User-tapped "Resume" on the watch (from a paused state).
    case resume
    /// User-tapped "Stop".  `autoSave: true` means iOS should run the
    /// full finalize-and-save flow with default title + auto-detected
    /// pocket mode.  `autoSave: false` (future use) would leave iOS in
    /// `.finished` for the user to handle on the phone.  v1.6 design
    /// always sends `true`.
    case stop(autoSave: Bool)
    /// User-tapped the close-call button.  iOS logs at its own current
    /// GPS location — the watch doesn't have to know coordinates.
    case closeCall
}

/// Dictionary-keyed wrappers for shoving Codable payloads through
/// `WCSession`'s `[String: Any]` message format.  We JSON-encode our
/// types into `Data` and wrap them under one of these keys; the
/// receiver looks for the key it expects and decodes.
///
/// Why not use the dictionary representation directly?  Because
/// `WatchCommand` carries associated values and `WatchSnapshot` has
/// nested types — both round-trip cleanly through JSON but get lossy
/// when shoved into `[String: Any]` via plist-style reflection.
enum WatchPayload {
    /// Top-level dictionary key for a `WatchSnapshot` payload.
    static let snapshotKey = "snapshot"
    /// Top-level dictionary key for a `WatchCommand` payload.
    static let commandKey = "command"

    static func encode(_ snapshot: WatchSnapshot) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        return [snapshotKey: data]
    }

    static func decodeSnapshot(from message: [String: Any]) -> WatchSnapshot? {
        guard let data = message[snapshotKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    static func encode(_ command: WatchCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        return [commandKey: data]
    }

    static func decodeCommand(from message: [String: Any]) -> WatchCommand? {
        guard let data = message[commandKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchCommand.self, from: data)
    }
}
