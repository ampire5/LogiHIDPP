import Darwin
import Foundation
import os

private let log = Logger(subsystem: "LogiHIDPP", category: "SoftwareID")

/// The HID++ software ID of this process: the low nibble of byte 3 of every request, echoed by its reply.
///
/// macOS delivers every input report of the receiver's vendor interface to every process that has it open, so two
/// processes using the same software ID take each other's replies as answers to their own requests (and can then send
/// a write to the wrong feature). Each process therefore claims its own ID: the lowest free one of
/// `candidates`, by a non-blocking `flock` on `$TMPDIR/LogiHIDPP-swid-<n>.lock`, held for the life of the process (the
/// kernel drops the lock when the process ends, crash included). Notifications carry ID 0, which is never claimed;
/// BetterMouse uses 8, which is never claimed either.
public enum HIDPPSoftwareID {
    /// The order IDs are tried in: `0xA…0xF`, then `1…7` and `9`.
    public static let candidates: [UInt8] = [0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 1, 2, 3, 4, 5, 6, 7, 9]

    /// This process's ID, claimed on first use. When every candidate is taken (or the lock files cannot be opened, e.g.
    /// in a sandbox without a shared temporary directory) it falls back to `0x0A` and logs an error; pass an explicit
    /// `softwareID:` to `HIDPPChannel` / `LogiMouse` there.
    public static let process: UInt8 = {
        let directory = userTemporaryDirectory()
        if let claim = claim(in: directory) {
            return claim.id   // the descriptor stays open for the life of the process: it holds the lock
        }
        log.error("no free HID++ software ID in \(directory, privacy: .public): falling back to 0x0A")
        return candidates[0]
    }()

    /// The per-user temporary directory as Darwin defines it (`_CS_DARWIN_USER_TEMP_DIR`), not `$TMPDIR`: a shell that
    /// overrides `TMPDIR` must not put its locks where another process using the package won't look.
    static func userTemporaryDirectory() -> String {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return NSTemporaryDirectory() }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return NSTemporaryDirectory() }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Claims the first free candidate in `directory`. Returns the ID and the descriptor that holds its lock (closing
    /// it frees the ID), or nil when none is free.
    static func claim(in directory: String, candidates: [UInt8] = candidates) -> (id: UInt8, descriptor: Int32)? {
        for id in candidates {
            let path = (directory as NSString).appendingPathComponent("LogiHIDPP-swid-\(id).lock")
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return (id, descriptor) }
            close(descriptor)
        }
        return nil
    }
}
