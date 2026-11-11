@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac voice input preference migration")
@MainActor
struct MacVoiceInputPreferenceMigrationTests {
    @Test
    func importsLegacyFlowTypeValuesIntoNamespacedKeys() throws {
        try withIsolatedDefaults { current, legacy in
            legacy.set(false, forKey: "codexEnabled")
            legacy.set("en-US", forKey: "localeIdentifier")
            legacy.set(18.0, forKey: "codexTimeoutSeconds")

            let store = MacVoiceInputStore(
                preferences: current,
                legacyPreferences: legacy
            )

            #expect(store.codexEnabled == false)
            #expect(store.localeIdentifier == "en-US")
            #expect(store.codexTimeoutSeconds == 18)
            #expect(current.bool(
                forKey: "com.tidux.codex-watch-pet.voice-input.codex-enabled.v1"
            ) == false)
            #expect(current.string(
                forKey: "com.tidux.codex-watch-pet.voice-input.locale-identifier.v1"
            ) == "en-US")
            #expect(current.double(
                forKey: "com.tidux.codex-watch-pet.voice-input.codex-timeout-seconds.v1"
            ) == 18)
            #expect(current.bool(
                forKey: "com.tidux.codex-watch-pet.voice-input.flowtype-migration-completed.v1"
            ))
        }
    }

    @Test
    func existingCodexWatchPetValuesWinOverLegacyValues() throws {
        try withIsolatedDefaults { current, legacy in
            current.set(
                true,
                forKey: "com.tidux.codex-watch-pet.voice-input.codex-enabled.v1"
            )
            current.set(
                "zh-CN",
                forKey: "com.tidux.codex-watch-pet.voice-input.locale-identifier.v1"
            )
            current.set(
                9.0,
                forKey: "com.tidux.codex-watch-pet.voice-input.codex-timeout-seconds.v1"
            )

            legacy.set(false, forKey: "codexEnabled")
            legacy.set("en-US", forKey: "localeIdentifier")
            legacy.set(20.0, forKey: "codexTimeoutSeconds")

            let store = MacVoiceInputStore(
                preferences: current,
                legacyPreferences: legacy
            )

            #expect(store.codexEnabled)
            #expect(store.localeIdentifier == "zh-CN")
            #expect(store.codexTimeoutSeconds == 9)
        }
    }

    @Test
    func freshInstallKeepsCodexPolishingOffAndNeverReimportsAfterMigration() throws {
        try withIsolatedDefaults { current, legacy in
            _ = MacVoiceInputStore(
                preferences: current,
                legacyPreferences: legacy
            )
            #expect(current.object(
                forKey: "com.tidux.codex-watch-pet.voice-input.codex-enabled.v1"
            ) == nil)

            legacy.set(true, forKey: "codexEnabled")
            let secondStore = MacVoiceInputStore(
                preferences: current,
                legacyPreferences: legacy
            )

            #expect(secondStore.codexEnabled == false)
            #expect(current.object(
                forKey: "com.tidux.codex-watch-pet.voice-input.codex-enabled.v1"
            ) == nil)
        }
    }

    @Test
    func malformedLegacyValuesAreIgnored() throws {
        try withIsolatedDefaults { current, legacy in
            legacy.set("yes", forKey: "codexEnabled")
            legacy.set(["en-US"], forKey: "localeIdentifier")
            legacy.set(true, forKey: "codexTimeoutSeconds")

            let store = MacVoiceInputStore(
                preferences: current,
                legacyPreferences: legacy
            )

            #expect(store.codexEnabled == false)
            #expect(store.localeIdentifier == "zh-CN")
            #expect(store.codexTimeoutSeconds == 12)
        }
    }

    private func withIsolatedDefaults(
        _ operation: (UserDefaults, UserDefaults) throws -> Void
    ) throws {
        let currentName = "com.tidux.CodexWatchPet.tests.current.\(UUID())"
        let legacyName = "com.tidux.CodexWatchPet.tests.legacy.\(UUID())"
        let current = try #require(UserDefaults(suiteName: currentName))
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        defer {
            current.removePersistentDomain(forName: currentName)
            legacy.removePersistentDomain(forName: legacyName)
        }
        try operation(current, legacy)
    }
}
