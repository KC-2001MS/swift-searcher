//
//  CrawlerJob.swift
//
//  
//  Created by Keisuke Chinone on 2024/04/28.
//


import Queues
import XMLCoder
import Foundation
import Vapor

//クローラーを実行するための構造体
struct CrawlerJob: AsyncScheduledJob {
    init() {}
    //巡回のための処理を記載
    func run(context: QueueContext) async throws {
        //URLのリクエストを行うための定数
        let client = context.application.client
        
        let domain = "https://iroiro.dev/"
        let sitemap: URI = .init(string: domain + "sitemap.xml")
        //実際のリクエストを行うための処理
        let response = try await client.get(sitemap)
        
        guard let body = response.body else {
            fatalError()
        }
        
        guard let xml = String(decoding: body.readableBytesView, as: UTF8.self).data(using: .utf8) else {
            fatalError()
        }
        
        
        let decoder = XMLDecoder()
        _ = try decoder.decode(Array<SitemapItem>.self, from: xml)
        
        let domainData = Domain(domain: domain)
        do {
            try await domainData.save(on: context.application.db)
        } catch {
            print("domainData.save error: \(String(reflecting: error))") // エラーの詳細をログに出力
        }
        
    }
}

struct SitemapItem: Codable {
    var loc: String
    var changefreq: String
    var priority: Double
}


