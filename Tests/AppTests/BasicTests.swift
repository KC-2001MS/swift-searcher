@testable import App
import Foundation
import Testing

@Suite("URL の正規化")
struct URLNormalizerTests {
    @Test("表記ゆれのある URL を同じ形にそろえる", arguments: [
        ("HTTPS://IROIRO.DEV", "https://iroiro.dev/"),
        ("https://iroiro.dev:443/", "https://iroiro.dev/"),
        ("https://iroiro.dev/#section", "https://iroiro.dev/"),
        ("https://iroiro.dev/a/b/../c/./d", "https://iroiro.dev/a/c/d"),
        ("https://iroiro.dev/?utm_source=x&b=2&a=1", "https://iroiro.dev/?a=1&b=2"),
        ("https://iroiro.dev/?utm_medium=y", "https://iroiro.dev/"),
    ])
    func normalize(input: String, expected: String) {
        #expect(URLNormalizer.normalize(input)?.absoluteString == expected)
    }

    @Test("相対 URL を解決する")
    func relative() {
        let base = URL(string: "https://iroiro.dev/blog/post/")!
        #expect(URLNormalizer.normalize("../other", relativeTo: base)?.absoluteString == "https://iroiro.dev/blog/other")
        #expect(URLNormalizer.normalize("/about", relativeTo: base)?.absoluteString == "https://iroiro.dev/about")
        #expect(URLNormalizer.normalize("//iroiro.dev/x", relativeTo: base)?.absoluteString == "https://iroiro.dev/x")
    }

    @Test("http(s) 以外は扱わない")
    func unsupportedSchemes() {
        #expect(URLNormalizer.normalize("mailto:a@example.com") == nil)
        #expect(URLNormalizer.normalize("javascript:void(0)") == nil)
        #expect(URLNormalizer.normalize("tel:000") == nil)
    }

    @Test("拡張子で HTML 以外を判定する")
    func nonHTML() {
        #expect(URLNormalizer.isLikelyNonHTML(URL(string: "https://iroiro.dev/image.PNG")!))
        #expect(!URLNormalizer.isLikelyNonHTML(URL(string: "https://iroiro.dev/page.html")!))
        #expect(!URLNormalizer.isLikelyNonHTML(URL(string: "https://iroiro.dev/blog/")!))
    }
}

@Suite("robots.txt")
struct RobotsTxtTests {
    let text = """
    # comment
    User-agent: *
    Disallow: /private/
    Allow: /private/public.html
    Disallow: /*.pdf$
    Crawl-delay: 2

    User-agent: BadBot
    Disallow: /

    Sitemap: https://iroiro.dev/sitemap.xml
    """

    @Test("最も長く一致したルールで判定する")
    func longestMatch() {
        let robots = RobotsTxt(parsing: text, userAgent: "SwiftSearcher")
        #expect(robots.isAllowed(path: "/"))
        #expect(!robots.isAllowed(path: "/private/secret.html"))
        #expect(robots.isAllowed(path: "/private/public.html"))
        #expect(!robots.isAllowed(path: "/docs/file.pdf"))
        #expect(robots.isAllowed(path: "/docs/file.pdf?download=1"))
        #expect(robots.crawlDelay == 2)
        #expect(robots.sitemaps == ["https://iroiro.dev/sitemap.xml"])
    }

    @Test("自分の名前のグループを優先する")
    func specificGroup() {
        let robots = RobotsTxt(parsing: text, userAgent: "BadBot")
        #expect(!robots.isAllowed(path: "/"))
        #expect(robots.isAllowed(path: "/robots.txt"))
    }

    @Test("ワイルドカードの照合")
    func wildcard() {
        #expect(RobotsTxt.matches(pattern: "/a*b", path: "/a/x/b/c"))
        #expect(!RobotsTxt.matches(pattern: "/a*b$", path: "/a/x/b/c"))
        #expect(RobotsTxt.matches(pattern: "/a*b$", path: "/a/x/b"))
        #expect(!RobotsTxt.matches(pattern: "/b", path: "/a/b"))
    }
}

@Suite("トークナイザー")
struct TokenizerTests {
    @Test("英単語は小文字化し、ストップワードを除く")
    func english() {
        #expect(Tokenizer.tokenize("The Swift Programming Language") == ["swift", "programming", "language"])
    }

    @Test("キャメルケースを分解する")
    func camelCase() {
        #expect(Tokenizer.tokenize("NavigationStack") == ["navigationstack", "navigation", "stack"])
        #expect(Tokenizer.splitCamelCase("URLSession") == ["URL", "Session"])
        #expect(Tokenizer.splitCamelCase("SwiftUI") == ["Swift", "UI"])
    }

    @Test("日本語はバイグラムに分割する")
    func japanese() {
        #expect(Tokenizer.tokenize("検索エンジン") == ["検索", "索エ", "エン", "ンジ", "ジン"])
        #expect(Tokenizer.tokenize("Swiftで検索") == ["swift", "で検", "検索"])
    }

    @Test("全角英数字を半角にそろえる")
    func fullWidth() {
        #expect(Tokenizer.tokenize("ＳＷＩＦＴ　６") == ["swift", "6"])
    }
}

@Suite("PageRank")
struct PageRankTests {
    @Test("多くリンクされるページほど高くなる")
    func ranking() {
        let ranks = PageRank.compute(
            nodes: ["home", "a", "b", "c"],
            edges: [
                ("home", "a"), ("home", "b"), ("home", "c"),
                ("a", "home"), ("b", "home"), ("c", "home"),
                ("a", "b"),
            ]
        )
        let total = ranks.values.reduce(0, +)
        #expect(abs(total - 1) < 1e-6)
        #expect(ranks["home"]! > ranks["b"]!)
        #expect(ranks["b"]! > ranks["c"]!)
    }

    @Test("ページが無ければ空")
    func empty() {
        #expect(PageRank.compute(nodes: [], edges: []).isEmpty)
    }
}

@Suite("HTML の解析")
struct HTMLExtractorTests {
    @Test("タイトル・説明・リンク・本文を取り出す")
    func extract() throws {
        let html = """
        <html lang="ja"><head>
          <title> テストページ </title>
          <meta name="description" content="説明文">
          <link rel="canonical" href="/canonical">
        </head><body>
          <nav><a href="/">ホーム</a></nav>
          <main>
            <h1>見出し</h1>
            <p>本文です。<a href="/a#top">記事A</a> <a href="https://example.com/" rel="nofollow">外部</a></p>
            <script>var x = "script text";</script>
          </main>
          <footer>フッター</footer>
        </body></html>
        """
        let page = try HTMLExtractor.extract(html: html, baseURL: URL(string: "https://iroiro.dev/page")!)
        #expect(page.title == "テストページ")
        #expect(page.description == "説明文")
        #expect(page.language == "ja")
        #expect(page.canonicalURL?.absoluteString == "https://iroiro.dev/canonical")
        #expect(page.headings == ["見出し"])
        #expect(page.content.contains("本文です。"))
        #expect(!page.content.contains("script text"))
        #expect(!page.content.contains("フッター"))
        #expect(page.links.map(\.url.absoluteString) == ["https://iroiro.dev/", "https://iroiro.dev/a", "https://example.com/"])
        #expect(page.links.map(\.nofollow) == [false, false, true])
        #expect(!page.noindex)
    }

    @Test("meta robots を読む")
    func metaRobots() throws {
        let html = #"<html><head><meta name="robots" content="noindex, nofollow"></head><body></body></html>"#
        let page = try HTMLExtractor.extract(html: html, baseURL: URL(string: "https://iroiro.dev/")!)
        #expect(page.noindex)
        #expect(page.nofollow)
    }

    @Test("サイトマップを読む")
    func sitemap() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://iroiro.dev/</loc></url>
          <url><loc> https://iroiro.dev/about </loc></url>
        </urlset>
        """
        let result = try HTMLExtractor.extractSitemap(xml: xml)
        #expect(result.urls == ["https://iroiro.dev/", "https://iroiro.dev/about"])
        #expect(!result.isIndex)
    }
}
