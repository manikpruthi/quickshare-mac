import Foundation
import Network
import CryptoKit
import CommonCrypto
import System
import AppKit




class InboundNearbyConnection: NearbyConnection{

	private var currentState:State = .initial
	weak var delegate:(any InboundNearbyConnectionDelegate)?
	private var cipherCommitment:Data?

	private var textPayloadID:Int64=0
	private(set) var completedFileURLs:[URL]=[]
	static let maxFiles=50
	static let maxTotalBytes:Int64=2*1024*1024*1024
	static let maxNameCollisions=1000

	enum State{
		case initial, receivedConnectionRequest, sentUkeyServerInit, receivedUkeyClientFinish, sentConnectionResponse, sentPairedKeyResult, receivedPairedKeyResult, waitingForUserConsent, receivingFiles, disconnected
	}

	override init(connection: NWConnection, id:String) {
		super.init(connection: connection, id: id)
	}

	override func noteClosure() {
		currentState = .disconnected
		closeOpenHandles()
		unpublishAllProgress()
		do{
			try deletePartiallyReceivedFiles()
		}catch{
		}
		DispatchQueue.main.async {[weak self] in
			guard let self=self else {return}
			self.delegate?.connectionWasTerminated(connection: self, error: self.lastError)
		}
	}

	private func closeOpenHandles(){
		for id in transferredFiles.keys{
			try? transferredFiles[id]?.fileHandle?.close()
			transferredFiles[id]?.fileHandle=nil
		}
	}

	private func unpublishAllProgress(){
		for id in transferredFiles.keys{
			transferredFiles[id]?.progress?.unpublish()
			transferredFiles[id]?.progress=nil
		}
	}

	override internal func processReceivedFrame(frameData:Data){
		do{
			switch currentState {
			case .initial:
				let frame=try Location_Nearby_Connections_OfflineFrame(serializedData: frameData)
				try processConnectionRequestFrame(frame)
			case .receivedConnectionRequest:
				let msg=try Securegcm_Ukey2Message(serializedData: frameData)
				ukeyClientInitMsgData=frameData
				try processUkey2ClientInit(msg)
			case .sentUkeyServerInit:
				let msg=try Securegcm_Ukey2Message(serializedData: frameData)
				try processUkey2ClientFinish(msg, raw: frameData)
			case .receivedUkeyClientFinish:
				let frame=try Location_Nearby_Connections_OfflineFrame(serializedData: frameData)
				try processConnectionResponseFrame(frame)
			default:
				let smsg=try Securemessage_SecureMessage(serializedData: frameData)
				try decryptAndProcessReceivedSecureMessage(smsg)
			}
		}catch{
			lastError=error
			protocolError()
		}
	}

	override internal func processTransferSetupFrame(_ frame:Sharing_Nearby_Frame) throws{
		if frame.hasV1 && frame.v1.hasType, case .cancel = frame.v1.type {
			try sendDisconnectionAndDisconnect()
			return
		}
		switch currentState{
		case .sentConnectionResponse:
			try processPairedKeyEncryptionFrame(frame)
		case .sentPairedKeyResult:
			try processPairedKeyResultFrame(frame)
		case .receivedPairedKeyResult:
			try processIntroductionFrame(frame)
		default:
			break
		}
	}

	override func isServer() -> Bool {
		return true
	}

	override func processFileChunk(frame: Location_Nearby_Connections_PayloadTransferFrame) throws{
		let id=frame.payloadHeader.id
		guard transferredFiles[id] != nil else { throw NearbyError.protocolError("File payload ID \(id) is not known") }
		let currentOffset=transferredFiles[id]!.bytesTransferred
		guard frame.payloadChunk.offset==currentOffset else { throw NearbyError.protocolError("Invalid offset into file \(frame.payloadChunk.offset), expected \(currentOffset)") }
		let body=frame.payloadChunk.body
		guard currentOffset+Int64(body.count)<=transferredFiles[id]!.meta.size else { throw NearbyError.protocolError("Transferred file size exceeds previously specified value") }
		if body.count>0{
			guard let handle=transferredFiles[id]!.fileHandle else { throw NearbyError.inputOutput }
			try handle.write(contentsOf: body)
			transferredFiles[id]!.bytesTransferred+=Int64(body.count)
			transferredFiles[id]!.progress?.completedUnitCount=transferredFiles[id]!.bytesTransferred
		}
		if (frame.payloadChunk.flags & 1)==1{
			try? transferredFiles[id]?.fileHandle?.close()
			let destURL=transferredFiles[id]?.destinationURL
			transferredFiles[id]?.fileHandle=nil
			transferredFiles[id]?.progress?.unpublish()
			transferredFiles[id]?.progress=nil
			transferredFiles.removeValue(forKey: id)
			if let destURL{
				completedFileURLs.append(destURL)
			}
			if transferredFiles.isEmpty{
				try sendDisconnectionAndDisconnect()
			}
		}
	}

	override func processBytesPayload(payload: Data, id: Int64) throws -> Bool {
		if id==textPayloadID{
			if let urlStr=String(data: payload, encoding: .utf8), let url=URL(string: urlStr),
			   let scheme=url.scheme?.lowercased(), scheme=="http" || scheme=="https"{
				NSWorkspace.shared.open(url)
			}
			try sendDisconnectionAndDisconnect()
			return true
		}else if transferredFiles[id] != nil{
			guard let handle=transferredFiles[id]!.fileHandle else { throw NearbyError.inputOutput }
			try handle.write(contentsOf: payload)
			transferredFiles[id]!.bytesTransferred+=Int64(payload.count)
			transferredFiles[id]!.progress?.completedUnitCount=transferredFiles[id]!.bytesTransferred
			try? transferredFiles[id]?.fileHandle?.close()
			let destURL=transferredFiles[id]?.destinationURL
			transferredFiles[id]?.fileHandle=nil
			transferredFiles[id]?.progress?.unpublish()
			transferredFiles[id]?.progress=nil
			transferredFiles.removeValue(forKey: id)
			if let destURL{
				completedFileURLs.append(destURL)
			}
			try sendDisconnectionAndDisconnect()
			return true
		}
		return false
	}

	private func processConnectionRequestFrame(_ frame:Location_Nearby_Connections_OfflineFrame) throws{
		guard frame.hasV1 && frame.v1.hasConnectionRequest && frame.v1.connectionRequest.hasEndpointInfo else { throw NearbyError.requiredFieldMissing("connectionRequest.endpointInfo") }
		guard case .connectionRequest = frame.v1.type else { throw NearbyError.protocolError("Unexpected frame type \(frame.v1.type)") }
		let endpointInfo=frame.v1.connectionRequest.endpointInfo
		guard endpointInfo.count>17 else { throw NearbyError.protocolError("Endpoint info too short") }
		let deviceNameLength=Int(endpointInfo[17])
		guard endpointInfo.count>=deviceNameLength+18 else { throw NearbyError.protocolError("Endpoint info too short to contain the device name") }
		guard let deviceName=String(data: endpointInfo[18..<(18+deviceNameLength)], encoding: .utf8) else { throw NearbyError.protocolError("Device name is not valid UTF-8") }
		let rawDeviceType:Int=Int(endpointInfo[0] & 7) >> 1
		remoteDeviceInfo=RemoteDeviceInfo(name: deviceName, type: RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType))
		currentState = .receivedConnectionRequest
	}

	private func processUkey2ClientInit(_ msg:Securegcm_Ukey2Message) throws{
		guard msg.hasMessageType, msg.hasMessageData else { throw NearbyError.requiredFieldMissing("clientInit ukey2message.type|data") }
		guard case .clientInit = msg.messageType else{
			sendUkey2Alert(type: .badMessageType)
			throw NearbyError.ukey2
		}
		let clientInit:Securegcm_Ukey2ClientInit
		do{
			clientInit=try Securegcm_Ukey2ClientInit(serializedData: msg.messageData)
		}catch{
			sendUkey2Alert(type: .badMessageData)
			throw NearbyError.ukey2
		}
		guard clientInit.version==1 else{
			sendUkey2Alert(type: .badVersion)
			throw NearbyError.ukey2
		}
		guard clientInit.random.count==32 else{
			sendUkey2Alert(type: .badRandom)
			throw NearbyError.ukey2
		}
		var found=false
		for commitment in clientInit.cipherCommitments{
			if case .p256Sha512 = commitment.handshakeCipher{
				found=true
				cipherCommitment=commitment.commitment
				break
			}
		}
		guard found else{
			sendUkey2Alert(type: .badHandshakeCipher)
			throw NearbyError.ukey2
		}
		guard clientInit.nextProtocol=="AES_256_CBC-HMAC_SHA256" else{
			sendUkey2Alert(type: .badNextProtocol)
			throw NearbyError.ukey2
		}

		let (pubKey, privKey)=ECDomain.makeKeyPair()
		publicKey=pubKey
		privateKey=privKey

		var serverInit=Securegcm_Ukey2ServerInit()
		serverInit.version=1
		serverInit.random=Data.randomData(length: 32)
		serverInit.handshakeCipher = .p256Sha512

		var pkey=Securemessage_GenericPublicKey()
		pkey.type = .ecP256
		pkey.ecP256PublicKey=Securemessage_EcP256PublicKey()
		pkey.ecP256PublicKey.x=signedBytes(pubKey.rawX)
		pkey.ecP256PublicKey.y=signedBytes(pubKey.rawY)
		serverInit.publicKey=try pkey.serializedData()

		var serverInitMsg=Securegcm_Ukey2Message()
		serverInitMsg.messageType = .serverInit
		serverInitMsg.messageData=try serverInit.serializedData()
		let serverInitData=try serverInitMsg.serializedData()
		ukeyServerInitMsgData=serverInitData
		sendFrameAsync(serverInitData)
		currentState = .sentUkeyServerInit
	}

	private func processUkey2ClientFinish(_ msg:Securegcm_Ukey2Message, raw:Data) throws{
		guard msg.hasMessageType, msg.hasMessageData else { throw NearbyError.requiredFieldMissing("clientFinish ukey2message.type|data") }
		guard case .clientFinish = msg.messageType else { throw NearbyError.ukey2 }

		var sha=SHA512()
		sha.update(data: raw)
		guard cipherCommitment==Data(sha.finalize()) else { throw NearbyError.ukey2 }

		let clientFinish=try Securegcm_Ukey2ClientFinished(serializedData: msg.messageData)
		guard clientFinish.hasPublicKey else {throw NearbyError.requiredFieldMissing("ukey2clientFinish.publicKey") }
		let clientKey=try Securemessage_GenericPublicKey(serializedData: clientFinish.publicKey)

		try finalizeKeyExchange(peerKey: clientKey)

		currentState = .receivedUkeyClientFinish
	}

	private func processConnectionResponseFrame(_ frame:Location_Nearby_Connections_OfflineFrame) throws{
		guard frame.hasV1, frame.v1.hasType else { throw NearbyError.requiredFieldMissing("offlineFrame.v1.type") }
		if case .connectionResponse = frame.v1.type {
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

			var pairedEncryption=Sharing_Nearby_Frame()
			pairedEncryption.version = .v1
			pairedEncryption.v1=Sharing_Nearby_V1Frame()
			pairedEncryption.v1.type = .pairedKeyEncryption
			pairedEncryption.v1.pairedKeyEncryption=Sharing_Nearby_PairedKeyEncryptionFrame()
			pairedEncryption.v1.pairedKeyEncryption.secretIDHash=Data.randomData(length: 6)
			pairedEncryption.v1.pairedKeyEncryption.signedData=Data.randomData(length: 72)
			try sendTransferSetupFrame(pairedEncryption)
			currentState = .sentConnectionResponse
		} else {
		}
	}

	private func processPairedKeyEncryptionFrame(_ frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyEncryption else { throw NearbyError.requiredFieldMissing("shareNearbyFrame.v1.pairedKeyEncryption") }
		var pairedResult=Sharing_Nearby_Frame()
		pairedResult.version = .v1
		pairedResult.v1=Sharing_Nearby_V1Frame()
		pairedResult.v1.type = .pairedKeyResult
		pairedResult.v1.pairedKeyResult=Sharing_Nearby_PairedKeyResultFrame()
		pairedResult.v1.pairedKeyResult.status = .unable
		try sendTransferSetupFrame(pairedResult)
		currentState = .sentPairedKeyResult
	}

	private func processPairedKeyResultFrame(_ frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyResult else { throw NearbyError.requiredFieldMissing("shareNearbyFrame.v1.pairedKeyResult") }
		currentState = .receivedPairedKeyResult
	}

	private func makeFileDestinationURL(_ initialDest:URL) -> URL{
		var dest=initialDest
		if FileManager.default.fileExists(atPath: dest.path){
			var counter=1
			var path:String
			let ext=dest.pathExtension
			let baseUrl=dest.deletingPathExtension()
			repeat{
				path="\(baseUrl.path) (\(counter))"
				if !ext.isEmpty{
					path+=".\(ext)"
				}
				counter+=1
				if counter>InboundNearbyConnection.maxNameCollisions{
					dest=dest.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
					break
				}
			}while FileManager.default.fileExists(atPath: path)
			dest=URL(fileURLWithPath: path)
		}
		return dest
	}

	private func processIntroductionFrame(_ frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasIntroduction else { throw NearbyError.requiredFieldMissing("shareNearbyFrame.v1.introduction") }
		guard let device=remoteDeviceInfo else { throw NearbyError.requiredFieldMissing("remoteDeviceInfo") }
		currentState = .waitingForUserConsent
		if frame.v1.introduction.fileMetadata.count>0 && frame.v1.introduction.textMetadata.isEmpty{
			guard frame.v1.introduction.fileMetadata.count<=InboundNearbyConnection.maxFiles else {
				rejectTransfer(with: .unsupportedAttachmentType)
				return
			}
			var total:Int64=0
			for file in frame.v1.introduction.fileMetadata{
				guard file.size>=0 else { throw NearbyError.protocolError("negative file size") }
				total+=file.size
			}
			guard total<=InboundNearbyConnection.maxTotalBytes else {
				rejectTransfer(with: .notEnoughSpace)
				return
			}
			let prefs=QSPreferences.load()
			let downloadsDirectory=prefs.destination.resolvingSymlinksInPath()
			try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
			if let free=(try? FileManager.default.attributesOfFileSystem(forPath: downloadsDirectory.path))?[.systemFreeSize] as? NSNumber,
			   total>free.int64Value{
				rejectTransfer(with: .notEnoughSpace)
				return
			}
			for file in frame.v1.introduction.fileMetadata{
				let clean=NearbyConnection.sanitizeFileName(file.name)
				guard !clean.isEmpty else {
					rejectTransfer(with: .unsupportedAttachmentType)
					return
				}
				let dest=makeFileDestinationURL(downloadsDirectory.appendingPathComponent(clean))
				let info=InternalFileInfo(meta: FileMetadata(name: clean, size: file.size, mimeType: file.mimeType),
										  payloadID: file.payloadID,
										  destinationURL: dest)
				transferredFiles[file.payloadID]=info
			}
			let metadata=TransferMetadata(files: transferredFiles.map({$0.value.meta}), id: id, pinCode: pinCode)
			obtainConsentOnMain(for: metadata, from: device)
		}else if frame.v1.introduction.textMetadata.count==1{
			let meta=frame.v1.introduction.textMetadata[0]
			if case .url=meta.type{
				let metadata=TransferMetadata(files: [], id: id, pinCode: pinCode, textDescription: meta.textTitle)
				textPayloadID=meta.payloadID
				obtainConsentOnMain(for: metadata, from: device)
			}else if case .text=meta.type{
				let prefs=QSPreferences.load()
				let downloadsDirectory=prefs.destination.resolvingSymlinksInPath()
				try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
				let dateFormatter=DateFormatter()
				dateFormatter.dateFormat="yyyy-MM-dd HH.mm.ss"
				let dest=makeFileDestinationURL(downloadsDirectory.appendingPathComponent("\(dateFormatter.string(from: Date())).txt"))
				let info=InternalFileInfo(meta: FileMetadata(name: dest.lastPathComponent, size: meta.size, mimeType: "text/plain"),
										  payloadID: meta.payloadID,
										  destinationURL: dest)
				transferredFiles[meta.payloadID]=info
				obtainConsentOnMain(for: TransferMetadata(files: [info.meta], id: self.id, pinCode: self.pinCode), from: device)
			}else{
				rejectTransfer(with: .unsupportedAttachmentType)
			}
		}else{
			rejectTransfer(with: .unsupportedAttachmentType)
		}
	}

	private func obtainConsentOnMain(for transfer:TransferMetadata, from device:RemoteDeviceInfo){
		DispatchQueue.main.async {[weak self] in
			guard let self=self else {return}
			self.delegate?.obtainUserConsent(for: transfer, from: device, connection: self)
		}
	}

	func submitUserConsent(accepted:Bool){
		peerQueue.async {[weak self] in
			guard let self=self else {return}
			if accepted{
				self.acceptTransfer()
			}else{
				self.rejectTransfer()
			}
		}
	}

	func submitUserConsentDirect(accepted:Bool){
		if accepted{
			self.acceptTransfer()
		}else{
			self.rejectTransfer()
		}
	}

	private func acceptTransfer(){
		do{
			var opened:[FileHandle]=[]
			do{
				for id in transferredFiles.keys{
					guard let dest=transferredFiles[id]?.destinationURL else {continue}
					FileManager.default.createFile(atPath: dest.path, contents: nil)
					let handle=try FileHandle(forWritingTo: dest)
					transferredFiles[id]!.fileHandle=handle
					opened.append(handle)
					let progress=Progress()
					progress.fileURL=dest
					progress.totalUnitCount=transferredFiles[id]!.meta.size
					progress.kind = .file
					progress.isPausable=false
					progress.publish()
					transferredFiles[id]!.progress=progress
					transferredFiles[id]!.created=true
				}
			}catch{
				for h in opened{try? h.close()}
				throw error
			}

			var frame=Sharing_Nearby_Frame()
			frame.version = .v1
			frame.v1.type = .response
			frame.v1.connectionResponse.status = .accept
			currentState = .receivingFiles
			try sendTransferSetupFrame(frame)
		}catch{
			lastError=error
			protocolError()
		}
	}

	private func rejectTransfer(with reason:Sharing_Nearby_ConnectionResponseFrame.Status = .reject){
		var frame=Sharing_Nearby_Frame()
		frame.version = .v1
		frame.v1.type = .response
		frame.v1.connectionResponse.status = reason
		do{
			try sendTransferSetupFrame(frame)
			try sendDisconnectionAndDisconnect()
		}catch{
			protocolError()
		}
	}

	private func deletePartiallyReceivedFiles() throws{
		for (_, file) in transferredFiles{
			try? file.fileHandle?.close()
			guard file.created else { continue }
			try? FileManager.default.removeItem(at: file.destinationURL)
		}
	}
}

protocol InboundNearbyConnectionDelegate: AnyObject{
	func obtainUserConsent(for transfer:TransferMetadata, from device:RemoteDeviceInfo, connection:InboundNearbyConnection)
	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?)
}
