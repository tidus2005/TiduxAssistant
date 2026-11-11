import Darwin
import Foundation

public enum MacSingleInstanceLockError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case cannotOpen(path: String, code: Int32)
    case cannotInspect(path: String, code: Int32)
    case insecureFile(path: String)
    case cannotLock(path: String, code: Int32)
    case cannotRecordOwner(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "CodexWatchPet 已经在运行。"
        case .cannotOpen(let path, let code):
            "无法打开单实例锁 \(path)：\(Self.message(for: code))"
        case .cannotInspect(let path, let code):
            "无法校验单实例锁 \(path)：\(Self.message(for: code))"
        case .insecureFile(let path):
            "拒绝使用不安全的单实例锁文件：\(path)"
        case .cannotLock(let path, let code):
            "无法锁定单实例文件 \(path)：\(Self.message(for: code))"
        case .cannotRecordOwner(let path, let code):
            "无法记录单实例进程 \(path)：\(Self.message(for: code))"
        }
    }

    private static func message(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Holds an advisory lock for the lifetime of the Mac app.
///
/// The lock file intentionally remains on disk after exit. Removing a lock file while another
/// process is waiting on its inode can split future instances across two different locks.
public final class MacSingleInstanceLock {
    public static var defaultPath: String {
        "/private/var/tmp/com.tidux.CodexWatchPet.mac-\(geteuid()).lock"
    }

    public let path: String
    private var fileDescriptor: Int32

    private init(path: String, fileDescriptor: Int32) {
        self.path = path
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        release()
    }

    public static func acquire(path: String = defaultPath) throws -> MacSingleInstanceLock {
        let baseFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        var didCreate = false
        var descriptor = path.withCString {
            Darwin.open($0, baseFlags | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }

        if descriptor == -1, errno == EEXIST {
            descriptor = path.withCString {
                Darwin.open($0, baseFlags)
            }
        } else if descriptor >= 0 {
            didCreate = true
        }

        guard descriptor >= 0 else {
            throw MacSingleInstanceLockError.cannotOpen(path: path, code: errno)
        }

        do {
            if didCreate, fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 {
                throw MacSingleInstanceLockError.cannotInspect(path: path, code: errno)
            }

            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw MacSingleInstanceLockError.cannotInspect(path: path, code: errno)
            }

            let fileType = metadata.st_mode & S_IFMT
            let permissions = metadata.st_mode & 0o777
            guard fileType == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1,
                  permissions == (S_IRUSR | S_IWUSR) else {
                throw MacSingleInstanceLockError.insecureFile(path: path)
            }

            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let lockError = errno
                if lockError == EWOULDBLOCK || lockError == EAGAIN {
                    throw MacSingleInstanceLockError.alreadyRunning
                }
                throw MacSingleInstanceLockError.cannotLock(
                    path: path,
                    code: lockError
                )
            }

            let ownerRecord = "\(getpid())\n"
            guard ftruncate(descriptor, 0) == 0,
                  lseek(descriptor, 0, SEEK_SET) == 0,
                  ownerRecord.withCString({
                      Darwin.write(
                          descriptor,
                          $0,
                          ownerRecord.utf8.count
                      )
                  }) == ownerRecord.utf8.count else {
                throw MacSingleInstanceLockError.cannotRecordOwner(
                    path: path,
                    code: errno
                )
            }

            return MacSingleInstanceLock(
                path: path,
                fileDescriptor: descriptor
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public func release() {
        guard fileDescriptor >= 0 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }
}
