// SPDX-License-Identifier: MPL-2.0

import Foundation
import LocalAuthentication
import Security

/// Data Protection honors LAContext, but the file-based login Keychain needs
/// its legacy interaction switch. Serialize all of our Keychain operations so
/// a silent operation cannot change an overlapping credential request.
enum SystemKeychainAccess {
    private static let lock = NSRecursiveLock()

    static func perform(query: [CFString: Any], operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }

        guard requiresNoninteractiveAccess(query) else { return operation() }
        return withoutInteraction(operation: operation)
    }

    static func requiresNoninteractiveAccess(_ query: [CFString: Any]) -> Bool {
        // LAContext's property can read back as false when the authentication
        // service is unavailable. An explicit query policy must still fail closed.
        if let policy = query[kSecUseAuthenticationUI],
           CFEqual(policy as CFTypeRef, kSecUseAuthenticationUIFail) {
            return true
        }
        return (query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true
    }

    /// Injectable for tests: no test needs to inspect the user's Keychain.
    static func withoutInteraction(
        getAllowed: (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus = SecKeychainGetUserInteractionAllowed,
        setAllowed: (Bool) -> OSStatus = SecKeychainSetUserInteractionAllowed,
        operation: () -> OSStatus
    ) -> OSStatus {
        var wasAllowed = DarwinBoolean(false)
        let readStatus = getAllowed(&wasAllowed)
        guard readStatus == errSecSuccess else { return readStatus }
        guard wasAllowed.boolValue else { return operation() }

        let setStatus = setAllowed(false)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { _ = setAllowed(wasAllowed.boolValue) }
        return operation()
    }
}
