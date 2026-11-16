import Foundation

/// One WebSocket message as it arrived.
public enum SocketMessage: Sendable, Equatable {
    case binary(Data)
    case text(String)
}

/// How a WebSocket connection ended.
public enum SocketError: Error, Equatable, Sendable {
    /// The connection is gone; `code` is the close code of the relay, nil when it sent none.
    case closed(code: Int?)
    /// A message above the receive limit arrived (section 6.3).
    case tooBig
}

/// The seam between the transport and the WebSocket library: the real one dials the relay,
/// a scripted one lets a test say what the relay sends.
public protocol RelaySocket: Sendable {
    func receive() async throws -> SocketMessage
    func send(_ data: Data) async throws
    func close(code: Int) async
}

public protocol RelayDialer: Sendable {
    func dial(_ url: URL) async throws -> any RelaySocket
}

/// Dials with `URLSessionWebSocketTask`: no proxy, a receive limit of MAX_FRAME_BYTES
/// (section 23.2), binary frames only.
public struct URLSessionDialer: RelayDialer {
    public init() {}

    public static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: false,
            kCFNetworkProxiesHTTPSEnable: false,
            kCFNetworkProxiesSOCKSEnable: false,
            kCFNetworkProxiesProxyAutoConfigEnable: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable: false,
        ]
        return configuration
    }

    public func dial(_ url: URL) async throws -> any RelaySocket {
        URLSessionSocket(url: url)
    }
}

final class URLSessionSocket: RelaySocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: URLSessionDialer.configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = Frames.maxFrameBytes
        task.resume()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func receive() async throws -> SocketMessage {
        do {
            switch try await task.receive() {
            case .data(let data): return .binary(data)
            case .string(let text): return .text(text)
            @unknown default: throw ended()
            }
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EMSGSIZE) {
            throw SocketError.tooBig
        } catch {
            throw ended()
        }
    }

    func send(_ data: Data) async throws {
        do {
            try await task.send(.data(data))
        } catch {
            throw ended()
        }
    }

    func close(code: Int) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }

    private func ended() -> SocketError {
        let code = task.closeCode
        return .closed(code: code == .invalid ? nil : code.rawValue)
    }
}
