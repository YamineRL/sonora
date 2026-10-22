import Foundation

/// The TCC gate behind every Core Audio process tap.
///
/// A tap created without the System Audio Recording grant does *not* fail:
/// `AudioHardwareCreateProcessTap` returns `noErr`, the IOProc fires at the
/// normal cadence, buffers arrive with the right size — and every sample is
/// zero. Because a `CATapMutedWhenTapped` tap still removes the process from
/// the device mix, that failure mode is audible as "the slider muted the app"
/// rather than as an error.
///
/// [NSAudioCaptureUsageDescription] in Info.plist is what lets macOS show the
/// consent prompt at all, and the app has to be a signed bundle (Info.plist
/// sealed) for TCC to attribute the grant. See `build-app.sh`.
///
/// This is the same TCC SPI Apple's own AudioCap sample uses. It is private
/// API; it is fine for a Developer ID / direct-download app, not for the App
/// Store.
public enum SystemAudioPermission {

    public enum Status: Equatable {
        /// The user has granted System Audio Recording.
        case authorized
        /// The user declined, or the grant was reset in System Settings.
        case denied
        /// No decision yet — `requestAccess` is allowed to show the prompt.
        case undetermined
        /// macOS < 14.2, or TCC SPI unavailable. The caller may still try a
        /// tap; the zero-flow watchdog is the only signal in that case.
        case unavailable
    }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (
        CFString, CFDictionary?, @escaping (Bool) -> Void
    ) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen(frameworkPath, RTLD_NOW)

    private static let preflight: PreflightFn? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else {
            return nil
        }
        return unsafeBitCast(symbol, to: PreflightFn.self)
    }()

    private static let request: RequestFn? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            return nil
        }
        return unsafeBitCast(symbol, to: RequestFn.self)
    }()

    /// Current grant. Cheap enough to call on every menu interaction.
    public static func current() -> Status {
        guard #available(macOS 14.2, *) else { return .unavailable }
        guard let preflight else { return .unavailable }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .undetermined
        default: return .undetermined
        }
    }

    /// Shows the system prompt when the state is undetermined. The completion
    /// may arrive on any thread; the caller hops to the main actor.
    public static func requestAccess(completion: @escaping (Bool) -> Void) {
        guard #available(macOS 14.2, *), let request else {
            completion(false)
            return
        }
        request(service, nil, completion)
    }
}
