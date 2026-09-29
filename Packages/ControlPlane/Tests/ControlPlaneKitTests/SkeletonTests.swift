import ControlPlaneKit
import Testing

@Test func theServiceHasAVersion() {
    #expect(!ControlPlaneKit.version.isEmpty)
}
