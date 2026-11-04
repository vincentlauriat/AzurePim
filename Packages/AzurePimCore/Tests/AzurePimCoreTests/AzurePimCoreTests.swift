import Testing
@testable import AzurePimCore

@Test func coreVersionIsSemantic() {
    let parts = AzurePimCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
