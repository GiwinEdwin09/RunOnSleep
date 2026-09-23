import Foundation
import Darwin

public enum UnixTransport {
    public static let maximumFrame = 8192
    private static func fail(_ text: String) -> ServiceError { .failure(text) }

    public static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw fail("Socket path is too long.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    public static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    public static func peer(_ fd: Int32) throws -> Peer {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw fail("Cannot authenticate socket peer.") }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout.size(ofValue: token) else { throw fail("Cannot read peer audit identity.") }
        let identity = withUnsafeBytes(of: token) { Data($0) }
        return Peer(uid: uid, identity: identity)
    }

    public static func readFrame(_ fd: Int32) throws -> Data {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while data.count <= maximumFrame {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw fail("Socket read timed out.") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(remaining * 1000))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw fail("Socket read timed out.") }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw fail("Socket closed before a complete response.") }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= maximumFrame else { throw fail("Socket frame exceeds limit.") }
            if let end = data.firstIndex(of: 10) {
                guard end == data.count - 1 else { throw fail("Only one request per connection is allowed.") }
                return data.prefix(upTo: end)
            }
        }
        throw fail("Socket frame exceeds limit.")
    }

    public static func writeFrame<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        guard data.count <= maximumFrame else { throw fail("Socket frame exceeds limit.") }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw fail("Socket write failed.") }
                offset += count
            }
        }
    }

    public static func call(_ request: Request, path: String = BuildInfo.socketPath) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("Cannot create helper connection.") }
        defer { close(fd) }
        configure(fd)
        // A saturated listener must not indefinitely block the GUI worker.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw fail("Cannot configure helper connection.") }
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw fail("Helper unavailable. Install it for experimental closed-lid support.") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, 2000) > 0 else { throw fail("Helper connection timed out.") }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: socketError))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                throw fail("Helper connection failed.")
            }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else { throw fail("Cannot configure helper connection.") }
        // Do not send a session token to a user-created imposter socket.
        guard try peer(fd).uid == 0 else { throw fail("Helper socket is not owned by a root process.") }
        try writeFrame(request, to: fd)
        let response = try JSONDecoder().decode(Response.self, from: readFrame(fd))
        guard response.version == BuildInfo.protocolVersion else { throw fail("Helper protocol version mismatch.") }
        return response
    }
}
