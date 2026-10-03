import Fluent
import Foundation
import Vapor

/// `App link-analysis`: PageRank と HostRank を計算し直す（cron などで1日1回程度実行する）
struct LinkAnalysisCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String { "全ページ・全リンクから PageRank と HostRank を計算し直します" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let result = try await LinkAnalysisJob(database: app.db, logger: app.logger).run()
        context.console.info("完了: pages=\(result.pages) links=\(result.links) hosts=\(result.hosts) updated=\(result.updatedPages)")
        context.console.info("シャードは次の作り直しで新しい値を取り込みます（すぐに反映するには POST /internal/shard/rebuild）")
    }
}

/// `App train-ranker`: 検索ログからランキングモデルを学習する
struct TrainRankerCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "days", help: "何日前までのログを使うか（既定: 30）")
        var days: Int?

        @Option(name: "min-pairs", help: "学習に必要な最小のペア数（既定: 1000）")
        var minimumPairs: Int?

        @Flag(name: "dry-run", help: "学習結果を保存しない")
        var dryRun: Bool
    }

    var help: String { "クリックの記録からランキングモデルを学習し、新しいバージョンとして保存します" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        var trainer = RankerTrainer(database: app.db, logger: app.logger)
        if let days = signature.days { trainer.days = days }
        if let minimumPairs = signature.minimumPairs { trainer.minimumPairs = minimumPairs }
        let result = try await trainer.run(save: !signature.dryRun)
        guard let model = result.model else {
            context.console.warning("学習用のデータが足りないため、モデルは更新しませんでした（ペア: \(result.pairs)）")
            return
        }
        context.console.info("ペア: \(result.pairs)、正解率: \(result.accuracyBefore) → \(result.accuracyAfter)")
        for (name, weight) in zip(model.featureNames, model.weights) {
            context.console.info("  \(name): \(weight)")
        }
        if !signature.dryRun {
            context.console.info("v\(model.version) として保存しました（検索 API が数分以内に読み込みます）")
        }
    }
}

/// `App seed <url>`: シードを追加する
struct SeedCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "url", help: "巡回を始める URL")
        var url: String
    }

    var help: String { "シード（巡回を始める URL）を追加します" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let url = URLNormalizer.normalize(signature.url), let origin = URLNormalizer.origin(of: url) else {
            context.console.error("URL が不正です: \(signature.url)")
            return
        }
        if try await Seed.query(on: app.db).filter(\.$url == url.absoluteString).count() == 0 {
            try await Seed(url: url.absoluteString).create(on: app.db)
        }
        try await app.crawlServices.frontier.enqueue(FrontierEntry(url: url.absoluteString, depth: 0), origin: origin, force: true)
        context.console.info("シードを追加しました: \(url.absoluteString)")
    }
}
