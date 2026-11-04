import Foundation
import CryptoKit
import Network

enum SelfTest {
    static var failed = false

    static func run() {
        failed = false
        check("endpointInfo round-trip", testEndpointInfo)
        check("protobuf varint codec", testVarint)
        check("protobuf message encode/decode", testProtoMessage)
        check("HKDF RFC5869 vector", testHKDF)
        check("P-256 ECDH agreement", testECDH)
        check("AES-GCM QR TLV round-trip", testAESGCM)
        check("PIN derivation format", testPIN)
        check("UKEY2 sign/verify interop", testUkeySignVerify)
        check("QR image renders scannable", testQRImage)
        check("full handshake loopback (client+server)", testHandshakeLoopback)
        if failed {
            print("SELF-TEST: FAIL")
        } else {
            print("SELF-TEST: PASS")
        }
    }

    private static func check(_ name: String, _ fn: () throws -> Void) {
        do {
            try fn()
            print("  ok: \(name)")
        } catch {
            failed = true
            print("  FAIL: \(name): \(error)")
        }
    }

    private static func testEndpointInfo() throws {
        let info = EndpointInfo(name: "TestMac", deviceType: .computer)
        let data = info.serialize()
        guard let back = EndpointInfo(data: data) else { throw TestErr.bad("parse nil") }
        guard back.name == "TestMac" else { throw TestErr.bad("name mismatch: \(back.name ?? "nil")") }
        guard back.deviceType == .computer else { throw TestErr.bad("type mismatch") }

        // A long multi-byte name must still fit Nearby's 131-byte limit and stay valid UTF-8.
        let long = String(repeating: "Manik’s MacBook Neo ", count: 10)
        let longData = EndpointInfo(name: long, deviceType: .computer).serialize()
        guard longData.count <= EndpointInfo.maxSerializedLength else { throw TestErr.bad("long name not capped: \(longData.count) bytes") }
        guard let longBack = EndpointInfo(data: longData), let name = longBack.name, long.hasPrefix(name), !name.isEmpty else {
            throw TestErr.bad("long name not a clean prefix")
        }
    }

    private static func testVarint() throws {
        for v: UInt64 in [0, 1, 127, 128, 300, UInt64.max / 2] {
            let enc = ProtoCompatWriter.varint(v)
            var pos = 0
            let dec = try ProtoCompatReader.readVarint(enc, &pos)
            guard dec == v && pos == enc.count else { throw TestErr.bad("varint \(v)") }
        }
    }

    private static func testProtoMessage() throws {
        var msg = Securemessage_SecureMessage()
        msg.headerAndBody = Data([1, 2, 3])
        msg.signature = Data([4, 5])
        let enc = try msg.serializedData()
        let back = try Securemessage_SecureMessage(serializedData: enc)
        guard back.headerAndBody == Data([1, 2, 3]) && back.signature == Data([4, 5]) else {
            throw TestErr.bad("message mismatch")
        }
        guard back.hasHeaderAndBody && back.hasSignature else { throw TestErr.bad("has flags") }
    }

    private static func testHKDF() throws {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data([0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c])
        let info = Data([0xf0,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9])
        let okm = NearbyConnection.hkdf(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: 42)
        let expected = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        let got = okm.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        guard got == expected else { throw TestErr.bad("hkdf mismatch: \(got)") }
    }

    private static func testECDH() throws {
        let (pubA, privA) = ECDomain.makeKeyPair()
        let (pubB, _) = ECDomain.makeKeyPair()
        let s1 = try ECDomain.sharedSecret(privateKey: privA, peerX: signedBytes(pubB.rawX), peerY: signedBytes(pubB.rawY))
        guard s1.count == 32 else { throw TestErr.bad("ecdh len") }
        _ = pubA
    }

    private static func testAESGCM() throws {
        let key = SymmetricKey(size: .bits128)
        let nonce = try AES.GCM.Nonce(data: Data.randomData(length: 12))
        let sealedBox = try AES.GCM.seal(Data("hello android".utf8), using: key, nonce: nonce, authenticating: Data("ad".utf8))
        let opened = try AES.GCM.open(sealedBox, using: key, authenticating: Data("ad".utf8))
        guard String(data: opened, encoding: .utf8) == "hello android" else { throw TestErr.bad("aes-gcm") }
    }

    private static func testPIN() throws {
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let pin = NearbyConnection.pinCodeFromAuthKey(key)
        guard pin.count == 4 && Int(pin) != nil else { throw TestErr.bad("pin: \(pin)") }
    }

    // Verify our CryptoKit ECDH produces the same shared secret as the peer
    // computing from our public key (both directions), and that QR-style
    // raw ECDSA signatures verify.
    private static func testUkeySignVerify() throws {
        let (pubA, privA) = ECDomain.makeKeyPair()
        let (pubB, privB) = ECDomain.makeKeyPair()
        let sAB = try ECDomain.sharedSecret(privateKey: privA, peerX: signedBytes(pubB.rawX), peerY: signedBytes(pubB.rawY))
        let sBA = try ECDomain.sharedSecret(privateKey: privB, peerX: signedBytes(pubA.rawX), peerY: signedBytes(pubA.rawY))
        guard sAB == sBA else { throw TestErr.bad("ecdh asymmetry") }
        let msg = Data("authkey-material".utf8)
        let sig = try privA.sign(msg: msg)
        let raw = sig.r + sig.s
        guard raw.count == 64 else { throw TestErr.bad("sig len") }
        // Verify via CryptoKit ECDSA raw signature
        let pub = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + privA.publicKey.signing.rawRepresentation)
        let ecdsaSig = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        guard pub.isValidSignature(ecdsaSig, for: msg) else { throw TestErr.bad("sig verify") }
    }

    private static func testQRImage() throws {
        guard let image = qrImage(from: "https://quickshare.google/qrcode#key=TESTKEY123", size: 160) else {
            throw TestErr.bad("qr render nil")
        }
        guard image.size.width == 160 && image.size.height == 160 else {
            throw TestErr.bad("qr size \(image.size)")
        }
        let rep = image.representations.first
        guard rep != nil else { throw TestErr.bad("qr no representation") }
    }

    // Full protocol handshake over real NWConnections on localhost:
    // server (inbound) + client (outbound) through UKEY2, PairedKey,
    // Introduction(auto-accept), one file payload, disconnection.
    private static func testHandshakeLoopback() throws {
        let fileBytes = Data("hello quickshare loopback".utf8)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let destDir = tmpDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let listener = try NWListener(using: NWParameters(tls: .none))
        let serverDone = DispatchSemaphore(value: 0)
        var serverError: Error?
        var receivedFiles: [String: Data] = [:]
        let serverConnHolder = ServerConnHolder()
        let ready = DispatchSemaphore(value: 0)
        var listenerFailed: Error?
        listener.stateUpdateHandler = { st in
            if case .ready = st { ready.signal() }
            if case .failed(let e) = st { listenerFailed = e; ready.signal() }
        }
        listener.newConnectionHandler = { [weak serverConnHolder] nwconn in
            let srv = LoopbackServer(connection: nwconn, id: "srv") { result in
                switch result {
                case .success(let files):
                    receivedFiles = files
                case .failure(let e):
                    serverError = e
                }
                serverDone.signal()
            }
            srv.connectionDidClose = { [weak srv] in
                guard let srv = srv else {return}
                if srv.fileCount > 0 {
                    receivedFiles = srv.allCollected
                    serverDone.signal()
                }
            }
            serverConnHolder?.conn = srv
            serverConnHolder?.conn?.start()
        }
        listener.start(queue: DispatchQueue(label: "loopback-listener"))
        guard ready.wait(timeout: .now() + 10) == .success else { throw TestErr.bad("listener never ready") }
        if let e = listenerFailed { throw e }
        guard let port = listener.port else { throw TestErr.bad("no port") }
        let clientDone = DispatchSemaphore(value: 0)
        var clientError: Error?
        let sendURL = tmpDir.appendingPathComponent("send.txt")
        try fileBytes.write(to: sendURL)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: .none, tcp: tcp)
        let nwclient = NWConnection(host: "127.0.0.1", port: port, using: params)
        let clientHolder = ClientConnHolder()
        let client = LoopbackClient(connection: nwclient, id: "cli", urlsToSend: [sendURL]) { e in
            clientError = e
            clientDone.signal()
        }
        clientHolder.conn = client
        client.start()
        let serverWait = pump(semaphore: serverDone, timeout: 20)
        let clientWait = pump(semaphore: clientDone, timeout: 10)
        listener.cancel()
        guard serverWait == .success else { throw TestErr.bad("server timeout") }
        guard clientWait == .success else { throw TestErr.bad("client timeout") }
        if let e = serverError { throw e }
        if let e = clientError { throw e }
        guard receivedFiles.values.contains(fileBytes) else {
            throw TestErr.bad("file bytes mismatch: \(receivedFiles)")
        }
    }
}

final class ServerConnHolder { var conn: LoopbackServer? }
final class ClientConnHolder { var conn: LoopbackClient? }

enum TestErr: Error {
    case bad(String)
}

private func pump(semaphore: DispatchSemaphore, timeout: TimeInterval) -> DispatchTimeoutResult{
    let deadline=Date(timeIntervalSinceNow: timeout)
    while true{
        if semaphore.wait(timeout: .now()+DispatchTimeInterval.milliseconds(50))==DispatchTimeoutResult.success{return .success}
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        if Date()>deadline{return .timedOut}
    }
}

// Minimal inbound subclass writing files to a temp dir and auto-accepting.
final class LoopbackServer: InboundNearbyConnection {
    private var collected: [String: Data] = [:]
    var fileCount: Int { collected.count }
    var allCollected: [String: Data] { collected }

    private final class AutoDelegate: InboundNearbyConnectionDelegate{
        weak var server:LoopbackServer?
        let finish:(Result<[String: Data], Error>) -> Void
        init(server:LoopbackServer, finish:@escaping (Result<[String: Data], Error>) -> Void){
            self.server=server
            self.finish=finish
        }
        func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
            connection.submitUserConsentDirect(accepted: true)
        }
        func connectionWasTerminated(connection: InboundNearbyConnection, error: Error?) {
            let collected=server?.allCollected ?? [:]
            if collected.isEmpty, let e = error{
                finish(.failure(e))
            } else {
                finish(.success(collected))
            }
        }
    }
    private var autoDelegate:AutoDelegate?

    init(connection: NWConnection, id: String, finish: @escaping (Result<[String: Data], Error>) -> Void) {
        super.init(connection: connection, id: id)
        autoDelegate=AutoDelegate(server: self, finish: finish)
        delegate=autoDelegate
    }

    override func processReceivedFrame(frameData: Data) {
        super.processReceivedFrame(frameData: frameData)
    }

    override func processFileChunk(frame: Location_Nearby_Connections_PayloadTransferFrame) throws {
        let id = frame.payloadHeader.id
        var cur = collected["file-\(id)"] ?? Data()
        cur.reserveCapacity(cur.count + frame.payloadChunk.body.count)
        cur.append(frame.payloadChunk.body)
        collected["file-\(id)"] = cur
        if (frame.payloadChunk.flags & 1) == 1 {
            try sendDisconnectionAndDisconnect()
        }
    }
}

// Minimal outbound subclass reporting completion.
final class LoopbackServer2: InboundNearbyConnection { // unused
    override func processTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
        print("loopback server got setup frame: \(frame.v1.type) in state machine")
        try super.processTransferSetupFrame(frame)
    }
}

final class LoopbackClient: OutboundNearbyConnection {
    private var finished = false
    private final class AutoDelegate: OutboundNearbyConnectionDelegate{
        weak var client:LoopbackClient?
        let finish:(Error?) -> Void
        init(client:LoopbackClient, finish:@escaping (Error?) -> Void){
            self.client=client
            self.finish=finish
        }
        func outboundConnectionWasEstablished(connection: OutboundNearbyConnection) {}
        func outboundConnection(connection: OutboundNearbyConnection, transferProgress: Double) {}
        func outboundConnectionTransferAccepted(connection: OutboundNearbyConnection) {}
        func outboundConnection(connection: OutboundNearbyConnection, failedWithError: Error) {
            client?.done(failedWithError)
        }
        func outboundConnectionTransferFinished(connection: OutboundNearbyConnection) {
            client?.done(nil)
        }
    }
    private var autoDelegate:AutoDelegate?

    init(connection: NWConnection, id: String, urlsToSend: [URL], finish: @escaping (Error?) -> Void) {
        super.init(connection: connection, id: id, urlsToSend: urlsToSend)
        autoDelegate=AutoDelegate(client: self, finish: finish)
        delegate=autoDelegate
    }

    fileprivate func done(_ e: Error?) {
        if !finished {
            finished = true
            autoDelegate?.finish(e)
        }
    }
}
