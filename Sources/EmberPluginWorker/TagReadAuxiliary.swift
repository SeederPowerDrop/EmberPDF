// SPDX-License-Identifier: MPL-2.0
import CEmberPDFRawStreams
import Darwin
import Foundation

/// A separate native role. No JavaScript context or plugin protocol is used.
/// Parent supplies scoped inherited descriptors and owns RSS/time/cancellation,
/// output cleanup, source identity and all current-document eligibility checks.
enum TagReadAuxiliaryRole {
    static func run(arguments: [String]) -> Int32 {
        let prefix = ["--tag-read-auxiliary", "--protocol-version", "1", "--input-fd", "0", "--output-fd", "1", "--input-sha256"]
        guard arguments.count == 9, Array(arguments.prefix(8)) == prefix,
              arguments[8].utf8.count == 64,
              arguments[8].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return report(["type": "tag-read-auxiliary-error", "protocolVersion": 1, "status": "invalid_arguments"], code: 64)
        }
        let hex = Array(arguments[8].utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        let expected = stride(from: 0, to: 64, by: 2).map { nibble(hex[$0]) * 16 + nibble(hex[$0 + 1]) }
        var control = stat()
        guard Darwin.fstat(STDERR_FILENO, &control) == 0,
              control.st_mode & S_IFMT == S_IFIFO else {
            return report(["type": "tag-read-auxiliary-error", "protocolVersion": 1, "status": "invalid_control_pipe"], code: 64)
        }
        signal(SIGPIPE, SIG_IGN)
        // These independent self limits also cover QPDF calls that cannot
        // poll a callback. They do not replace the parent's owned-child proof.
        signal(SIGALRM) { _ in _exit(75) }
        alarm(90)
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        watchdog.schedule(deadline: .now(), repeating: .milliseconds(100))
        watchdog.setEventHandler {
            // Closing the parent's diagnostic reader is a cancellation
            // request even when child PID observation is unavailable. No
            // unverified process identifier is ever signalled for this path.
            var channel = pollfd(fd: STDERR_FILENO, events: Int16(POLLOUT), revents: 0)
            let observed = Darwin.poll(&channel, 1, 0)
            if (observed < 0 && errno != EINTR)
                || channel.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { _exit(78) }
            var resident: UInt64 = 0
            guard ember_pdf_current_worker_resident_bytes(&resident) == 1 else { _exit(76) }
            if resident > 1_024 * 1_024 * 1_024 { _exit(75) }
            if getppid() == 1 { _exit(77) }
        }
        watchdog.resume()
        defer { watchdog.cancel(); alarm(0) }
        let limits = EmberTagReadAuxiliaryLimits(max_input_bytes: 128 * 1_024 * 1_024,
                                                max_output_bytes: 192 * 1_024 * 1_024, max_objects: 250_000)
        var receipt = EmberTagReadAuxiliaryReceipt()
        let status = expected.withUnsafeBufferPointer { buffer in
            ember_tag_read_auxiliary(STDIN_FILENO, STDOUT_FILENO, buffer.baseAddress, limits,
                { _ in getppid() == 1 ? 1 : 0 }, nil, &receipt)
        }
        guard status == Int32(EMBER_TAG_AUX_OK.rawValue), receipt.raw_tag_graph_equivalent == 1,
              receipt.tag_nodes > 0, receipt.tag_nodes <= 16_000_000 else {
            return report(["type": "tag-read-auxiliary-error", "protocolVersion": 1, "status": Int(status)], code: 65)
        }
        func hexadecimal<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
        }
        return report(["type": "tag-read-auxiliary-result", "protocolVersion": 1, "status": "ok",
            "inputBytes": receipt.input_bytes, "outputBytes": receipt.output_bytes,
            "objectCount": receipt.object_count, "pageCount": receipt.page_count, "tagNodes": receipt.tag_nodes,
            "inputSHA256": hexadecimal(receipt.input_sha256), "outputSHA256": hexadecimal(receipt.output_sha256),
            "rawTagGraphEquivalent": true], code: 0)
    }

    private static func report(_ value: [String: Any], code: Int32) -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count < 2_047 else { return 70 }
        var line = data; line.append(10)
        do { try FileHandle.standardError.write(contentsOf: line) }
        catch { return 74 }
        return code
    }
}
