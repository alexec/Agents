import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A document read the direct way says the same thing as one read through `Decodable`.
@Suite("Reading JSON without guessing")
struct JSONValueParseTests {
    private let text = #"""
    {"s":"hi","t":true,"f":false,"i":42,"n":-7,"d":1.5,"e":1e3,"z":null,
     "a":[1,"two",{"three":3}],"o":{"nested":{"deep":[true]}},"big":9223372036854775807,
     "huge":18446744073709551615,"slash":"a/b","unicode":"café 😀"}
    """#

    @Test func everyKindIsReadAsItself() throws {
        let value = try JSONValue.parse(Data(text.utf8))
        #expect(value["s"] == .string("hi"))
        #expect(value["t"] == .bool(true))
        #expect(value["f"] == .bool(false))
        #expect(value["i"] == .int(42))
        #expect(value["n"] == .int(-7))
        #expect(value["d"] == .double(1.5))
        #expect(value["e"] == .double(1000))
        #expect(value["z"] == .null)
        #expect(value["a"] == .array([.int(1), .string("two"), ["three": .int(3)]]))
        #expect(value["o"]?["nested"]?["deep"] == .array([.bool(true)]))
        #expect(value["big"] == .int(Int.max))
        #expect(value["huge"]?.stringValue == nil)
        #expect(value["huge"]?.intValue == nil, "past what Int holds: a double, never a wrapped int")
        #expect(value["slash"] == .string("a/b"))
        #expect(value["unicode"] == .string("café 😀"))
    }

    @Test func itAgreesWithDecodable() throws {
        let direct = try JSONValue.parse(Data(text.utf8))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        // The one thing the two are allowed to disagree on is a whole number written
        // with an exponent, which `Decodable` reads as an Int and this as a Double.
        var comparable = decoded.objectValue ?? [:]
        comparable["e"] = nil
        var mine = direct.objectValue ?? [:]
        mine["e"] = nil
        #expect(JSONValue.object(mine) == JSONValue.object(comparable))
    }

    @Test func aRoundTripThroughEncodingHolds() throws {
        struct Shape: Codable { var name: String; var count: Int; var ratio: Double; var flags: [Bool] }
        let value = try JSONValue.encoding(Shape(name: "x", count: 3, ratio: 0.25, flags: [true, false]))
        #expect(value == ["name": "x", "count": 3, "ratio": 0.25, "flags": [true, false]])
        let back = try value.decode(Shape.self)
        #expect(back.count == 3 && back.ratio == 0.25 && back.flags == [true, false])
    }

    @Test func aFragmentAndAnEmptyLineAreHandled() throws {
        #expect(try JSONValue.parse(Data("\"just a string\"".utf8)) == .string("just a string"))
        #expect(throws: (any Error).self) { try JSONValue.parse(Data()) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("{ not json".utf8)) }
    }
}
