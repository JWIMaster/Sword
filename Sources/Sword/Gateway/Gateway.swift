//
//  Gateway.swift
//  Sword
//
//  Created by Alejandro Alonso
//  Copyright © 2017 Alejandro Alonso. All rights reserved.
//

import Foundation
import Dispatch

#if !os(Linux)
import Starscream
#else
import Sockets
import TLS
import URI
import WebSockets
#endif

protocol Gateway: class {

  var acksMissed: Int { get set }
  
  var gatewayUrl: String { get set }

  var heartbeatPayload: Payload { get }
  
  var heartbeatQueue: DispatchQueue! { get }
  
  var isConnected: Bool { get set }
  
  var session: SRWebSocket? { get set }
  
  func handleDisconnect(for code: Int)
  
  func handlePayload(_ payload: Payload)
  
  func heartbeat(at interval: Int)
  
  func reconnect()
  
  func send(_ text: String, presence: Bool)
  
  func start()

  func stop()

}

import Foundation
import Dispatch
import SocketRocket

extension Gateway {

  func start() {
    #if !os(Linux)
    if self.session == nil {
        // Create a SocketRocket WebSocket
        guard let url = URL(string: self.gatewayUrl) else { return }
        let socket = SRWebSocket(url: url)
        socket!.delegate = SocketDelegateWrapper(gateway: self)
        self.session = socket
    }

    self.acksMissed = 0
    (self.session as? SRWebSocket)?.open()
    #else
    do {
      let gatewayUri = try URI(self.gatewayUrl)
      let tcp = try TCPInternetSocket(
        scheme: "https",
        hostname: gatewayUri.hostname,
        port: gatewayUri.port ?? 443
      )
      let stream = try TLS.InternetSocket(tcp, TLS.Context(.client))
      try WebSocket.connect(to: gatewayUrl, using: stream) {
        [self] ws in
        
        self.session = ws
        self.isConnected = true
        
        ws.onText = { _, text in
          self.handlePayload(Payload(with: text))
        }

        ws.onClose = { _, code, _, _ in
          self.isConnected = false

          guard let code = code else { return }

          self.handleDisconnect(for: Int(code))
        }
      }
    } catch {
      print("[Sword] \(error.localizedDescription)")
      self.start()
    }
    #endif
  }
}

/// A private wrapper to forward SocketRocket delegate calls to your Gateway instance
private class SocketDelegateWrapper: NSObject, SRWebSocketDelegate {
    weak var gateway: Gateway?

    init(gateway: Gateway) {
        self.gateway = gateway
    }

    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        gateway?.isConnected = true
    }

    func webSocket(_ webSocket: SRWebSocket!, didFailWithError error: Error!) {
        gateway?.isConnected = false
        if let code = (error as NSError?)?.code {
            gateway?.handleDisconnect(for: code)
        }
    }

    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        if let text = message as? String {
            gateway?.handlePayload(Payload(with: text))
        }
    }

    func webSocket(_ webSocket: SRWebSocket!, didCloseWithCode code: Int, reason: String!, wasClean: Bool) {
        gateway?.isConnected = false
        gateway?.handleDisconnect(for: code)
    }
}
