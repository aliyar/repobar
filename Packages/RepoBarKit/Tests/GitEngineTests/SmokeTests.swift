import Testing
@testable import GitEngine

@Test func engineModuleLoads() {
    #expect(GitEngineInfo.version.isEmpty == false)
}
