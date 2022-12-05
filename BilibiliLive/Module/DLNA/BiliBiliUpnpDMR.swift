//
//  UpnpDMR.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/11/25.
//

import CocoaAsyncSocket
import CoreMedia
import Foundation
import Swifter
import SwiftyJSON
import UIKit

class BiliBiliUpnpDMR: NSObject {
    static let shared = BiliBiliUpnpDMR()
    private var udp: GCDAsyncUdpSocket!
    private var httpServer = HttpServer()
    private var connectedSockets = [GCDAsyncSocket]()
    private var sessions = Set<NVASession>()
    private var udpStarted = false
    private var ip: String?

    private lazy var serverInfo: String = {
        let file = Bundle.main.url(forResource: "DLNAInfo", withExtension: "xml")!
        return try! String(contentsOf: file).replacingOccurrences(of: "{{UUID}}", with: bUuid)
    }()

    private lazy var nirvanaControl: String = {
        let file = Bundle.main.url(forResource: "NirvanaControl", withExtension: "xml")!
        return try! String(contentsOf: file)
    }()

    private lazy var avTransportScpd: String = {
        let file = Bundle.main.url(forResource: "AvTransportScpd", withExtension: "xml")!
        return try! String(contentsOf: file)
    }()

    private lazy var bUuid: String = {
        if Settings.uuid.count > 0 {
            return Settings.uuid
        }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var randomString = ""
        for _ in 0..<35 {
            let rand = arc4random_uniform(36)
            let nextChar = letters[letters.index(letters.startIndex, offsetBy: Int(rand))]
            randomString.append(nextChar)
        }
        Settings.uuid = randomString
        return randomString
    }()

    override private init() { super.init() }
    func start() {
        startUdpIfNeed()
        try? httpServer.start(9958)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        httpServer["/description.xml"] = { [weak self] req in
            print("handel serverInfo")
            return HttpResponse.ok(.text(self?.serverInfo ?? ""))
        }

        httpServer["projection"] = nvasocket(uuid: bUuid, didConnect: { [weak self] session in
            self?.sessions.insert(session)
        }, didDisconnect: { [weak self] session in
            self?.sessions.remove(session)
        }, processor: { [weak self] session, frame in
            DispatchQueue.main.async {
                self?.handleEvent(frame: frame, session: session)
            }
        })

        httpServer["/dlna/NirvanaControl.xml"] = {
            [weak self] req in
            print("handle NirvanaControl")
            let txt = self?.nirvanaControl ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.get["/dlna/AVTransport.xml"] = {
            [weak self] req in
            print("handle AVTransport.xml")
            let txt = self?.avTransportScpd ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.post["/AVTransport/action"] = {
            req in
            let str = String(data: Data(req.body), encoding: .utf8) ?? ""
            print("handle AVTransport.xml", str)
            return HttpResponse.ok(.text(str))
        }

        httpServer["AVTransport/event"] = {
            req in
            return HttpResponse.internalServerError(nil)
        }
    }

    @objc func didEnterBackground() {
        udp?.close()
        udpStarted = false
    }

    @objc func willEnterForeground() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startUdpIfNeed()
        }
    }

    private func startUdpIfNeed() {
        ip = getIPAddress()
        if !udpStarted {
            do {
                udp = GCDAsyncUdpSocket(delegate: self, delegateQueue: DispatchQueue.main)
                try udp.enableBroadcast(true)
                try udp.enableReusePort(true)
                try udp.bind(toPort: 1900)
                try udp.joinMulticastGroup("239.255.255.250")
                try udp.beginReceiving()
                udpStarted = true
            } catch let err {
                print(err)
            }
        }
    }

    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { return "" }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en2" || name == "en3" || name == "en4" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func getSSDPResp() -> String {
        guard let ip = ip ?? getIPAddress() else {
            print("no ip")
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E, d MMM yyyy HH:mm:ss"
        return """
        HTTP/1.1 200 OK
        LOCATION: http://\(ip):9958/description.xml
        CACHE-CONTROL: max-age=30
        SERVER: Linux/3.0.0, UPnP/1.0, Platinum/1.0.5.13
        EXT:
        BOOTID.UPNP.ORG: 1669443520
        CONFIGID.UPNP.ORG: 10177363
        USN: uuid:atvbilibili&\(bUuid)::upnp:rootdevice
        ST: upnp:rootdevice
        DATE: \(formatter.string(from: Date())) GMT

        """
    }

    func handleEvent(frame: NVASession.NVAFrame, session: NVASession) {
        let topMost = UIViewController.topMostViewController()
        switch frame.action {
        case "GetVolume":
            session.sendReply(content: ["volume": 30])
        case "Play":
            let json = JSON(parseJSON: frame.body)
            let aid = json["aid"].intValue
            let cid = json["cid"].intValue
            let epid = json["epid"].intValue
            let player: VideoDetailViewController
            if epid > 0 {
                player = VideoDetailViewController.create(epid: epid)
            } else {
                player = VideoDetailViewController.create(aid: aid, cid: cid)
            }
            if let _ = AppDelegate.shared.window!.rootViewController?.presentedViewController {
                AppDelegate.shared.window!.rootViewController?.dismiss(animated: false) {
                    player.present(from: UIViewController.topMostViewController(), direatlyEnterVideo: true)
                }
            } else {
                player.present(from: topMost, direatlyEnterVideo: true)
            }
            session.sendEmpty()
        case "Pause":
            (topMost as? VideoPlayerViewController)?.player?.pause()
            session.sendEmpty()
        case "Resume":
            (topMost as? VideoPlayerViewController)?.player?.play()
            session.sendEmpty()
        case "SwitchDanmaku":
            let json = JSON(parseJSON: frame.body)
            (topMost as? VideoPlayerViewController)?.danMuView.isHidden = !json["open"].boolValue
            session.sendEmpty()
        case "Seek":
            let json = JSON(parseJSON: frame.body)
            (topMost as? VideoPlayerViewController)?.player?.seek(to: CMTime(seconds: json["seekTs"].doubleValue, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
            session.sendEmpty()
        case "Stop":
            (topMost as? VideoPlayerViewController)?.dismiss(animated: true)
            session.sendEmpty()
        default:
            print("action:", frame.action)
            session.sendEmpty()
        }
    }

    enum PlayStatus: Int {
        case loading = 3
        case playing = 4
        case paused = 5
        case end = 6
        case stop = 7
    }

    func sendStatus(status: PlayStatus) {
        print("send status:", status)
        Array(sessions).forEach { $0.sendCommand(action: "OnPlayState", content: ["playState": status.rawValue]) }
    }

    func sendProgress(duration: Int, current: Int) {
        Array(sessions).forEach { $0.sendCommand(action: "OnProgress", content: ["duration": duration, "position": current]) }
    }

    func sendVideoSwitch(aid: Int, cid: Int, title: String) {
        // causing client crash
//        let playItem = ["aid": "\(aid)", "cid": "\(cid)", "contentType": "1", "epId": "0", "seasonId": "0"] as [String: Any]
//        let data = ["playItem": playItem, "qnDesc": "112", "title": title] as [String: Any]
//        Array(sessions).forEach { $0.sendCommand(action: "OnEpisodeSwitch", content: data) }
    }
}

extension BiliBiliUpnpDMR: GCDAsyncUdpSocketDelegate {
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        address.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            let sockaddrPtr = pointer.bindMemory(to: sockaddr.self)
            guard let unsafePtr = sockaddrPtr.baseAddress else { return }
            guard getnameinfo(unsafePtr, socklen_t(data.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else {
                return
            }
        }
        var ipAddress = String(cString: hostname)
        ipAddress = ipAddress.replacingOccurrences(of: "::ffff:", with: "")
        let str = String(data: data, encoding: .utf8)
        if str?.contains("ssdp:discover") == true {
            print("handle ssdp discover from:", ipAddress)
            let data = getSSDPResp().data(using: .utf8)!
            sock.send(data, toAddress: address, withTimeout: -1, tag: 0)
        }
    }
}