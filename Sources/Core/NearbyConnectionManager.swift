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

	// Nearby Connections drops endpoint info longer than 131 bytes: header(1) + salt/key hash(16) + length(1) + name.
	static let maxSerializedLength=131
	static let maxNameBytes=maxSerializedLength-18

	func serialize()->Data{
		var endpointInfo:[UInt8]=[UInt8(deviceType.rawValue << 1)]
		for _ in 0...15{
			endpointInfo.append(UInt8.random(in: 0...255))
		}
		let nameChars=EndpointInfo.truncatedUTF8(name ?? "Mac", maxBytes: EndpointInfo.maxNameBytes)
		endpointInfo.append(UInt8(nameChars.count))
		endpointInfo.append(contentsOf: nameChars)
		return Data(endpointInfo)
	}

	// Cuts on a character boundary so a long name never ends in a broken UTF-8 sequence.
	static func truncatedUTF8(_ string:String, maxBytes:Int)->[UInt8]{
		var out:[UInt8]=[]
		for ch in string{
			let bytes=Array(String(ch).utf8)
			if out.count+bytes.count>maxBytes{break}
			out.append(contentsOf: bytes)
		}
		return out
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
	private static let staleSweepInterval:TimeInterval=5
	private static let staleDeviceTTL:TimeInterval=12
	private static let liveProbeTimeout:TimeInterval=4
	// Longest a live device can go without a refreshed lastSeen: TTL, then up to one sweep tick, then the probe itself.
	private static let staleSendWindow:TimeInterval=staleDeviceTTL+staleSweepInterval+liveProbeTimeout

	private var browser:NWBrowser?
	private var staleSweepTimer:DispatchSourceTimer?
	private var probingDevices:Set<String>=[]

	private var qrCodePublicKey:ECPublicKey?
	private var qrCodePrivateKey:ECPrivateKey?
	private var qrCodeAdvertisingToken:Data?
	private var qrCodeNameEncryptionKey:SymmetricKey?
	private var qrCodeData:Data?

	private var pathMonitor:NWPathMonitor?
	private var lanInterfaceOrder:[String]=[]
	private var advertisedEndpointInfo:Data?
	private var advertisedIPv4:String?

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
		startPathMonitor()
		startTCPListener()
	}

	public func stopVisible(){
		guard isVisible else {return}
		isVisible=false
		pathMonitor?.cancel()
		pathMonitor=nil
		tcpListener?.cancel()
		tcpListener=nil
		mdnsService?.stop()
		mdnsService = nil
		advertisedEndpointInfo=nil
		advertisedIPv4=nil
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
		listener.stateUpdateHandler={[weak self, weak listener] (state:NWListener.State) in
			if case .ready = state {
				// NetService needs a running run loop for its callbacks and later TXT updates.
				DispatchQueue.main.async {
					guard let listener else {return}
					guard let self=self, self.isVisible, self.tcpListener===listener else {return}
					self.initMDNS()
				}
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
		let prefsName=QSPreferences.load().deviceName
		let deviceName=prefsName.isEmpty ? (Host.current().localizedName ?? "Mac") : prefsName
		let endpointInfo=EndpointInfo(name: deviceName, deviceType: .computer).serialize()

		guard let port=tcpListener?.port else {return}
		let portNum:Int32=Int32(port.rawValue)
		mdnsService?.stop()
		mdnsService=NetService(domain: "", type: "_FC9F5ED42C8A._tcp.", name: name, port: portNum)
		mdnsService?.delegate=self
		advertisedEndpointInfo=endpointInfo
		advertisedIPv4=NearbyConnectionManager.lanIPv4Address(preferredInterfaces: lanInterfaceOrder)
		mdnsService?.setTXTRecord(currentTXTRecord())
		mdnsService?.publish()
	}

	// Google's own Quick Share publishes the receiver's LAN address as TXT "IPv4" and falls back to it
	// when the host's A record doesn't resolve; current Pixel builds expect it.
	private func currentTXTRecord()->Data{
		var txt:[String:Data]=[:]
		if let info=advertisedEndpointInfo, let n=info.urlSafeBase64EncodedString().data(using: .utf8){
			txt["n"]=n
		}
		if let ip=advertisedIPv4, let v=ip.data(using: .utf8){
			txt["IPv4"]=v
		}
		return NetService.data(fromTXTRecord: txt)
	}

	private func startPathMonitor(){
		pathMonitor?.cancel()
		let monitor=NWPathMonitor()
		monitor.pathUpdateHandler={[weak self] path in
			guard let self=self, self.isVisible else {return}
			self.lanInterfaceOrder=path.availableInterfaces
				.filter{$0.type == .wifi || $0.type == .wiredEthernet}
				.map{$0.name}
			self.refreshAdvertisedAddress()
		}
		pathMonitor=monitor
		monitor.start(queue: .main)
	}

	// Keeps TXT "IPv4" right after a Wi-Fi switch or DHCP renewal without re-registering the service.
	private func refreshAdvertisedAddress(){
		guard let service=mdnsService, advertisedEndpointInfo != nil else {return}
		let ip=NearbyConnectionManager.lanIPv4Address(preferredInterfaces: lanInterfaceOrder)
		guard ip != advertisedIPv4 else {return}
		advertisedIPv4=ip
		service.setTXTRecord(currentTXTRecord())
	}

	// First usable IPv4 on a Wi-Fi/Ethernet interface, in the system's preference order.
	static func lanIPv4Address(preferredInterfaces:[String])->String?{
		var head:UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head)==0, let first=head else {return nil}
		defer{freeifaddrs(head)}
		var byInterface:[String:String]=[:]
		var fallback:String?
		for ptr in sequence(first: first, next: {$0.pointee.ifa_next}){
			let ifa=ptr.pointee
			guard let addr=ifa.ifa_addr, addr.pointee.sa_family==sa_family_t(AF_INET) else {continue}
			let flags=Int32(ifa.ifa_flags)
			guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else {continue}
			var sin=sockaddr_in()
			memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
			var buf=[CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
			guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {continue}
			let ip=String(cString: buf)
			guard !ip.hasPrefix("169.254.") else {continue}
			let name=String(cString: ifa.ifa_name)
			if byInterface[name]==nil{byInterface[name]=ip}
			if fallback==nil, name.hasPrefix("en"){fallback=ip}
		}
		for name in preferredInterfaces{
			if let ip=byInterface[name]{return ip}
		}
		return fallback
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
		timer.schedule(deadline: .now()+NearbyConnectionManager.staleSweepInterval, repeating: NearbyConnectionManager.staleSweepInterval)
		timer.setEventHandler{[weak self] in self?.sweepStaleDevices()}
		timer.resume()
		staleSweepTimer=timer
	}

	private func stopStaleSweep(){
		staleSweepTimer?.cancel()
		staleSweepTimer=nil
	}

	// NWBrowser only reports changes, so a phone that keeps advertising unchanged never refreshes
	// lastSeen. Instead of evicting on age alone, probe devices past the TTL and drop only unreachable ones.
	private func sweepStaleDevices(){
		let cutoff=Date().addingTimeInterval(-NearbyConnectionManager.staleDeviceTTL)
		stateLock.lock()
		var due:[(String, NWEndpoint)]=[]
		for (id, info) in foundServices where info.lastSeen<cutoff && !probingDevices.contains(id){
			probingDevices.insert(id)
			due.append((id, info.service.endpoint))
		}
		stateLock.unlock()
		for (id, endpoint) in due{
			probeLiveness(endpointID: id, endpoint: endpoint)
		}
	}

	private func probeLiveness(endpointID:String, endpoint:NWEndpoint){
		let tcp=NWProtocolTCP.Options.init()
		tcp.connectionTimeout=Int(NearbyConnectionManager.liveProbeTimeout)
		let conn=NWConnection(to: endpoint, using: NWParameters(tls: .none, tcp: tcp))
		let startedAt=Date()
		var finished=false
		let finish:(Bool)->Void={[weak self] alive in
			guard !finished else {return}
			finished=true
			conn.cancel()
			guard let self=self else {return}
			self.stateLock.lock()
			self.probingDevices.remove(endpointID)
			var remove=false
			if let info=self.foundServices[endpointID]{
				if alive{
					self.foundServices[endpointID]?.lastSeen=Date()
				}else{
					// Skip if the browser re-reported the device while we were probing.
					remove=info.lastSeen<startedAt
				}
			}
			self.stateLock.unlock()
			if remove{
				self.removeKnownDevice(endpointID: endpointID)
			}
		}
		conn.stateUpdateHandler={state in
			switch state{
			case .ready:
				finish(true)
			case .failed, .cancelled:
				finish(false)
			default:
				break
			}
		}
		conn.start(queue: .main)
		DispatchQueue.main.asyncAfter(deadline: .now()+NearbyConnectionManager.liveProbeTimeout){
			finish(false)
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
			touchKnownService(endpointID: endpointID, service: service, device: nil)
			return
		}
		guard let endpointInfoEncoded=txtRecord.dictionary["n"] else {
			touchKnownService(endpointID: endpointID, service: service, device: nil)
			return
		}
		guard let endpointInfoSerialized=Data.dataFromUrlSafeBase64(endpointInfoEncoded) else {return}
		guard var endpointInfo=EndpointInfo(data: endpointInfoSerialized) else {return}

		stateLock.lock()
		if var existing=foundServices[endpointID]{
			existing.lastSeen=Date()
			existing.service=service
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
				if let deviceInfo=deviceInfo{
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

	private func touchKnownService(endpointID:String, service:NWBrowser.Result, device:RemoteDeviceInfo?){
		stateLock.lock()
		if foundServices[endpointID] != nil{
			foundServices[endpointID]?.lastSeen=Date()
			foundServices[endpointID]?.service=service
			if let device=device{
				foundServices[endpointID]?.device=device
			}
		}
		stateLock.unlock()
	}

	private func removeKnownDevice(endpointID:String){
		stateLock.lock()
		guard foundServices.removeValue(forKey: endpointID) != nil else {
			stateLock.unlock()
			return
		}
		stateLock.unlock()
		for delegate in liveDelegates(){
			delegate.removeDevice(id: endpointID)
		}
	}

	private func maybeRemoveFoundDevice(service:NWBrowser.Result){
		guard let endpointID=endpointID(for: service) else {return}
		removeKnownDevice(endpointID: endpointID)
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

	private func currentLastSeen(deviceID:String)->Date?{
		stateLock.lock()
		defer{stateLock.unlock()}
		return foundServices[deviceID]?.lastSeen
	}

	public func startOutgoingTransfer(deviceID:String, delegate:ShareExtensionDelegate, urls:[URL]){
		stateLock.lock()
		let info=foundServices[deviceID]
		stateLock.unlock()
		guard let info else {return}
		guard let device=info.device else {return}
		guard let lastSeen=currentLastSeen(deviceID: deviceID), Date().timeIntervalSince(lastSeen)<NearbyConnectionManager.staleSendWindow else {
			removeKnownDevice(endpointID: deviceID)
			DispatchQueue.main.async {
				delegate.connectionFailed(with: NearbyError.protocolError("Device is no longer available — pick it again after it reappears."))
			}
			return
		}
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
