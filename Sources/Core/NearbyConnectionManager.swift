import Foundation
import Network
import System
import CryptoKit


public struct RemoteDeviceInfo{
	public let name:String
	public let type:DeviceType
	public let qrCodeData:Data?
	public var id:String?

	init(name: String, type: DeviceType, id: String? = nil) {
		self.name = name
		self.type = type
		self.id = id
		self.qrCodeData = nil
	}

	init(info:EndpointInfo, id: String? = nil){
		self.name=info.name ?? "Android device"
		self.type=info.deviceType
		self.qrCodeData=info.qrCodeData
		self.id=id
	}

	public enum DeviceType:Int32{
		case unknown=0
		case phone
		case tablet
		case computer

		public static func fromRawValue(value:Int) -> DeviceType{
			switch value {
			case 0:
				return .unknown
			case 1:
				return .phone
			case 2:
				return .tablet
			case 3:
				return .computer
			default:
				return .unknown
			}
		}
	}
}


public enum NearbyError:Error{
	case protocolError(_ message:String)
	case requiredFieldMissing(_ message:String)
	case ukey2
	case inputOutput
	case canceled(reason:CancellationReason)

	public enum CancellationReason{
		case userRejected, userCanceled, notEnoughSpace, unsupportedType, timedOut
	}
}

public struct TransferMetadata{
	public let files:[FileMetadata]
	public let id:String
	public let pinCode:String?
	public let textDescription:String?

	init(files: [FileMetadata], id: String, pinCode: String?, textDescription: String?=nil){
		self.files = files
		self.id = id
		self.pinCode = pinCode
		self.textDescription = textDescription
	}
}

public struct FileMetadata{
	public let name:String
	public let size:Int64
	public let mimeType:String
}

struct FoundServiceInfo{
	var service:NWBrowser.Result
	var device:RemoteDeviceInfo?
	var lastSeen:Date
}

private class WeakShareDelegate {
	weak var value:(any ShareExtensionDelegate)?
	init(_ v:(any ShareExtensionDelegate)){value=v}
}


struct OutgoingTransferInfo{
	let service:NWBrowser.Result
	let device:RemoteDeviceInfo
	let connection:OutboundNearbyConnection
	let delegate:ShareExtensionDelegate
}

struct EndpointInfo{
	var name:String?
	let deviceType:RemoteDeviceInfo.DeviceType
	let qrCodeData:Data?

	init(name: String, deviceType: RemoteDeviceInfo.DeviceType){
		self.name = name
		self.deviceType = deviceType
		self.qrCodeData=nil
	}

	init?(data:Data){
		guard data.count>17 else {return nil}
		let hasName=(data[0] & 0x10)==0
		let deviceNameLength:Int
		let deviceName:String?
		if hasName{
			deviceNameLength=Int(data[17])
			guard data.count>=deviceNameLength+18 else {return nil}
			guard let _deviceName=String(data: data[18..<(18+deviceNameLength)], encoding: .utf8) else {return nil}
			deviceName=_deviceName
		}else{
			deviceNameLength=0
			deviceName=nil
		}
		let rawDeviceType:Int=Int(data[0] & 7) >> 1
		self.name=deviceName
		self.deviceType=RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType)
		var offset=1+16
		if hasName{
			offset=offset+1+deviceNameLength
		}
		var qrCodeData:Data?=nil
		while data.count-offset>2{
			let type=data[offset]
			let length=Int(data[offset+1])
			offset=offset+2
			if data.count-offset>=length{
				if type==1{
					qrCodeData=data.subdata(in: offset..<offset+length)
				}
				offset=offset+length
			}
		}
		self.qrCodeData=qrCodeData
	}

	func serialize()->Data{
		var endpointInfo:[UInt8]=[UInt8(deviceType.rawValue << 1)]
		for _ in 0...15{
			endpointInfo.append(UInt8.random(in: 0...255))
		}
		var nameChars=[UInt8]((name ?? "Mac").utf8)
		if nameChars.count>255{
			nameChars=[UInt8](nameChars[0..<255])
		}
		endpointInfo.append(UInt8(nameChars.count))
		for ch in nameChars{
			endpointInfo.append(UInt8(ch))
		}
		return Data(endpointInfo)
	}
}

public protocol MainAppDelegate: AnyObject {
	func obtainUserConsent(for transfer:TransferMetadata, from device:RemoteDeviceInfo)
	func incomingTransfer(id:String, didFinishWith error:Error?, files:[URL])
}

public protocol ShareExtensionDelegate:AnyObject{
	func addDevice(device:RemoteDeviceInfo)
	func removeDevice(id:String)
	func startTransferWithQrCode(device:RemoteDeviceInfo)
	func connectionWasEstablished(pinCode:String)
	func connectionFailed(with error:Error)
	func transferAccepted()
	func transferProgress(progress:Double)
	func transferFinished()
}

public class NearbyConnectionManager : NSObject, NetServiceDelegate, InboundNearbyConnectionDelegate, OutboundNearbyConnectionDelegate{

	private var tcpListener:NWListener?
	private var isVisible=false
	public let endpointID:[UInt8]=generateEndpointID()
	private var mdnsService:NetService?
	private var activeConnections:[String:InboundNearbyConnection]=[:]
	private var foundServices:[String:FoundServiceInfo]=[:]
	private var shareExtensionDelegates:[WeakShareDelegate]=[]
	private var outgoingTransfers:[String:OutgoingTransferInfo]=[:]
	public weak var mainAppDelegate:(any MainAppDelegate)?
	private var discoveryRefCount=0
	private var discoveryIdleTimer:DispatchWorkItem?
	private let stateLock=NSLock()

	private static let maxFoundDevices=64
	private static let discoveryTimeout:TimeInterval=120

	private var browser:NWBrowser?
	private var staleSweepTimer:DispatchSourceTimer?

	private var qrCodePublicKey:ECPublicKey?
	private var qrCodePrivateKey:ECPrivateKey?
	private var qrCodeAdvertisingToken:Data?
	private var qrCodeNameEncryptionKey:SymmetricKey?
	private var qrCodeData:Data?

	public static let shared=NearbyConnectionManager()

	override init() {
		super.init()
		tcpListener=try? NWListener(using: NWParameters(tls: .none))
	}

	public func becomeVisible(){
		guard !isVisible else {return}
		if tcpListener==nil{
			tcpListener=try? NWListener(using: NWParameters(tls: .none))
		}
		guard tcpListener != nil else {return}
		isVisible=true
		startTCPListener()
	}

	public func stopVisible(){
		guard isVisible else {return}
		isVisible=false
		tcpListener?.cancel()
		tcpListener=nil
		mdnsService?.stop()
		mdnsService = nil
		stateLock.lock()
		let conns=Array(activeConnections.values)
		stateLock.unlock()
		for conn in conns {
			conn.disconnectPublic()
		}
		stateLock.lock()
		activeConnections.removeAll()
		stateLock.unlock()
	}

	private func startTCPListener(){
		guard let listener=tcpListener else {return}
		listener.stateUpdateHandler={[weak self] (state:NWListener.State) in
			if case .ready = state {
				self?.initMDNS()
			}
		}
		listener.newConnectionHandler={[weak self] (connection:NWConnection) in
			guard let self=self else {return}
			let id=UUID().uuidString
			let conn=InboundNearbyConnection(connection: connection, id: id)
			self.stateLock.lock()
			self.activeConnections[id]=conn
			self.stateLock.unlock()
			conn.delegate=self
			conn.start()
		}
		listener.start(queue: .global(qos: .utility))
	}

	private static func generateEndpointID()->[UInt8]{
		let alphabet=Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
		var id:[UInt8]=[]
		for _ in 0...3{
			id.append(alphabet[Int.random(in: 0..<alphabet.count)])
		}
		return id
	}

	private func initMDNS(){
		let nameBytes:[UInt8]=[
			0x23,
			endpointID[0], endpointID[1], endpointID[2], endpointID[3],
			0xFC, 0x9F, 0x5E,
			0, 0
		]
		let name=Data(nameBytes).urlSafeBase64EncodedString()
		let deviceName=QSPreferences.load().deviceName.isEmpty ? (Host.current().localizedName ?? "Mac") : QSPreferences.load().deviceName
		let endpointInfo=EndpointInfo(name: deviceName, deviceType: .computer)

		guard let port=tcpListener?.port else {return}
		let portNum:Int32=Int32(port.rawValue)
		mdnsService?.stop()
		mdnsService=NetService(domain: "", type: "_FC9F5ED42C8A._tcp.", name: name, port: portNum)
		mdnsService?.delegate=self
		if let txt=endpointInfo.serialize().urlSafeBase64EncodedString().data(using: .utf8){
			mdnsService?.setTXTRecord(NetService.data(fromTXTRecord: ["n": txt]))
		}
		mdnsService?.publish()
	}

	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
		guard let delegate=mainAppDelegate else {return}
		delegate.obtainUserConsent(for: transfer, from: device)
	}

	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?){
		stateLock.lock()
		activeConnections.removeValue(forKey: connection.id)
		stateLock.unlock()
		guard let delegate=mainAppDelegate else {return}
		delegate.incomingTransfer(id: connection.id, didFinishWith: error, files: connection.completedFileURLs)
	}

	public func submitUserConsent(transferID:String, accept:Bool){
		stateLock.lock()
		let conn=activeConnections[transferID]
		stateLock.unlock()
		guard let conn else {return}
		conn.submitUserConsent(accepted: accept)
	}

	public func startDeviceDiscovery(){
		if discoveryRefCount==0{
			stateLock.lock()
			foundServices.removeAll()
			stateLock.unlock()
			if browser==nil{
				browser=NWBrowser(for: .bonjourWithTXTRecord(type: "_FC9F5ED42C8A._tcp.", domain: nil), using: .tcp)
				browser?.browseResultsChangedHandler={[weak self] newResults, changes in
					guard let self=self else {return}
					for change in changes{
						switch change{
						case let .added(res):
							self.maybeAddFoundDevice(service: res)
						case let .changed(_, newResult, _):
							self.maybeAddFoundDevice(service: newResult)
						case let .removed(res):
							self.maybeRemoveFoundDevice(service: res)
						default:
							break
						}
					}
					_ = newResults
				}
			}
			browser?.start(queue: .main)
			scheduleDiscoveryTimeout()
			startStaleSweep()
		}
		discoveryRefCount+=1
	}

	public func stopDeviceDiscovery(){
		guard discoveryRefCount>0 else {return}
		discoveryRefCount-=1
		if discoveryRefCount==0{
			discoveryIdleTimer?.cancel()
			discoveryIdleTimer=nil
			browser?.cancel()
			browser=nil
			stopStaleSweep()
		}
	}

	private func startStaleSweep(){
		stopStaleSweep()
		let timer=DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now()+15, repeating: 15)
		timer.setEventHandler{[weak self] in self?.sweepStaleDevices()}
		timer.resume()
		staleSweepTimer=timer
	}

	private func stopStaleSweep(){
		staleSweepTimer?.cancel()
		staleSweepTimer=nil
	}

	private func sweepStaleDevices(){
		let cutoff=Date().addingTimeInterval(-30)
		stateLock.lock()
		var expired:[String]=[]
		for (id, info) in foundServices where info.lastSeen<cutoff{
			expired.append(id)
		}
		for id in expired{
			foundServices.removeValue(forKey: id)
		}
		stateLock.unlock()
		for id in expired{
			for delegate in liveDelegates(){
				delegate.removeDevice(id: id)
			}
		}
	}

	private func scheduleDiscoveryTimeout(){
		discoveryIdleTimer?.cancel()
		let item=DispatchWorkItem{[weak self] in
			guard let self=self else {return}
			self.stateLock.lock()
			var count=0
			for holder in self.shareExtensionDelegates{
				if holder.value != nil{count+=1}
			}
			self.stateLock.unlock()
			if count==0{
				while self.discoveryRefCount>0{
					self.stopDeviceDiscovery()
				}
			}else{
				self.scheduleDiscoveryTimeout()
			}
		}
		discoveryIdleTimer=item
		DispatchQueue.main.asyncAfter(deadline: .now()+NearbyConnectionManager.discoveryTimeout, execute: item)
	}

	private func liveDelegates()->[any ShareExtensionDelegate]{
		shareExtensionDelegates=shareExtensionDelegates.filter({$0.value != nil})
		return shareExtensionDelegates.compactMap({$0.value})
	}

	public func addShareExtensionDelegate(_ delegate:ShareExtensionDelegate){
		if !shareExtensionDelegates.contains(where: {$0.value===delegate}){
			shareExtensionDelegates.append(WeakShareDelegate(delegate))
		}
		stateLock.lock()
		let services=Array(foundServices.values)
		stateLock.unlock()
		for service in services{
			guard let device=service.device else {continue}
			delegate.addDevice(device: device)
		}
	}

	public func removeShareExtensionDelegate(_ delegate:ShareExtensionDelegate){
		shareExtensionDelegates.removeAll(where: {$0.value==nil || $0.value===delegate})
	}

	public func cancelOutgoingTransfer(id:String){
		stateLock.lock()
		let transfer=outgoingTransfers.removeValue(forKey: id)
		stateLock.unlock()
		guard let transfer else {return}
		transfer.connection.cancel()
	}

	private func endpointID(for service:NWBrowser.Result)->String?{
		guard case let NWEndpoint.service(name: serviceName, type: _, domain: _, interface: _)=service.endpoint else {return nil}
		guard let nameData=Data.dataFromUrlSafeBase64(serviceName) else {return nil}
		guard nameData.count>=10 else {return nil}
		let pcp=nameData[0]
		guard pcp==0x23 else {return nil}
		guard let endpointID=String(data: nameData.subdata(in: 1..<5), encoding: .ascii) else {return nil}
		let serviceIDHash=nameData.subdata(in: 5..<8)
		guard serviceIDHash==Data([0xFC, 0x9F, 0x5E]) else {return nil}
		return endpointID
	}

	private func maybeAddFoundDevice(service:NWBrowser.Result){
		let hasNetworkInterface=service.interfaces.contains{
			if case .loopback=$0.type{return false}
			return true
		}
		guard hasNetworkInterface else{return}
		guard let endpointID=endpointID(for: service) else {return}
		guard endpointID != String(bytes: self.endpointID, encoding: .ascii) else {return}

		guard case let NWBrowser.Result.Metadata.bonjour(txtRecord)=service.metadata else {
			touchDevice(endpointID: endpointID, service: service)
			return
		}
		guard let endpointInfoEncoded=txtRecord.dictionary["n"] else {
			touchDevice(endpointID: endpointID, service: service)
			return
		}
		guard let endpointInfoSerialized=Data.dataFromUrlSafeBase64(endpointInfoEncoded) else {return}
		guard var endpointInfo=EndpointInfo(data: endpointInfoSerialized) else {return}

		stateLock.lock()
		if var existing=foundServices[endpointID]{
			existing.lastSeen=Date()
			if existing.device==nil, endpointInfo.name != nil{
				stateLock.unlock()
				_ = addFoundDevice(service: service, endpointInfo: endpointInfo, endpointID: endpointID)
				return
			}
			foundServices[endpointID]=existing
			stateLock.unlock()
			return
		}
		stateLock.unlock()

		var deviceInfo:RemoteDeviceInfo?
		if endpointInfo.name != nil{
			deviceInfo=addFoundDevice(service: service, endpointInfo: endpointInfo, endpointID: endpointID)
		}else{
			stateLock.lock()
			if foundServices.count<NearbyConnectionManager.maxFoundDevices{
				foundServices[endpointID]=FoundServiceInfo(service: service, device: nil, lastSeen: Date())
			}
			stateLock.unlock()
		}

		if let qrData=endpointInfo.qrCodeData, let token=qrCodeAdvertisingToken, let encKey=qrCodeNameEncryptionKey{
			if qrData==token{
				if let deviceInfo{
					for delegate in liveDelegates(){
						delegate.startTransferWithQrCode(device: deviceInfo)
					}
				}
			}else if qrData.count>28{
				do{
					let box=try AES.GCM.SealedBox(combined: qrData)
					let decryptedName=try AES.GCM.open(box, using: encKey, authenticating: token)
					guard let name=String.init(data: decryptedName, encoding: .utf8) else {return}
					endpointInfo.name=name
					let deviceInfo=addFoundDevice(service: service, endpointInfo: endpointInfo, endpointID: endpointID)
					for delegate in liveDelegates(){
						delegate.startTransferWithQrCode(device: deviceInfo)
					}
				}catch{
				}
			}
		}
	}

	private func addFoundDevice(service:NWBrowser.Result, endpointInfo:EndpointInfo, endpointID:String) -> RemoteDeviceInfo{
		let deviceInfo=RemoteDeviceInfo(info: endpointInfo, id: endpointID)
		stateLock.lock()
		if foundServices.count>=NearbyConnectionManager.maxFoundDevices, foundServices[endpointID]==nil{
			if let oldest=foundServices.min(by: {$0.value.lastSeen<$1.value.lastSeen}){
				foundServices.removeValue(forKey: oldest.key)
			}
		}
		var foundService=foundServices[endpointID] ?? FoundServiceInfo(service: service, device: nil, lastSeen: Date())
		foundService.device=deviceInfo
		foundService.lastSeen=Date()
		foundServices[endpointID]=foundService
		stateLock.unlock()
		for delegate in liveDelegates(){
			delegate.addDevice(device: deviceInfo)
		}
		return deviceInfo
	}

	private func touchDevice(endpointID:String, service:NWBrowser.Result){
		stateLock.lock()
		if foundServices[endpointID] != nil{
			foundServices[endpointID]?.lastSeen=Date()
			foundServices[endpointID]?.service=service
		}
		stateLock.unlock()
	}

	private func maybeRemoveFoundDevice(service:NWBrowser.Result){
		guard let endpointID=endpointID(for: service) else {return}
		stateLock.lock()
		guard foundServices.removeValue(forKey: endpointID) != nil else {
			stateLock.unlock()
			return
		}
		stateLock.unlock()
		for delegate in liveDelegates() {
			delegate.removeDevice(id: endpointID)
		}
	}

	public func generateQrCodeKey() -> String{
		let (pubKey, privKey)=ECDomain.makeKeyPair()
		qrCodePublicKey=pubKey
		qrCodePrivateKey=privKey
		var keyData=Data()
		keyData.append(contentsOf: [0, 0, 2])
		let keyBytes=signedBytes(pubKey.rawX)
		keyData.append(keyBytes.suffixOfAtMost(numBytes: 32))

		let ikm=SymmetricKey(data: keyData)
		qrCodeAdvertisingToken=NearbyConnection.hkdf(inputKeyMaterial: ikm, salt: Data(), info: "advertisingContext".data(using: .utf8)!, outputByteCount: 16).data()
		qrCodeNameEncryptionKey=NearbyConnection.hkdf(inputKeyMaterial: ikm, salt: Data(), info: "encryptionKey".data(using: .utf8)!, outputByteCount: 16)
		qrCodeData=keyData

		return keyData.urlSafeBase64EncodedString()
	}

	public func clearQrCodeKey(){
		qrCodePublicKey=nil
		qrCodePrivateKey=nil
		qrCodeAdvertisingToken=nil
		qrCodeNameEncryptionKey=nil
		qrCodeData=nil
	}

	public func startOutgoingTransfer(deviceID:String, delegate:ShareExtensionDelegate, urls:[URL]){
		stateLock.lock()
		let info=foundServices[deviceID]
		stateLock.unlock()
		guard let info else {return}
		guard let device=info.device else {return}
		let tcp=NWProtocolTCP.Options.init()
		tcp.noDelay=true
		let nwconn=NWConnection(to: info.service.endpoint, using: NWParameters(tls: .none, tcp: tcp))
		let conn=OutboundNearbyConnection(connection: nwconn, id: deviceID, urlsToSend: urls)
		conn.delegate=self
		conn.qrCodePrivateKey=qrCodePrivateKey
		let transfer=OutgoingTransferInfo(service: info.service, device: device, connection: conn, delegate: delegate)
		stateLock.lock()
		outgoingTransfers[deviceID]=transfer
		stateLock.unlock()
		conn.start()
	}

	func outboundConnectionWasEstablished(connection: OutboundNearbyConnection) {
		stateLock.lock()
		let transfer=outgoingTransfers[connection.id]
		stateLock.unlock()
		guard let transfer else {return}
		guard let pin=connection.pinCode else {return}
		DispatchQueue.main.async {
			transfer.delegate.connectionWasEstablished(pinCode: pin)
		}
	}

	func outboundConnectionTransferAccepted(connection: OutboundNearbyConnection) {
		stateLock.lock()
		let transfer=outgoingTransfers[connection.id]
		stateLock.unlock()
		guard let transfer else {return}
		DispatchQueue.main.async {
			transfer.delegate.transferAccepted()
		}
	}

	func outboundConnection(connection: OutboundNearbyConnection, transferProgress: Double) {
		stateLock.lock()
		let transfer=outgoingTransfers[connection.id]
		stateLock.unlock()
		guard let transfer else {return}
		DispatchQueue.main.async {
			transfer.delegate.transferProgress(progress: transferProgress)
		}
	}

	func outboundConnection(connection: OutboundNearbyConnection, failedWithError: Error) {
		stateLock.lock()
		let transfer=outgoingTransfers.removeValue(forKey: connection.id)
		stateLock.unlock()
		guard let transfer else {return}
		DispatchQueue.main.async {
			transfer.delegate.connectionFailed(with: failedWithError)
		}
	}

	func outboundConnectionTransferFinished(connection: OutboundNearbyConnection) {
		stateLock.lock()
		let transfer=outgoingTransfers.removeValue(forKey: connection.id)
		stateLock.unlock()
		guard let transfer else {return}
		DispatchQueue.main.async {
			transfer.delegate.transferFinished()
		}
	}
}
