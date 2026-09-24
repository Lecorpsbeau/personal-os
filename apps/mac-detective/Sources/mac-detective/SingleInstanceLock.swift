import Darwin
import Foundation

enum SingleInstanceLockError: Error, CustomStringConvertible {
    case cannotOpen(path: String, message: String)
    case alreadyRunning(path: String)

    var description: String {
        switch self {
        case .cannotOpen(let path, let message):
            return "Cannot open single-instance lock \(path): \(message)"
        case .alreadyRunning(let path):
            return "Another mac-detective instance already owns \(path)"
        }
    }
}

final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1
    let path: String

    init(path: String) throws {
        self.path = path
        let descriptor = open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SingleInstanceLockError.cannotOpen(
                path: path,
                message: String(cString: strerror(errno))
            )
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            let message = String(cString: strerror(lockError))
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw SingleInstanceLockError.alreadyRunning(path: path)
            }
            throw SingleInstanceLockError.cannotOpen(
                path: path,
                message: message
            )
        }

        fileDescriptor = descriptor
    }

    func release() {
        guard fileDescriptor >= 0 else {
            return
        }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}
