import Foundation

public enum LockError: Error, CustomStringConvertible {
    case busy(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .busy(let path): return "storage is in use by another Try FydeOS process or its QEMU (lock held on \(path))"
        case .system(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        }
    }
}

/// flock on `<workspace>/.lock`. The file is never unlinked. The descriptor stays
/// inheritable so QEMU keeps the lock for its whole life via `-add-fd`.
public final class StorageLock {
    public let path: String
    public private(set) var fd: Int32

    public init(path: String) throws {
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LockError.system("open \(path)", errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw LockError.busy(path) }
            throw LockError.system("flock \(path)", code)
        }
        self.path = path
        self.fd = fd
    }

    /// True when another open file description holds the lock.
    public static func isHeld(path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }

    public func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}
