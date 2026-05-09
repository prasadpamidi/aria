import Aria
import AriaTesting
import Testing
@testable import AriaSample

struct AriaSampleTests {
    @Test
    func ariaVersionIsAvailable() async throws {
        #expect(!Aria.version.isEmpty)
    }

    @Test
    func ariaTestingVersionMatchesCore() async throws {
        #expect(Aria.version == AriaTesting.version)
    }
}
