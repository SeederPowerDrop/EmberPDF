// SPDX-License-Identifier: MPL-2.0
import Foundation

extension PluginScriptStorage {
    /// Conditional replacement is one host operation. Every comparison and write
    /// stays on the main actor without suspension, so independent window workers
    /// cannot overwrite a value that changed since they read it.
    @MainActor
    func compareAndSet(expected: Any, value: Any, identifier: String) throws -> Bool {
        // Wrapping fragments also validates scalars. Foundation can raise an
        // Objective-C exception for non-finite fragment numbers if not checked.
        guard JSONSerialization.isValidJSONObject([expected]), JSONSerialization.isValidJSONObject([value]) else {
            throw PluginScriptError.invalidMessage
        }
        let expectedBytes = try JSONSerialization.data(withJSONObject: expected, options: [.fragmentsAllowed, .sortedKeys])
        let replacementBytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard expectedBytes.count <= 64 * 1_024, replacementBytes.count <= 64 * 1_024 else {
            throw PluginScriptError.limit
        }
        let current = try get(identifier: identifier)
        let currentBytes = try JSONSerialization.data(withJSONObject: current, options: [.fragmentsAllowed, .sortedKeys])
        guard currentBytes == expectedBytes else { return false }
        try set(value, identifier: identifier)
        return true
    }
}
