@testable import CodexMobilityMacFeature
import Darwin
import Foundation
import Testing

@Suite("Mac single-instance lock")
struct MacSingleInstanceLockTests {
    @Test
    func secondOwnerIsRejectedUntilFirstOwnerReleases() throws {
        try withTemporaryLockPath { path in
            let first = try MacSingleInstanceLock.acquire(path: path)

            #expect(throws: MacSingleInstanceLockError.alreadyRunning) {
                _ = try MacSingleInstanceLock.acquire(path: path)
            }

            first.release()
            let replacement = try MacSingleInstanceLock.acquire(path: path)
            replacement.release()
        }
    }

    @Test
    func newLockUsesPrivatePermissionsAndRecordsPID() throws {
        try withTemporaryLockPath { path in
            let lock = try MacSingleInstanceLock.acquire(path: path)
            defer { lock.release() }

            var metadata = stat()
            #expect(lstat(path, &metadata) == 0)
            #expect(metadata.st_mode & S_IFMT == S_IFREG)
            #expect(metadata.st_uid == geteuid())
            #expect(metadata.st_mode & 0o777 == S_IRUSR | S_IWUSR)

            let contents = try String(contentsOfFile: path, encoding: .utf8)
            #expect(contents == "\(getpid())\n")
        }
    }

    @Test
    func symlinkIsNeverFollowed() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target")
            let link = directory.appendingPathComponent("instance.lock")
            #expect(FileManager.default.createFile(
                atPath: target.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ))
            #expect(symlink(target.path, link.path) == 0)

            #expect(throws: (any Error).self) {
                _ = try MacSingleInstanceLock.acquire(path: link.path)
            }
        }
    }

    @Test
    func permissiveExistingFileIsRejected() throws {
        try withTemporaryLockPath(create: true, permissions: 0o644) { path in
            #expect(throws: MacSingleInstanceLockError.insecureFile(path: path)) {
                _ = try MacSingleInstanceLock.acquire(path: path)
            }
        }
    }

    private func withTemporaryLockPath(
        create: Bool = false,
        permissions: NSNumber = 0o600,
        _ operation: (String) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("instance.lock").path
            if create {
                #expect(FileManager.default.createFile(
                    atPath: path,
                    contents: Data(),
                    attributes: [.posixPermissions: permissions]
                ))
            }
            try operation(path)
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexWatchPet-single-instance-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try operation(directory)
    }
}
