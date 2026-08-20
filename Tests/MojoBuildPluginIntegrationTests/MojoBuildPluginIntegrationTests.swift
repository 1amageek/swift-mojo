#if os(macOS)
import MojoBuildPluginIntegrationFixture
import Testing

@Test
func buildPluginVerifiesLinksAndRunsPreparedMojoArtifact() {
    #expect(integrationAdd(20, 22) == 42)
}
#endif
