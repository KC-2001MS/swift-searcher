import Fluent
import Vapor

func routes(_ app: Application) throws {
    //このAPIに関する詳細を表示
    app.get { req async in
        "Swift Crawler\nAPI for crawling and searching on Swift language\n\nSee the GitHub repository for more information.\n\n"
    }
    //検索リクエストでの処理
    app.get("search") { req async throws -> Array<Domain> in
        let controller = DomainController()
        //textクエリから検索文字列を取得
        let search: String? = req.query["text"]
        
        let domainData = Domain(domain: "https://iroiro.dev/")
        
        let data = try req.content.decode(Domain.self)
        do {
            try await domainData.save(on: req.db)
        } catch {
            fatalError("DB : \(req.db)")
        }
        //検索結果を返却
        let domains: Array<Domain>
        do {
            domains = try await Domain.query(on: req.db).all()
        } catch {
            fatalError("query error")
        }
        
//        return search != nil ? sample : []
        return domains
    }

    try app.register(collection: DomainController())
}

//検索結果の項目
struct SearchItem: Content {
    var url: String
    var title: String
    var description: String
}

//サンプル用の検索結果
let sample = [
    SearchItem(
        url: "https://www.swift.org",
        title: "Swift.org - Welcome to Swift.org",
        description: "Swift is a general-purpose programming language that's approachable for newcomers and powerful for experts. It is fast, modern, safe, and a joy to write ...")
]
