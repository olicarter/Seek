import Foundation
import Network

enum SocketError: LocalizedError {
    case closed
    case timeout
    case oversized(Int)

    var errorDescription: String? {
        switch self {
        case .closed: "Connection closed"
        case .timeout: "Connection timed out"
        case .oversized(let size): "Message too large (\(size) bytes)"
        }
    }
}

/// A thin async wrapper around a TCP NWConnection. Reads must come from one task at a time.
final class Socket: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.olicarter.seek.socket")
    private var buffer = Data()

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 2242,
            using: .tcp
        )
    }

    init(accepted connection: NWConnection) {
        self.connection = connection
    }

    /// Connects and waits until the connection is ready.
    func open(timeout: TimeInterval = 10) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: error) }
                    connection.cancel()
                case .cancelled:
                    once.run { continuation.resume(throwing: SocketError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                once.run {
                    continuation.resume(throwing: SocketError.timeout)
                    connection.cancel()
                }
            }
        }
    }

    /// Starts a connection handed to us by a listener.
    func startAccepted() {
        connection.start(queue: queue)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Reads exactly `count` bytes.
    func read(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await receive(max: max(count - buffer.count, 64 * 1024)))
        }
        let result = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(result)
    }

    /// Returns whatever bytes are available next, for streaming file data.
    func readAvailable() async throws -> Data {
        if !buffer.isEmpty {
            defer { buffer = Data() }
            return buffer
        }
        return try await receive(max: 256 * 1024)
    }

    func readUInt32() async throws -> UInt32 {
        var reader = MessageReader(try await read(4))
        return try reader.uint32()
    }

    /// Reads one length-prefixed frame and returns its body (code included).
    func readFrame(limit: Int = 64 * 1024 * 1024) async throws -> Data {
        let length = Int(try await readUInt32())
        guard length <= limit else { throw SocketError.oversized(length) }
        return try await read(length)
    }

    func close() {
        connection.cancel()
    }

    private func receive(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    _ = isComplete
                    continuation.resume(throwing: SocketError.closed)
                }
            }
        }
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
