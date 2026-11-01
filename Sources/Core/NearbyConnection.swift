import Foundation
import Network
import CommonCrypto
import CryptoKit
import System


class NearbyConnection{
	internal static let SANE_FRAME_LENGTH=5*1024*1024
	internal static let maxInflightPayloads=4
	internal static let maxReassemblyBytes=20*1024*1024
	internal static let payloadTTL:TimeInterval=60
	internal static let fileIOQueue=DispatchQueue(label: "me.grishka.NearDrop.fileIO", qos: .utility)

	internal let connection:NWConnection
	internal let peerQueue:DispatchQueue
	internal var remoteDeviceInfo:RemoteDeviceInfo?
	private var payloadBuffers:[Int64:PayloadBuffer]=[:]
	private var payloadBytesTotal:Int=0
	internal var encryptionDone:Bool=false
	internal var transferredFiles:[Int64:InternalFileInfo]=[:]
	public let id:String
	internal var lastError:Error?
	private var connectionClosed:Bool=false
	private let closeLock=NSLock()
	private var didClose=false

	private struct PayloadBuffer{
		var data:NSMutableData
		var total:Int64
		var updated:Date
	}

	internal var publicKey:ECPublicKey?
	internal var privateKey:ECPrivateKey?
	internal var ukeyClientInitMsgData:Data?
	internal var ukeyServerInitMsgData:Data?

	internal var decryptKey:[UInt8]?
	internal var encryptKey:[UInt8]?
	internal var recvHmacKey:SymmetricKey?
	internal var sendHmacKey:SymmetricKey?

	private var serverSeq:Int32=0
	private var clientSeq:Int32=0

	private(set) var pinCode:String?
	private(set) var authKey:SymmetricKey?

	init(connection: NWConnection, id:String) {
		self.connection=connection
		self.id=id
		self.peerQueue=DispatchQueue(label: "me.grishka.NearDrop.conn")
	}

	internal var isClosed:Bool{
		closeLock.lock()
		defer{closeLock.unlock()}
		return connectionClosed
	}

	internal func markClosed(){
		closeLock.lock()
		connectionClosed=true
		closeLock.unlock()
	}

	internal func claimClosure()->Bool{
		closeLock.lock()
		defer{closeLock.unlock()}
		if didClose{return false}
		didClose=true
		return true
	}

	func start(){
		connection.stateUpdateHandler={[weak self] state in
			guard let self=self else {return}
			if case .ready = state {
				self.connectionReady()
				self.receiveFrameAsync()
			} else if case .failed(let err) = state {
				self.lastError=err
				self.handleConnectionClosure()
			}
		}
		connection.start(queue: peerQueue)
	}

	func connectionReady(){}

	internal func handleConnectionClosure(){
		guard claimClosure() else {return}
		connectionDidClose?()
		noteClosure()
	}

	internal func noteClosure(){}

	public var connectionDidClose:(() -> Void)?

	internal func protocolError(){
		disconnect()
	}

	internal func processReceivedFrame(frameData:Data){
		lastError=NearbyError.protocolError("unhandled frame")
		disconnect()
	}

	internal func processTransferSetupFrame(_ frame:Sharing_Nearby_Frame) throws{
		lastError=NearbyError.protocolError("unhandled setup frame")
		disconnect()
	}

	internal func isServer() -> Bool{
		return false
	}

	internal func processFileChunk(frame: Location_Nearby_Connections_PayloadTransferFrame) throws{
		protocolError()
	}

	internal func processBytesPayload(payload:Data, id:Int64)throws ->Bool{
		return false
	}

	private func bufferForPayload(id:Int64, totalSize:Int64) throws ->NSMutableData{
		if let existing=payloadBuffers[id]?.data{
			payloadBuffers[id]?.updated=Date()
			return existing
		}
		guard totalSize>=0 else {throw NearbyError.protocolError("negative payload size")}
		guard totalSize<=Int64(NearbyConnection.SANE_FRAME_LENGTH) else {throw NearbyError.protocolError("payload too large (\(totalSize) bytes)")}
		sweepPayloads()
		while payloadBuffers.count>=NearbyConnection.maxInflightPayloads || payloadBytesTotal+Int(totalSize)>NearbyConnection.maxReassemblyBytes{
			guard evictOldestPayload() else {break}
		}
		let buf=NSMutableData(capacity: Int(totalSize)) ?? NSMutableData(capacity: 0)!
		payloadBuffers[id]=PayloadBuffer(data: buf, total: totalSize, updated: Date())
		payloadBytesTotal+=Int(totalSize)
		return buf
	}

	private func touchPayload(id:Int64){
		payloadBuffers[id]?.updated=Date()
	}

	private func removePayload(id:Int64){
		if let b=payloadBuffers.removeValue(forKey: id){
			payloadBytesTotal=max(0, payloadBytesTotal-Int(b.total))
		}
	}

	private func sweepPayloads(){
		let cutoff=Date().addingTimeInterval(-NearbyConnection.payloadTTL)
		for (id, b) in payloadBuffers where b.updated<cutoff{
			payloadBuffers.removeValue(forKey: id)
			payloadBytesTotal=max(0, payloadBytesTotal-Int(b.total))
		}
	}

	private func evictOldestPayload()->Bool{
		guard let oldest=payloadBuffers.min(by: {$0.value.updated<$1.value.updated}) else {return false}
		removePayload(id: oldest.key)
		return true
	}

	private var pendingHeader=Data()

	private func receiveFrameAsync(){
		pendingHeader=Data()
		receiveMoreHeaderBytes()
	}

	private func receiveMoreHeaderBytes(){
		let remaining=4-pendingHeader.count
		guard remaining>0 else {
			let h=pendingHeader
			pendingHeader=Data()
			let frameLength:UInt32=UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
			guard frameLength>0 && frameLength<NearbyConnection.SANE_FRAME_LENGTH else {
				self.lastError=NearbyError.protocolError("Unexpected packet length")
				self.protocolError()
				return
			}
			self.receiveFrameAsync(length: frameLength)
			return
		}
		connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {[weak self] content, contentContext, isComplete, error in
			guard let self=self else {return}
			if self.isClosed{
				return
			}
			if isComplete{
				self.handleConnectionClosure()
				return
			}
			if let error=error{
				self.lastError=error
				self.protocolError()
				return
			}
			guard let content=content, !content.isEmpty else {
				self.lastError=NearbyError.protocolError("empty header chunk")
				self.protocolError()
				return
			}
			self.pendingHeader.append(content)
			self.receiveMoreHeaderBytes()
		}
	}

	private var pendingFrameLength:UInt32=0
	private var pendingFrameData=Data()

	private func receiveFrameAsync(length:UInt32){
		pendingFrameLength=length
		pendingFrameData=Data()
		receiveMoreFrameBytes()
	}

	private func receiveMoreFrameBytes(){
		let remaining=Int(pendingFrameLength)-pendingFrameData.count
		guard remaining>0 else {
			let frame=pendingFrameData
			pendingFrameData=Data()
			self.processReceivedFrame(frameData: frame)
			self.receiveFrameAsync()
			return
		}
		connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {[weak self] content, contentContext, isComplete, error in
			guard let self=self else {return}
			if self.isClosed{
				return
			}
			if isComplete{
				self.handleConnectionClosure()
				return
			}
			if let error=error{
				self.lastError=error
				self.protocolError()
				return
			}
			guard let content=content, !content.isEmpty else {
				self.lastError=NearbyError.protocolError("empty frame chunk")
				self.protocolError()
				return
			}
			self.pendingFrameData.append(content)
			self.receiveMoreFrameBytes()
		}
	}

	internal func sendFrameAsync(_ frame:Data, completion:(()->Void)?=nil){
		if isClosed{
			return
		}
		var lengthPrefixedData=Data(capacity: frame.count+4)
		let length:Int=frame.count
		lengthPrefixedData.append(contentsOf: [
			UInt8(truncatingIfNeeded: length >> 24),
			UInt8(truncatingIfNeeded: length >> 16),
			UInt8(truncatingIfNeeded: length >> 8),
			UInt8(truncatingIfNeeded: length)
		])
		lengthPrefixedData.append(frame)
		connection.send(content: lengthPrefixedData, completion: .contentProcessed({ _ in
			if let completion=completion{
				completion()
			}
		}))
	}

	internal func encryptAndSendOfflineFrame(_ frame:Location_Nearby_Connections_OfflineFrame, completion:(()->Void)?=nil) throws{
		guard let sendKey=sendHmacKey else {throw NearbyError.requiredFieldMissing("sendHmacKey")}
		guard let encKey=encryptKey else {throw NearbyError.requiredFieldMissing("encryptKey")}
		var d2dMsg=Securegcm_DeviceToDeviceMessage()
		serverSeq+=1
		d2dMsg.sequenceNumber=serverSeq
		d2dMsg.message=try frame.serializedData()

		let serializedMsg=[UInt8](try d2dMsg.serializedData())
		let iv=Data.randomData(length: 16)
		var encryptedData=Data(count: serializedMsg.count+16)
		var encryptedLength:size_t=0
		let ccStatus=encryptedData.withUnsafeMutableBytes({ (outPtr: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
			guard let outBase=outPtr.baseAddress else {return CCCryptorStatus(kCCParamError)}
			return encKey.withUnsafeBytes({ keyPtr in
				CCCrypt(
					CCOperation(kCCEncrypt),
					CCAlgorithm(kCCAlgorithmAES128),
					CCOptions(kCCOptionPKCS7Padding),
					keyPtr.baseAddress, kCCKeySizeAES256,
					[UInt8](iv),
					serializedMsg, serializedMsg.count,
					outBase, outPtr.count,
					&encryptedLength
				)
			})
		})
		guard ccStatus==kCCSuccess else {throw NearbyError.protocolError("encrypt failed: \(ccStatus)")}

		var hb=Securemessage_HeaderAndBody()
		hb.body=encryptedData.prefix(encryptedLength)
		hb.header=Securemessage_Header()
		hb.header.encryptionScheme = .aes256Cbc
		hb.header.signatureScheme = .hmacSha256
		hb.header.iv=iv
		var md=Securegcm_GcmMetadata()
		md.type = .deviceToDeviceMessage
		md.version=1
		hb.header.publicMetadata=try md.serializedData()

		var smsg=Securemessage_SecureMessage()
		smsg.headerAndBody=try hb.serializedData()
		smsg.signature=Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: sendKey))
		sendFrameAsync(try smsg.serializedData(), completion: completion)
	}

	internal func sendTransferSetupFrame(_ frame:Sharing_Nearby_Frame) throws{
		try sendBytesPayload(data: try frame.serializedData(), id: Int64.random(in: Int64.min...Int64.max))
	}

	internal func sendBytesPayload(data:Data, id:Int64) throws{
		var transfer=Location_Nearby_Connections_PayloadTransferFrame()
		transfer.packetType = .data
		transfer.payloadChunk.offset=0
		transfer.payloadChunk.flags=0
		transfer.payloadChunk.body=data
		transfer.payloadHeader.id=id
		transfer.payloadHeader.type = .bytes
		transfer.payloadHeader.totalSize=Int64(transfer.payloadChunk.body.count)
		transfer.payloadHeader.isSensitive=false

		var wrapper=Location_Nearby_Connections_OfflineFrame()
		wrapper.version = .v1
		wrapper.v1=Location_Nearby_Connections_V1Frame()
		wrapper.v1.type = .payloadTransfer
		wrapper.v1.payloadTransfer=transfer
		try encryptAndSendOfflineFrame(wrapper)

		transfer.payloadChunk.flags=1
		transfer.payloadChunk.offset=Int64(transfer.payloadChunk.body.count)
		transfer.payloadChunk.clearBody()
		wrapper.v1.payloadTransfer=transfer
		try encryptAndSendOfflineFrame(wrapper)
	}

	internal func decryptAndProcessReceivedSecureMessage(_ smsg: Securemessage_SecureMessage) throws{
		guard smsg.hasSignature, smsg.hasHeaderAndBody else { throw NearbyError.requiredFieldMissing("secureMessage.signature|headerAndBody") }
		guard let recvKey=recvHmacKey else {throw NearbyError.requiredFieldMissing("recvHmacKey")}
		guard let decKey=decryptKey else {throw NearbyError.requiredFieldMissing("decryptKey")}
		let hmac=Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: recvKey))
		guard hmac==smsg.signature else { throw NearbyError.protocolError("hmac!=signature") }
		let headerAndBody=try Securemessage_HeaderAndBody(serializedData: smsg.headerAndBody)
		var decryptedData=Data(count: headerAndBody.body.count)

		var decryptedLength:Int=0
		let ccStatus=decryptedData.withUnsafeMutableBytes({ (outPtr: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
			guard let outBase=outPtr.baseAddress else {return CCCryptorStatus(kCCParamError)}
			return decKey.withUnsafeBytes({ keyPtr in
				CCCrypt(
					CCOperation(kCCDecrypt),
					CCAlgorithm(kCCAlgorithmAES128),
					CCOptions(kCCOptionPKCS7Padding),
					keyPtr.baseAddress, kCCKeySizeAES256,
					[UInt8](headerAndBody.header.iv),
					[UInt8](headerAndBody.body), headerAndBody.body.count,
					outBase, outPtr.count,
					&decryptedLength
				)
			})
		})
		guard ccStatus==kCCSuccess else {throw NearbyError.protocolError("decrypt failed: \(ccStatus)")}
		decryptedData=decryptedData.prefix(decryptedLength)
		let d2dMsg=try Securegcm_DeviceToDeviceMessage(serializedData: decryptedData)
		guard d2dMsg.hasMessage, d2dMsg.hasSequenceNumber else { throw NearbyError.requiredFieldMissing("d2dMessage.message|sequenceNumber") }
		clientSeq+=1
		guard d2dMsg.sequenceNumber==clientSeq else { throw NearbyError.protocolError("Wrong sequence number. Expected \(clientSeq), got \(d2dMsg.sequenceNumber)") }
		let offlineFrame=try Location_Nearby_Connections_OfflineFrame(serializedData: d2dMsg.message)

		if offlineFrame.hasV1 && offlineFrame.v1.hasType, case .payloadTransfer = offlineFrame.v1.type {
			guard offlineFrame.v1.hasPayloadTransfer else { throw NearbyError.requiredFieldMissing("offlineFrame.v1.payloadTransfer") }
			let payloadTransfer=offlineFrame.v1.payloadTransfer
			let header=payloadTransfer.payloadHeader;
			let chunk=payloadTransfer.payloadChunk;
			guard header.hasType, header.hasID else { throw NearbyError.requiredFieldMissing("payloadHeader.type|id") }
			guard payloadTransfer.hasPayloadChunk, chunk.hasOffset, chunk.hasFlags else { throw NearbyError.requiredFieldMissing("payloadTransfer.payloadChunk|offset|flags") }
			if case .bytes = header.type{
				let payloadID=header.id
				let buffer=try bufferForPayload(id: payloadID, totalSize: header.totalSize)
				guard chunk.offset==Int64(buffer.length) else {
					removePayload(id: payloadID)
					throw NearbyError.protocolError("Unexpected chunk offset \(chunk.offset), expected \(buffer.length)")
				}
				if chunk.hasBody {
					buffer.append(chunk.body)
					touchPayload(id: payloadID)
				}
				if (chunk.flags & 1)==1 {
					removePayload(id: payloadID)
					if !(try processBytesPayload(payload: Data(buffer), id: payloadID)){
						let innerFrame=try Sharing_Nearby_Frame(serializedData: buffer as Data)
						try processTransferSetupFrame(innerFrame)
					}
				}
			}else if case .file = header.type{
				try processFileChunk(frame: payloadTransfer)
			}
		}else if offlineFrame.hasV1 && offlineFrame.v1.hasType, case .keepAlive = offlineFrame.v1.type{
			sendKeepAlive(ack: true)
		}else{
		}
	}

	internal static func pinCodeFromAuthKey(_ key:SymmetricKey) -> String{
		var hash:Int=0
		var multiplier:Int=1
		let keyBytes:[UInt8]=key.withUnsafeBytes({
			return [UInt8]($0)
		})

		for _byte in keyBytes {
			let byte=Int(Int8(bitPattern: _byte))
			hash=(hash+byte*multiplier)%9973
			multiplier=(multiplier*31)%9973
		}

		return String(format: "%04d", abs(hash))
	}

	internal static func sanitizeFileName(_ name:String)->String{
		let clean=name.replacingOccurrences(of: "[\\/\\\\?%\\*:\\|\"<>=]", with: "_", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\\.\\.", with: "_", options: .regularExpression)
		let trimmed=clean.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
		if trimmed.isEmpty{return "file"}
		return String(trimmed.prefix(255))
	}

	internal static func hkdfExtract(salt:Data, ikm:Data) -> Data{
		return HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)).withUnsafeBytes({
			guard let base=$0.baseAddress else {return Data()}
			return Data(bytes: base, count: $0.count)
		})
	}

	internal static func hkdfExpand(prk:Data, info:Data, length:Int) -> Data{
		var okm=Data()
		var t=Data()
		var i=0
		while okm.count<length{
			i=i+1
			let toDigest=t+info+Data([UInt8(truncatingIfNeeded: i)])
			t=HMAC<SHA256>.authenticationCode(for: toDigest, using: SymmetricKey(data: prk)).withUnsafeBytes({
				guard let base=$0.baseAddress else {return Data()}
				return Data(bytes: base, count: $0.count)
			})
			okm=okm+t
		}
		return okm.subdata(in: 0..<length)
	}

	internal static func hkdf(inputKeyMaterial:SymmetricKey, salt:Data, info:Data, outputByteCount:Int) -> SymmetricKey{
		if #available(macOS 11.0, *){
			return HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKeyMaterial, salt: salt, info: info, outputByteCount: outputByteCount)
		}else{
			return SymmetricKey(data: hkdfExpand(prk: hkdfExtract(salt: salt, ikm: inputKeyMaterial.data()), info: info, length: outputByteCount))
		}
	}

	internal func finalizeKeyExchange(peerKey:Securemessage_GenericPublicKey) throws{
		guard peerKey.hasEcP256PublicKey else { throw NearbyError.requiredFieldMissing("peerKey.ecP256PublicKey") }
		guard let priv=privateKey, let cInit=ukeyClientInitMsgData, let sInit=ukeyServerInitMsgData else {
			throw NearbyError.requiredFieldMissing("ukey handshake state")
		}

		let clientX=peerKey.ecP256PublicKey.x
		let clientY=peerKey.ecP256PublicKey.y
		let derivedSecretKey=try ECDomain.sharedSecret(privateKey: priv, peerX: clientX, peerY: clientY)

		var ukeyInfo=Data()
		ukeyInfo.append(cInit)
		ukeyInfo.append(sInit)
		let authString=NearbyConnection.hkdf(inputKeyMaterial: SymmetricKey(data: derivedSecretKey), salt: "UKEY2 v1 auth".data(using: .utf8)!, info: ukeyInfo, outputByteCount: 32)
		let nextSecret=NearbyConnection.hkdf(inputKeyMaterial: SymmetricKey(data: derivedSecretKey), salt: "UKEY2 v1 next".data(using: .utf8)!, info: ukeyInfo, outputByteCount: 32)

		authKey=authString
		pinCode=NearbyConnection.pinCodeFromAuthKey(authString)

		let salt:Data=Data([0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C,
							0xEE, 0x8D, 0x39, 0x09, 0xB9, 0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D,
							0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10])

		let d2dClientKey=NearbyConnection.hkdf(inputKeyMaterial: nextSecret, salt: salt, info: "client".data(using: .utf8)!, outputByteCount: 32)
		let d2dServerKey=NearbyConnection.hkdf(inputKeyMaterial: nextSecret, salt: salt, info: "server".data(using: .utf8)!, outputByteCount: 32)

		var sha2=SHA256()
		sha2.update(data: "SecureMessage".data(using: .utf8)!)
		let smsgSalt=Data(sha2.finalize())

		let clientKey=NearbyConnection.hkdf(inputKeyMaterial: d2dClientKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputByteCount: 32).withUnsafeBytes({[UInt8]($0)})
		let clientHmacKey=NearbyConnection.hkdf(inputKeyMaterial: d2dClientKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputByteCount: 32)
		let serverKey=NearbyConnection.hkdf(inputKeyMaterial: d2dServerKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputByteCount: 32).withUnsafeBytes({[UInt8]($0)})
		let serverHmacKey=NearbyConnection.hkdf(inputKeyMaterial: d2dServerKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputByteCount: 32)

		if isServer(){
			decryptKey=clientKey
			recvHmacKey=clientHmacKey
			encryptKey=serverKey
			sendHmacKey=serverHmacKey
		}else{
			decryptKey=serverKey
			recvHmacKey=serverHmacKey
			encryptKey=clientKey
			sendHmacKey=clientHmacKey
		}
	}

	public func disconnectPublic(){
		disconnectFromOutside()
	}

	private func disconnectFromOutside(){
		connection.cancel()
		markClosed()
		handleConnectionClosure()
	}

	internal func disconnect(){
		markClosed()
		connection.send(content: nil, isComplete: true, completion: .contentProcessed({[weak self] _ in
			self?.handleConnectionClosure()
		}))
	}

	internal func sendDisconnectionAndDisconnect() throws{
		var offlineFrame=Location_Nearby_Connections_OfflineFrame()
		offlineFrame.version = .v1
		offlineFrame.v1.type = .disconnection
		offlineFrame.v1.disconnection=Location_Nearby_Connections_DisconnectionFrame()

		if encryptionDone{
			try encryptAndSendOfflineFrame(offlineFrame)
		}else{
			sendFrameAsync(try offlineFrame.serializedData())
		}
		disconnect()
	}

	internal func sendUkey2Alert(type:Securegcm_Ukey2Alert.AlertType){
		var alert=Securegcm_Ukey2Alert()
		alert.type=type
		var msg=Securegcm_Ukey2Message()
		msg.messageType = .alert
		msg.messageData=(try? alert.serializedData()) ?? Data()
		sendFrameAsync((try? msg.serializedData()) ?? Data())
		disconnect()
	}

	internal func sendKeepAlive(ack:Bool){
		var offlineFrame=Location_Nearby_Connections_OfflineFrame()
		offlineFrame.version = .v1
		offlineFrame.v1.type = .keepAlive
		offlineFrame.v1.keepAlive.ack=ack

		do{
			if encryptionDone{
				try encryptAndSendOfflineFrame(offlineFrame)
			}else{
				sendFrameAsync(try offlineFrame.serializedData())
			}
		}catch{
		}
	}
}

struct InternalFileInfo{
	let meta:FileMetadata
	let payloadID:Int64
	let destinationURL:URL
	var bytesTransferred:Int64=0
	var fileHandle:FileHandle?
	var progress:Progress?
	var created:Bool=false
}
