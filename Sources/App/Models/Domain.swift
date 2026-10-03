import Fluent
import Vapor

final class Domain: Model, Content {
    static let schema = "domains"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "domain")
    var domain: String
    
//    @Children(for: \.$domain)
//    var sites: [Site]
    
    init() { }
    
    init(
        id: UUID? = nil,
        domain: String
    ) {
        self.id = id
        self.domain = domain
    }
}
