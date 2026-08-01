import Testing

@testable import Pulse

/// App-target tests. The substantive logic lives in PulseKit and is tested there (fast, no simulator);
/// this target covers only things that need the real app bundle.
@Suite("App smoke")
struct AppSmokeTests {

    @Test("App target links and boots its root view")
    func rootViewExists() {
        _ = RootView()
    }
}
