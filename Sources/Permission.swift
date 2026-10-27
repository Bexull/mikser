import Foundation

/// "System audio recording" permission (TCC service kTCCServiceAudioCapture).
/// There is no public API to query it, so this uses the same TCC calls Apple's own
/// tools rely on. Without the permission a tap still mutes the app but delivers silence,
/// so the mixer must never tap anything until access is granted.
enum AudioCaptureAccess {
    enum Status { case granted, denied, notDetermined }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    static var status: Status {
        guard let preflightFunction else { return .granted }
        switch preflightFunction(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (only the first time); the completion runs on the main queue.
    static func request(completion: @escaping (Bool) -> Void) {
        guard let requestFunction else {
            completion(true)
            return
        }
        requestFunction(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
