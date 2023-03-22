//
//  CustomViewController.swift
//  BilibiliLive
//
//  Created by hydewww on 2023/1/25.
//

import UIKit

class CustomViewController: UIViewController {
    let collectionVC = FeedCollectionViewController()
    override func viewDidLoad() {
        super.viewDidLoad()
        collectionVC.styleOverride = .sideBar
        collectionVC.show(in: self)
        collectionVC.didSelect = {
            [weak self] in
            self?.goDetail(with: $0 as! CustomData)
        }
    }

    func goDetail(with history: CustomData) {
        let detailVC = VideoDetailViewController.create(aid: history.aid, cid: 0)
        detailVC.present(from: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadData()
    }
}

extension CustomViewController: BLTabBarContentVCProtocol {
    func reloadData() {
        if Settings.customLink.count <= 7 {
            return
        }
        WebRequest.requestCustomList { [weak self] datas in
            self?.collectionVC.displayDatas = datas
        }
    }
}

extension WebRequest {
    static func requestCustomList(complete: (([CustomData]) -> Void)?) {
        request(url: Settings.customLink) {
            (result: Result<[CustomData], RequestError>) in
            if let data = try? result.get() {
                complete?(data)
            }
        }
    }
}

struct CustomData: DisplayData, Codable {
    let aid: Int
    let title: String
    let avatar: URL?
    let pic: URL?
    let ownerName: String
    let date: String?
}
