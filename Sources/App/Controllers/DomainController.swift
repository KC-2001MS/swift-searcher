import Fluent
import Vapor

struct DomainController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let domains = routes.grouped("domains")

        domains.get(use: { try await self.index(req: $0) })
//        domains.post(use: { try await self.create(req: $0) })
//        domains.group(":domainID") { domain in
//            domain.delete(use: { try await self.delete(req: $0) })
//        }
    }
    
    func index(req: Request) async throws -> [Domain] {
        try await Domain.query(on: req.db).all()
    }

    func create(req: Request) async throws -> Domain {
        let domain = try req.content.decode(Domain.self)

        try await domain.save(on: req.db)
        return domain
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard let domain = try await Domain.find(req.parameters.get("domainID"), on: req.db) else {
            throw Abort(.notFound)
        }

        try await domain.delete(on: req.db)
        return .noContent
    }
}
