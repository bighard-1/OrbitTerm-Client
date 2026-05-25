import Foundation
import Network

actor TelnetClient {
    struct AutoLoginConfig: Sendable {
        let username: String
        let password: String
        let profile: NetworkDeviceProfile

        var isEnabled: Bool {
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !password.isEmpty
        }
    }

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed
        case failed(String)
    }

    private var connection: NWConnection?
    private(set) var state: State = .idle
    private let host: String
    private let port: Int
    private var onData: ((Data) -> Void)?
    private var onState: ((State) -> Void)?
    private var autoLoginConfig: AutoLoginConfig?
    private var autoLoginBuffer = ""
    private var didSendUsername = false
    private var didSendPassword = false
    private var didSendContinue = false
    private var didCompleteAutoLogin = false

    init(host: String, port: Int) {
        self.host = host
        self.port = max(1, min(65535, port))
    }

    func connect(
        autoLogin: AutoLoginConfig? = nil,
        onData: @escaping (Data) -> Void,
        onState: @escaping (State) -> Void
    ) async -> Bool {
        self.onData = onData
        self.onState = onState
        self.autoLoginConfig = autoLogin?.isEnabled == true ? autoLogin : nil
        self.autoLoginBuffer = ""
        self.didSendUsername = false
        self.didSendPassword = false
        self.didSendContinue = false
        self.didCompleteAutoLogin = false
        state = .connecting
        onState(.connecting)

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            state = .failed("端口无效")
            onState(state)
            return false
        }
        let parameters = NWParameters.tcp
        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = connection

        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var resumed = false
            let resumeOnce: (Bool) -> Void = { result in
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                Task {
                    switch newState {
                    case .ready:
                        await self.updateState(.connected)
                        await self.receiveLoop()
                        resumeOnce(true)
                    case let .failed(error):
                        await self.updateState(.failed(error.localizedDescription))
                        await self.disconnect()
                        resumeOnce(false)
                    case .cancelled:
                        await self.updateState(.closed)
                        resumeOnce(false)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                resumeLock.lock()
                let shouldCancel = !resumed
                resumeLock.unlock()
                if shouldCancel {
                    connection.cancel()
                    resumeOnce(false)
                }
            }
        }
    }

    func send(_ bytes: [UInt8]) async -> Bool {
        guard let connection, case .connected = state else { return false }
        let data = Data(bytes)
        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { await self?.updateState(.failed(error.localizedDescription)) }
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            })
        }
    }

    func disconnect() async {
        connection?.cancel()
        connection = nil
        updateState(.closed)
    }

    private func receiveLoop() async {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.emitData(data)
                    await self.handleAutoLoginIfNeeded(data)
                }
                if let error {
                    await self.updateState(.failed(error.localizedDescription))
                    await self.disconnect()
                    return
                }
                if isComplete {
                    await self.updateState(.closed)
                    await self.disconnect()
                    return
                }
                await self.receiveLoop()
            }
        }
    }

    private func emitData(_ data: Data) {
        onData?(data)
    }

    private func handleAutoLoginIfNeeded(_ data: Data) async {
        guard let config = autoLoginConfig, !didCompleteAutoLogin else { return }
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return }

        autoLoginBuffer += chunk
        if autoLoginBuffer.count > 4096 {
            autoLoginBuffer = String(autoLoginBuffer.suffix(4096))
        }

        let snapshot = autoLoginBuffer
        if !didSendContinue, matchesContinuePrompt(snapshot, profile: config.profile) {
            didSendContinue = true
            _ = await send(Array("y\r\n".utf8))
            return
        }

        if !didSendUsername, matchesUsernamePrompt(snapshot, profile: config.profile) {
            didSendUsername = true
            _ = await send(Array((config.username + "\r\n").utf8))
            return
        }

        if !didSendPassword, matchesPasswordPrompt(snapshot, profile: config.profile) {
            didSendPassword = true
            _ = await send(Array((config.password + "\r\n").utf8))
            return
        }

        if didSendPassword, matchesShellPrompt(snapshot, profile: config.profile) {
            didCompleteAutoLogin = true
        }
    }

    private func matchesUsernamePrompt(_ text: String, profile: NetworkDeviceProfile) -> Bool {
        let patterns = [
            #"(?im)(^|\r|\n)\s*(username|login|user name|user|account|用户名|账号)\s*[:：]\s*$"#,
            #"(?im)(^|\r|\n)\s*(name)\s*[:：]\s*$"#
        ]
        return matchesAny(patterns, in: text)
    }

    private func matchesPasswordPrompt(_ text: String, profile: NetworkDeviceProfile) -> Bool {
        let patterns = [
            #"(?im)(^|\r|\n)\s*(password|passwd|passcode|口令|密码)\s*[:：]\s*$"#,
            #"(?im)(^|\r|\n).*password\s+for\s+.*[:：]\s*$"#
        ]
        return matchesAny(patterns, in: text)
    }

    private func matchesContinuePrompt(_ text: String, profile: NetworkDeviceProfile) -> Bool {
        let patterns = [
            #"(?im)(press any key|hit any key|按任意键|任意键)"#,
            #"(?im)(continue\?|continue connecting|are you sure|yes/no|y/n|是否继续)"#
        ]
        return matchesAny(patterns, in: text)
    }

    private func matchesShellPrompt(_ text: String, profile: NetworkDeviceProfile) -> Bool {
        var patterns = [
            #"(?m)(^|\r|\n)\s*<[^>\r\n]+>\s*$"#,
            #"(?m)(^|\r|\n)\s*\[[^\]\r\n]+\]\s*$"#,
            #"(?m)(^|\r|\n)[A-Za-z0-9_.()\/:-]{1,64}\s*[>#]\s*$"#
        ]

        switch profile {
        case .fortinetFortiGate:
            patterns.append(#"(?m)(^|\r|\n)[A-Za-z0-9_.-]+\s+\#\s*$"#)
        case .paloAltoPANOS:
            patterns.append(#"(?m)(^|\r|\n)[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+[>#]\s*$"#)
        case .mikrotikRouterOS:
            patterns.append(#"(?m)(^|\r|\n)\[[^\]\r\n]+@[^\]\r\n]+\]\s*>\s*$"#)
        default:
            break
        }
        return matchesAny(patterns, in: text)
    }

    private func matchesAny(_ patterns: [String], in text: String) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    private func updateState(_ newState: State) {
        state = newState
        onState?(newState)
    }
}
