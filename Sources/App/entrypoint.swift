import Vapor
import Logging

@main
enum Entrypoint {
    static func main() async throws {
        //環境の初期化
        var env = try Environment.detect()
        //Logの設定
        try LoggingSystem.bootstrap(from: &env)
        
        let app = Application(env)
        //終了時の処理
        defer { app.shutdown() }
        //APIを設定
        do {
            try await configure(app)
        } catch {
            app.logger.report(error: error)
            throw error
        }
        //APIの開始
        try await app.execute()
    }
}
