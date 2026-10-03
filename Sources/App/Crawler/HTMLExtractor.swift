import Foundation
import SwiftSoup

/// HTML から取り出した情報
struct ExtractedPage: Sendable, Equatable {
    struct Link: Sendable, Equatable {
        /// 正規化済みのリンク先 URL
        var url: URL
        /// リンクのテキスト（アンカーテキスト）。リンク先の内容を表す重要な手がかりになる
        var text: String
        /// rel="nofollow" が付いているか
        var nofollow: Bool
    }

    var title: String
    var description: String
    var headings: [String]
    var content: String
    var language: String?
    var canonicalURL: URL?
    var links: [Link]
    /// <meta name="robots" content="noindex"> が指定されているか
    var noindex: Bool
    /// <meta name="robots" content="nofollow"> が指定されているか
    var nofollow: Bool
}

/// SwiftSoup を使って HTML を解析する
enum HTMLExtractor {
    /// 本文として保存する最大文字数
    static let maxContentLength = 50_000

    static func extract(html: String, baseURL: URL) throws -> ExtractedPage {
        // HTML を DOM（要素の木構造）に変換する。以降は CSS セレクタ（"a[href]" など）で要素を探せる
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)

        // <base href> があればリンクの解決に使う
        var linkBase = baseURL
        if let baseHref = try document.select("base[href]").first()?.attr("href"),
           let resolved = URL(string: baseHref, relativeTo: baseURL)?.absoluteURL {
            linkBase = resolved
        }

        // meta robots（noindex / nofollow / none）
        let robots = try document.select("meta[name=robots], meta[name=swiftsearcher]")
            .array()
            .map { try $0.attr("content").lowercased() }
            .joined(separator: ",")
        let noindex = robots.contains("noindex") || robots.contains("none")
        let nofollow = robots.contains("nofollow") || robots.contains("none")

        // タイトル: <title> → og:title → 最初の <h1> の順に探す
        var title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = try document.select("meta[property=og:title]").first()?.attr("content") ?? ""
        }
        if title.isEmpty {
            title = try document.select("h1").first()?.text() ?? ""
        }

        // 説明文: meta description → og:description
        var description = try document.select("meta[name=description]").first()?.attr("content") ?? ""
        if description.isEmpty {
            description = try document.select("meta[property=og:description]").first()?.attr("content") ?? ""
        }

        let language = try document.select("html[lang]").first()?.attr("lang")

        var canonicalURL: URL?
        if let href = try document.select("link[rel=canonical][href]").first()?.attr("href") {
            canonicalURL = URLNormalizer.normalize(href, relativeTo: linkBase)
        }

        // リンクの抽出（ナビゲーションなども含めてページ全体から集める）。
        // 本文の抽出でナビゲーションを取り除く前に行うのがポイント
        var links: [ExtractedPage.Link] = []
        var seen = Set<URL>()
        for anchor in try document.select("a[href]").array() {
            guard let url = URLNormalizer.normalize(try anchor.attr("href"), relativeTo: linkBase) else { continue }
            let rel = try anchor.attr("rel").lowercased()
            let text = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
            // 同じページへのリンクは最初の1つだけ（ただしアンカーテキストは足し合わせる）
            if seen.contains(url) {
                if let index = links.firstIndex(where: { $0.url == url }), !text.isEmpty,
                   !links[index].text.contains(text) {
                    links[index].text += " " + text
                }
                continue
            }
            seen.insert(url)
            links.append(.init(url: url, text: text, nofollow: rel.contains("nofollow")))
        }

        // 本文の抽出。検索に関係ない要素を取り除く（ボイラープレートの除去）。
        // メニューやフッターは全ページ共通なので、残すと全ページが同じ語で一致してしまう
        try document.select("script, style, noscript, template, svg, iframe, form").remove()
        let headings = try document.select("h1, h2, h3")
            .array()
            .map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // <main> や <article> があればそこを本文とし、無ければナビゲーション等を除いた <body> を使う
        let contentRoot: Element?
        if let main = try document.select("main, article, [role=main]").first() {
            contentRoot = main
        } else {
            try document.select("nav, header, footer, aside").remove()
            contentRoot = document.body()
        }
        var content = try contentRoot?.text() ?? ""
        if content.count > maxContentLength {
            content = String(content.prefix(maxContentLength))
        }

        return ExtractedPage(
            title: title,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            headings: headings,
            content: content,
            language: language,
            canonicalURL: canonicalURL,
            links: links,
            noindex: noindex,
            nofollow: nofollow
        )
    }

    /// サイトマップ（sitemap.xml）から URL を取り出す。
    /// サイトマップインデックスの場合は `isIndex` が true になり、URL は子サイトマップを指す。
    static func extractSitemap(xml: String) throws -> (urls: [String], isIndex: Bool) {
        let document = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        let isIndex = try !document.select("sitemapindex").isEmpty()
        let urls = try document.select("loc")
            .array()
            .map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (urls, isIndex)
    }
}
