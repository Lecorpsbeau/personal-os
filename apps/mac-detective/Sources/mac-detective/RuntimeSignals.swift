import Darwin
import Dispatch
import Foundation

enum RuntimeSignal: Hashable, Equatable, Sendable {
    case interrupt
    case terminate

    var number: Int32 {
        switch self {
        case .interrupt:
            return SIGINT
        case .terminate:
            return SIGTERM
        }
    }
}

protocol RuntimeSignalInstalling: AnyObject {
    func install(handler: @escaping (RuntimeSignal) -> Void)
    func cancel()
}

final class RuntimeSignalRouter {
    private let lock = NSLock()
    private var handler: ((RuntimeSignal) -> Void)?
    private var pendingSignal: RuntimeSignal?

    func receive(_ signal: RuntimeSignal) {
        lock.lock()
        let handler = self.handler
        if handler == nil {
            pendingSignal = signal
        }
        lock.unlock()

        handler?(signal)
    }

    func connect(_ handler: @escaping (RuntimeSignal) -> Void) {
        lock.lock()
        self.handler = handler
        let pendingSignal = self.pendingSignal
        self.pendingSignal = nil
        lock.unlock()

        if let pendingSignal {
            handler(pendingSignal)
        }
    }
}

final class DarwinRuntimeSignalController: RuntimeSignalInstalling {
    private var sources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(
        label: "com.mac-detective.runtime.signals",
        qos: .utility
    )

    func install(handler: @escaping (RuntimeSignal) -> Void) {
        cancel()

        for signal in [RuntimeSignal.interrupt, .terminate] {
            // Darwin may retain the default disposition, which terminates the
            // process before the dispatch source gets a chance to run. Ignore
            // the signal first; the source then receives it asynchronously.
            _ = Darwin.signal(signal.number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(
                signal: signal.number,
                queue: queue
            )
            source.setEventHandler {
                handler(signal)
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    deinit {
        cancel()
    }
}
