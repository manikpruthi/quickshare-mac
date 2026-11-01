import Foundation
import Network
import CryptoKit
import CommonCrypto
import System
import UniformTypeIdentifiers




class OutboundNearbyConnection:NearbyConnection{
	private var currentState:State = .initial
	private let urlsToSend:[URL]
	private var ukeyClientFinishMsgData:Data?
	private var pendingFiles:[OutgoingFileTransfer]=[]
	private var currentTransfer:OutgoingFileTransfer?
	weak var delegate:(any OutboundNearbyConnectionDelegate)?
	private var totalBytesToSend:Int64=0
	private var totalBytesSent:Int64=0
	private var cancelled:Bool=false
	private var textPayloadID:Int64=0

	public var qrCodePrivateKey:ECPrivateKey?

	enum State{
		case initial, sentUkeyClientInit, sentUkeyClientFinish, sentPairedKeyEncryption, sentPairedKeyResult, sentIntroduction, sendingFiles
	}

	init(connection: NWConnection, id: String, urlsToSend:[URL]){
		self.urlsToSend=urlsToSend
		super.init(connection: connection, id: id)
		if urlsToSend.count==1 && !urlsToSend[0].isFileURL{
			textPayloadID=Int64.random(in: Int64.min...Int64.max)
		}
	}

	deinit {
		if let transfer=currentTransfer, let handle=transfer.handle{
			try? handle.close()
		}
		for transfer in pendingFiles{
			if let handle=transfer.handle{
				try? handle.close()
			}
		}
	}

	public func cancel(){
		cancelled=true
		if encryptionDone{
			var cancel=Sharing_Nearby_Frame()
			cancel.version = .v1
			cancel.v1=Sharing_Nearby_V1Frame()
			cancel.v1.type = .cancel
			try? sendTransferSetupFrame(cancel)
		}
		try? sendDisconnectionAndDisconnect()
	}

	private func closeQueuedHandles(){
		if let transfer=currentTransfer, let handle=transfer.handle{
			try? handle.close()
		}
		currentTransfer=nil
		for transfer in pendingFiles{
			if let handle=transfer.handle{
				try? handle.close()
			}
		}
		pendingFiles.removeAll()
	}

	override func connectionReady() {
		super.connectionReady()
		do{
			try sendConnectionRequest()
			try sendUkey2ClientInit()
		}catch{
			lastError=error
			protocolError()
		}
	}

	override func isServer() -> Bool {
		return false
	}

	override func processReceivedFrame(frameData: Data) {
		do{
			switch currentState {
			case .initial:
				lastError=NearbyError.protocolError("frame before handshake")
				protocolError()
			case .sentUkeyClientInit:
				try processUkey2ServerInit(frame: try Securegcm_Ukey2Message(serializedData: frameData), raw: frameData)
			case .sentUkeyClientFinish:
				try processConnectionResponse(frame: try Location_Nearby_Connections_OfflineFrame(serializedData: frameData))
			default:
				let smsg=try Securemessage_SecureMessage(serializedData: frameData)
				try decryptAndProcessReceivedSecureMessage(smsg)
			}
		}catch{
			if case NearbyError.ukey2=error{
			}else if currentState == .sentUkeyClientInit{
				sendUkey2Alert(type: .badMessage)
			}
			lastError=error
			protocolError()
		}
	}

	override func processTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
		if frame.hasV1 && frame.v1.hasType, case .cancel = frame.v1.type {
			try sendDisconnectionAndDisconnect()
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .userCanceled))
			return
		}
		switch currentState{
		case .sentPairedKeyEncryption:
			try processPairedKeyEncryption(frame: frame)
		case .sentPairedKeyResult:
			try processPairedKeyResult(frame: frame)
		case .sentIntroduction:
			try processConsent(frame: frame)
		case .sendingFiles:
			break
		default:
			throw NearbyError.protocolError("Unexpected state \(currentState)")
		}
	}

	override func protocolError() {
		super.protocolError()
		closeQueuedHandles()
		delegate?.outboundConnection(connection: self, failedWithError: lastError ?? NearbyError.protocolError("unknown"))
	}

	private func sendConnectionRequest() throws {
		var frame=Location_Nearby_Connections_OfflineFrame()
		frame.version = .v1
		frame.v1=Location_Nearby_Connections_V1Frame()
		frame.v1.type = .connectionRequest
		frame.v1.connectionRequest=Location_Nearby_Connections_ConnectionRequestFrame()
		let prefs=QSPreferences.load()
		let deviceName=prefs.deviceName.isEmpty ? (Host.current().localizedName ?? "Mac") : prefs.deviceName
		frame.v1.connectionRequest.endpointID=String(bytes: NearbyConnectionManager.shared.endpointID, encoding: .ascii) ?? "MAC"
		frame.v1.connectionRequest.endpointName=deviceName
		let endpointInfo=EndpointInfo(name: deviceName, deviceType: .computer)
		frame.v1.connectionRequest.endpointInfo=endpointInfo.serialize()
		frame.v1.connectionRequest.mediums=[.wifiLan]
		sendFrameAsync(try frame.serializedData())
	}

	private func sendUkey2ClientInit() throws {
		let (pubKey, privKey)=ECDomain.makeKeyPair()
		publicKey=pubKey
		privateKey=privKey

		var finishFrame=Securegcm_Ukey2Message()
		finishFrame.messageType = .clientFinish
		var finish=Securegcm_Ukey2ClientFinished()
		var pkey=Securemessage_GenericPublicKey()
		pkey.type = .ecP256
		pkey.ecP256PublicKey=Securemessage_EcP256PublicKey()
		pkey.ecP256PublicKey.x=signedBytes(pubKey.rawX)
		pkey.ecP256PublicKey.y=signedBytes(pubKey.rawY)
		finish.publicKey=try pkey.serializedData()
		finishFrame.messageData=try finish.serializedData()
		ukeyClientFinishMsgData=try finishFrame.serializedData()

		var frame=Securegcm_Ukey2Message()
		frame.messageType = .clientInit

		var clientInit=Securegcm_Ukey2ClientInit()
		clientInit.version=1
		clientInit.random=Data.randomData(length: 32)
		clientInit.nextProtocol="AES_256_CBC-HMAC_SHA256"
		var sha=SHA512()
		sha.update(data: ukeyClientFinishMsgData ?? Data())
		var commitment=Securegcm_Ukey2ClientInit.CipherCommitment()
		commitment.commitment=Data(sha.finalize())
		commitment.handshakeCipher = .p256Sha512
		clientInit.cipherCommitments.append(commitment)
		frame.messageData=try clientInit.serializedData()

		ukeyClientInitMsgData=try frame.serializedData()
		sendFrameAsync(ukeyClientInitMsgData!)
		currentState = .sentUkeyClientInit
	}

	private func processUkey2ServerInit(frame:Securegcm_Ukey2Message, raw:Data) throws{
		ukeyServerInitMsgData=raw
		guard frame.messageType == .serverInit else{
			sendUkey2Alert(type: .badMessageType)
			throw NearbyError.ukey2
		}
		let serverInit=try Securegcm_Ukey2ServerInit(serializedData: frame.messageData)
		guard serverInit.version==1 else{
			sendUkey2Alert(type: .badVersion)
			throw NearbyError.ukey2
		}
		guard serverInit.random.count==32 else{
			sendUkey2Alert(type: .badRandom)
			throw NearbyError.ukey2
		}
		guard serverInit.handshakeCipher == .p256Sha512 else{
			sendUkey2Alert(type: .badHandshakeCipher)
			throw NearbyError.ukey2
		}

		let serverKey=try Securemessage_GenericPublicKey(serializedData: serverInit.publicKey)
		try finalizeKeyExchange(peerKey: serverKey)
		guard let clientFinish=ukeyClientFinishMsgData else {throw NearbyError.requiredFieldMissing("ukeyClientFinish")}
		sendFrameAsync(clientFinish)
		currentState = .sentUkeyClientFinish

		var resp=Location_Nearby_Connections_OfflineFrame()
		resp.version = .v1
		resp.v1=Location_Nearby_Connections_V1Frame()
		resp.v1.type = .connectionResponse
		resp.v1.connectionResponse=Location_Nearby_Connections_ConnectionResponseFrame()
		resp.v1.connectionResponse.response = .accept
		resp.v1.connectionResponse.status=0
		resp.v1.connectionResponse.osInfo=Location_Nearby_Connections_OsInfo()
		resp.v1.connectionResponse.osInfo.type = .apple
		sendFrameAsync(try resp.serializedData())

		encryptionDone=true
		delegate?.outboundConnectionWasEstablished(connection: self)
	}

	private func processConnectionResponse(frame:Location_Nearby_Connections_OfflineFrame) throws{
		guard frame.version == .v1 else {throw NearbyError.protocolError("Unexpected offline frame version \(frame.version)")}
		guard frame.v1.type == .connectionResponse else {throw NearbyError.protocolError("Unexpected frame type \(frame.v1.type)")}
		guard frame.v1.connectionResponse.response == .accept else {throw NearbyError.protocolError("Connection was rejected by recipient")}

		var pairedEncryption=Sharing_Nearby_Frame()
		pairedEncryption.version = .v1
		pairedEncryption.v1=Sharing_Nearby_V1Frame()
		pairedEncryption.v1.type = .pairedKeyEncryption
		pairedEncryption.v1.pairedKeyEncryption=Sharing_Nearby_PairedKeyEncryptionFrame()
		pairedEncryption.v1.pairedKeyEncryption.secretIDHash=Data.randomData(length: 6)
		pairedEncryption.v1.pairedKeyEncryption.signedData=Data.randomData(length: 72)
		if let qrKey=qrCodePrivateKey, let auth=authKey{
			if let signature=try? qrKey.sign(msg: auth.data()){
				var serializedSignature=signature.0
				serializedSignature.append(signature.1)
				pairedEncryption.v1.pairedKeyEncryption.qrCodeHandshakeData=serializedSignature
			}
		}
		try sendTransferSetupFrame(pairedEncryption)

		currentState = .sentPairedKeyEncryption
	}

	private func processPairedKeyEncryption(frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyEncryption else { throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.pairedKeyEncryption") }
		var pairedResult=Sharing_Nearby_Frame()
		pairedResult.version = .v1
		pairedResult.v1=Sharing_Nearby_V1Frame()
		pairedResult.v1.type = .pairedKeyResult
		pairedResult.v1.pairedKeyResult=Sharing_Nearby_PairedKeyResultFrame()
		pairedResult.v1.pairedKeyResult.status = .unable
		try sendTransferSetupFrame(pairedResult)
		currentState = .sentPairedKeyResult
	}

	private func processPairedKeyResult(frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyResult else { throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.pairedKeyResult") }

		var introduction=Sharing_Nearby_Frame()
		introduction.version = .v1
		introduction.v1.type = .introduction
		if urlsToSend.count==1 && !urlsToSend[0].isFileURL{
			var meta=Sharing_Nearby_TextMetadata()
			meta.type = .url
			meta.textTitle=urlsToSend[0].host ?? "URL"
			meta.size=Int64(urlsToSend[0].absoluteString.utf8.count)
			meta.payloadID=textPayloadID
			introduction.v1.introduction.textMetadata.append(meta)
		}else{
			for url in urlsToSend{
				guard url.isFileURL else {continue}
				let isDir=(try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
				guard !isDir else {continue}
				var meta=Sharing_Nearby_FileMetadata()
				meta.name=NearbyConnection.sanitizeFileName(url.lastPathComponent)
				let attrs=try FileManager.default.attributesOfItem(atPath: url.path)
				guard let sizeNum=attrs[FileAttributeKey.size] as? NSNumber else {continue}
				meta.size=sizeNum.int64Value
				guard meta.size>=0 else {continue}
				let typeID=try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
				meta.mimeType="application/octet-stream"
				if let typeID=typeID{
					if #available(macOS 11.0, *){
						let type=UTType(typeID)
						if let type=type, let mimeType=type.preferredMIMEType{
							meta.mimeType=mimeType
						}
					}else{
						if let mimeType=UTTypeCopyPreferredTagWithClass(typeID as CFString, kUTTagClassMIMEType){
							meta.mimeType=(mimeType.takeRetainedValue() as NSString) as String
						}
					}
				}
				if meta.mimeType.starts(with: "image/"){
					meta.type = .image
				}else if meta.mimeType.starts(with: "video/"){
					meta.type = .video
				}else if(meta.mimeType.starts(with: "audio/")){
					meta.type = .audio
				}else if(url.pathExtension.lowercased()=="apk"){
					meta.type = .androidApp
				}else{
					meta.type = .unknown
				}
				meta.payloadID=Int64.random(in: Int64.min...Int64.max)
				do{
					let handle=try FileHandle(forReadingFrom: url)
					pendingFiles.append(OutgoingFileTransfer(url: url, payloadID: meta.payloadID, handle: handle, totalBytes: meta.size, currentOffset: 0))
				}catch{
					continue
				}
				introduction.v1.introduction.fileMetadata.append(meta)
				totalBytesToSend+=meta.size
			}
		}
		do{
			try sendTransferSetupFrame(introduction)
		}catch{
			closeQueuedHandles()
			throw error
		}

		currentState = .sentIntroduction
	}

	private func processConsent(frame:Sharing_Nearby_Frame) throws{
		guard frame.version == .v1, frame.v1.type == .response else {throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.type==response")}
		switch frame.v1.connectionResponse.status{
		case .accept:
			currentState = .sendingFiles
			delegate?.outboundConnectionTransferAccepted(connection: self)
			if urlsToSend.count==1 && !urlsToSend[0].isFileURL{
				try sendURL()
			}else{
				try sendNextFileChunk()
			}
		case .reject, .unknown:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .userRejected))
			try sendDisconnectionAndDisconnect()
		case .notEnoughSpace:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .notEnoughSpace))
			try sendDisconnectionAndDisconnect()
		case .timedOut:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .timedOut))
			try sendDisconnectionAndDisconnect()
		case .unsupportedAttachmentType:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .unsupportedType))
			try sendDisconnectionAndDisconnect()
		}
	}

	private func sendURL() throws{
		try sendBytesPayload(data: Data(urlsToSend[0].absoluteString.utf8), id: textPayloadID)
		delegate?.outboundConnectionTransferFinished(connection: self)
		try sendDisconnectionAndDisconnect()
	}

	private func sendNextFileChunk() throws{
		if cancelled{
			return
		}
		if currentTransfer==nil || currentTransfer?.currentOffset==currentTransfer?.totalBytes{
			if currentTransfer != nil && currentTransfer?.handle != nil{
				try? currentTransfer?.handle?.close()
			}
			if pendingFiles.isEmpty{
				try sendDisconnectionAndDisconnect()
				delegate?.outboundConnectionTransferFinished(connection: self)
				return
			}
			currentTransfer=pendingFiles.removeFirst()
		}

		guard let transfer=currentTransfer, let handle=transfer.handle else {
			throw NearbyError.inputOutput
		}

		let fileBuffer:Data
		if #available(macOS 10.15.4, *) {
			guard let _fileBuffer=try handle.read(upToCount: Self.chunkSize) else{
				throw NearbyError.inputOutput
			}
			fileBuffer=_fileBuffer
		} else {
			fileBuffer=handle.readData(ofLength: Self.chunkSize)
		}

		var transferFrame=Location_Nearby_Connections_PayloadTransferFrame()
		transferFrame.packetType = .data
		transferFrame.payloadChunk.offset=transfer.currentOffset
		transferFrame.payloadChunk.flags=0
		transferFrame.payloadChunk.body=fileBuffer
		transferFrame.payloadHeader.id=transfer.payloadID
		transferFrame.payloadHeader.type = .file
		transferFrame.payloadHeader.totalSize=Int64(transfer.totalBytes)
		transferFrame.payloadHeader.isSensitive=false
		currentTransfer!.currentOffset+=Int64(fileBuffer.count)

		var wrapper=Location_Nearby_Connections_OfflineFrame()
		wrapper.version = .v1
		wrapper.v1=Location_Nearby_Connections_V1Frame()
		wrapper.v1.type = .payloadTransfer
		wrapper.v1.payloadTransfer=transferFrame
		try encryptAndSendOfflineFrame(wrapper, completion: {[weak self] in
			guard let self=self else {return}
			do{
				try self.sendNextFileChunk()
			}catch{
				self.lastError=error
				self.protocolError()
			}
		})
		totalBytesSent+=Int64(fileBuffer.count)
		let denom=max(totalBytesToSend, 1)
		delegate?.outboundConnection(connection: self, transferProgress: min(1, Double(totalBytesSent)/Double(denom)))

		if currentTransfer!.currentOffset==currentTransfer!.totalBytes{
			var endFrame=Location_Nearby_Connections_PayloadTransferFrame()
			endFrame.packetType = .data
			endFrame.payloadChunk.offset=currentTransfer!.currentOffset
			endFrame.payloadChunk.flags=1
			endFrame.payloadHeader.id=currentTransfer!.payloadID
			endFrame.payloadHeader.type = .file
			endFrame.payloadHeader.totalSize=Int64(currentTransfer!.totalBytes)
			endFrame.payloadHeader.isSensitive=false

			var endWrapper=Location_Nearby_Connections_OfflineFrame()
			endWrapper.version = .v1
			endWrapper.v1=Location_Nearby_Connections_V1Frame()
			endWrapper.v1.type = .payloadTransfer
			endWrapper.v1.payloadTransfer=endFrame
			try encryptAndSendOfflineFrame(endWrapper)
		}
	}

	private static let chunkSize=512*1024
}

fileprivate struct OutgoingFileTransfer{
	let url:URL
	let payloadID:Int64
	let handle:FileHandle?
	let totalBytes:Int64
	var currentOffset:Int64
}

protocol OutboundNearbyConnectionDelegate: AnyObject{
	func outboundConnectionWasEstablished(connection:OutboundNearbyConnection)
	func outboundConnection(connection:OutboundNearbyConnection, transferProgress:Double)
	func outboundConnectionTransferAccepted(connection:OutboundNearbyConnection)
	func outboundConnection(connection:OutboundNearbyConnection, failedWithError:Error)
	func outboundConnectionTransferFinished(connection:OutboundNearbyConnection)
}
