import Vapor
import Logging
import NIOCore
import NIOPosix

//APIの起動処理
@main
enum Entrypoint {
    static func main() async throws {
        //環境の初期化
        var env = try Environment.detect()
        //Logの設定
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        // NIO のシングルトン EventLoopGroup を Swift Concurrency の executor としても使う
        // （スレッドのホップが減り、パフォーマンスが向上する）
        let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        app.logger.debug("Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])

        //APIを設定
        do {
            try await configure(app)
            //APIの開始
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        //終了時の処理
        try await app.asyncShutdown()
    }
}
