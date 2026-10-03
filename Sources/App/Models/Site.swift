//
//  Site.swift
//  
//  
//  Created by Keisuke Chinone on 2024/04/28.
//


import Fluent
import Vapor

//final class Site: Model, Content {
//    static let schema = "todos"
//    
//    @ID(key: .id)
//    var id: UUID?
//
//    @Field(key: "title")
//    var title: String
//    
//    @Field(key: "url")
//    var url: String
//    
//    @Field(key: "html")
//    var html: String
//    
//    @Parent(key: "domain_id")
//    var domain: Domain
//
//    init() { }
//
//    init(
//        id: UUID? = nil,
//        title: String,
//        url: String,
//        html: String,
//        domainID: Domain.IDValue
//    ) {
//        self.id = id
//        self.title = title
//        self.url = url
//        self.html = html
//        self.$domain.id = domainID
//    }
//}
