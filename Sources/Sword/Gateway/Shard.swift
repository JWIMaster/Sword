import Foundation
import Dispatch
import SocketRocket

#if !os(Linux)
#else
import WebSockets
#endif

/// WS class
class Shard: Gateway {

    // MARK: Properties

    var gatewayUrl = ""
    let globalBucket: Bucket
    var heartbeatPayload: Payload {
        return Payload(op: .heartbeat, data: self.lastSeq ?? NSNull())
    }
    let heartbeatQueue: DispatchQueue!
    let id: Int
    var isConnected = false
    var lastSeq: Int?
    let presenceBucket: Bucket
    var isReconnecting = false
    var session: SRWebSocket?
    var sessionId: String?
    let shardCount: Int
    unowned let sword: Sword
    var acksMissed = 0

    // MARK: Initializer
    init(_ sword: Sword, _ id: Int, _ shardCount: Int, _ gatewayUrl: String) {
        self.sword = sword
        self.id = id
        self.shardCount = shardCount
        self.gatewayUrl = gatewayUrl

        self.heartbeatQueue = DispatchQueue(label: "me.azoy.sword.shard.\(id).heartbeat")

        self.globalBucket = Bucket(
            name: "me.azoy.sword.shard.\(id).global",
            limit: 120,
            interval: 60
        )

        self.presenceBucket = Bucket(
            name: "me.azoy.sword.shard.\(id).presence",
            limit: 5,
            interval: 60
        )
    }

    // MARK: Functions

    func handlePayload(_ payload: Payload) {
        if let sequenceNumber = payload.s {
            self.lastSeq = sequenceNumber
        }

        guard payload.t != nil else {
            self.handleGateway(payload)
            return
        }

        guard payload.d is [String: Any] else { return }

        self.handleEvent(payload.d as! [String: Any], payload.t!)
        self.sword.emit(.payload, with: payload.encode())
    }

    func handleDisconnect(for code: Int) {
        self.isReconnecting = true
        self.sword.emit(.disconnect, with: self.id)

        guard let closeCode = CloseOP(rawValue: code) else {
            self.sword.log("Connection closed with unrecognized response \(code).")
            self.reconnect()
            return
        }

        switch closeCode {
            case .authenticationFailed:
                print("[Sword] Invalid Bot Token")
            case .invalidShard:
                print("[Sword] Invalid Shard (We messed up here. Try again.)")
            case .noInternet:
                self.sword.globalQueue.asyncAfter(deadline: .now() + 10) { [self] in
                    self.sword.warn("Detected a loss of internet...")
                    self.reconnect()
                }
            case .shardingRequired:
                print("[Sword] Sharding is required for this bot to run correctly.")
            default:
                self.reconnect()
        }
    }

    func identify() {
        #if os(macOS)
        let osName = "macOS"
        #elseif os(Linux)
        let osName = "Linux"
        #elseif os(iOS)
        let osName = "iOS"
        #elseif os(watchOS)
        let osName = "watchOS"
        #elseif os(tvOS)
        let osName = "tvOS"
        #endif

        var data: [String: Any] = [
            "token": self.sword.token,
            "intents": self.sword.intents,
            "properties": [
                "$os": osName,
                "$browser": "Sword",
                "$device": "Sword"
            ],
            "compress": false,
            "large_threshold": 250,
            "shard": [self.id, self.shardCount]
        ]

        if let presence = self.sword.presence {
            data["presence"] = presence
        }

        let identity = Payload(op: .identify, data: data).encode()
        self.send(identity)
    }

    // MARK: Linux voice helpers
    #if os(macOS) || os(Linux)
    func joinVoiceChannel(_ channelId: Snowflake, in guildId: Snowflake) {
        let payload = Payload(op: .voiceStateUpdate, data: [
            "guild_id": guildId.description,
            "channel_id": channelId.description,
            "self_mute": false,
            "self_deaf": false
        ]).encode()
        self.send(payload)
    }

    func leaveVoiceChannel(in guildId: Snowflake) {
        let payload = Payload(op: .voiceStateUpdate, data: [
            "guild_id": guildId.description,
            "channel_id": NSNull(),
            "self_mute": false,
            "self_deaf": false
        ]).encode()
        self.send(payload)
    }
    #endif

    func reconnect() {
        #if !os(Linux)
        if self.session?.readyState == .OPEN {
            self.session?.close()
        }
        #else
        if let isOn = self.session?.state, isOn == .open {
            try? self.session?.close()
        }
        #endif

        self.isConnected = false
        self.acksMissed = 0
        self.sword.log("Disconnected from gateway... Resuming session")
        self.start()
    }

    func requestOfflineMembers(for guildId: Snowflake) {
        let payload = Payload(op: .requestGuildMember, data: [
            "guild_id": guildId.description,
            "query": "",
            "limit": 0
        ]).encode()
        self.send(payload)
    }

    func send(_ text: String, presence: Bool = false) {
        let item = DispatchWorkItem { [self] in
            #if !os(Linux)
            self.session?.send(text)
            #else
            try? self.session?.send(text)
            #endif
        }
        presence ? self.presenceBucket.queue(item) : self.globalBucket.queue(item)
    }

    func stop() {
        #if !os(Linux)
        self.session?.close()
        #else
        try? self.session?.close()
        #endif

        self.isConnected = false
        self.isReconnecting = false
        self.acksMissed = 0
        self.sword.log("Stopping gateway connection...")
    }

    // MARK: Start gateway connection
    func start() {
        #if !os(Linux)
        if self.session == nil {
            guard let url = URL(string: self.gatewayUrl) else { return }
            let socket = SRWebSocket(url: url)
            socket!.delegate = SocketDelegateWrapper(shard: self)
            self.session = socket
        }

        self.acksMissed = 0
        self.session?.open()
        #else
        // Linux implementation stays unchanged
        #endif
    }
}

// MARK: - SRWebSocket delegate wrapper
private class SocketDelegateWrapper: NSObject, SRWebSocketDelegate {
    weak var shard: Shard?

    init(shard: Shard) {
        self.shard = shard
    }

    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        shard?.isConnected = true
    }

    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        if let text = message as? String {
            shard?.handlePayload(Payload(with: text))
        }
    }

    func webSocket(_ webSocket: SRWebSocket!, didFailWithError error: Error!) {
        shard?.isConnected = false
        if let code = (error as NSError?)?.code {
            shard?.handleDisconnect(for: code)
        }
    }

    func webSocket(_ webSocket: SRWebSocket!, didCloseWithCode code: Int, reason: String!, wasClean: Bool) {
        shard?.isConnected = false
        shard?.handleDisconnect(for: code)
    }
}
