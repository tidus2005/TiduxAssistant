import Foundation
import Testing
@testable import WristArenaCore

struct ArenaGameTests {
    @Test func catalogAndBudgets() {
        #expect(ArenaCatalog.parts.count == 17)
        for tier in 1...10 {
            for seed in 1...20 {
                let game = ArenaGame(seed:UInt64(seed), tier:tier)
                #expect(game.isValid)
                #expect(game.player.loadout.power == 100+(tier-1)*18)
                #expect(game.enemy.loadout.power == 100+(tier-1)*18)
            }
        }
    }
    @Test func pauseAndRestoreDoNotAdvanceInBackground() throws {
        var game = ArenaGame(seed:42)
        game.advance(seconds:1); #expect(game.elapsed == 0)
        game.resume(); game.advance(seconds:1/30); #expect(game.elapsed > 0)
        game.pause(); let before = game.elapsed
        game.advance(seconds:60); #expect(game.elapsed == before)
        let restored = try #require(ArenaGame.restore(from:JSONEncoder().encode(game)))
        #expect(restored.paused); #expect(restored.elapsed == game.elapsed)
        #expect(restored.player.loadout == game.player.loadout)
        #expect(ArenaGame.restore(from:Data("invalid".utf8)) == nil)
    }
    @Test func deterministicBattlesTerminateAndRemainFinite() throws {
        for seed in 0..<40 {
            var a = ArenaGame(seed:UInt64(seed),tier:seed%10+1)
            var b = a; a.resume(); b.resume()
            for _ in 0..<1500 {
                a.advance(seconds:1/30); b.advance(seconds:1/30)
                #expect(a.isValid)
                if a.phase == .result { break }
            }
            #expect(a.phase == .result)
            #expect(a.player.hp == b.player.hp)
            #expect(a.enemy.hp == b.enemy.hp)
            #expect(a.player.hp >= 0 && a.enemy.hp >= 0)
        }
    }
    @Test func replacementReturnsEquipmentAndMaxLevelDoesNotConsume() {
        var loadout = ArenaLoadout()
        let first = loadout.install(ArenaPart("hammer"),at:0)
        #expect(first.accepted && first.returned?.id == "spike")
        let s1 = loadout.install(ArenaPart("shield"),at:0); #expect(s1.accepted)
        let s2 = loadout.install(ArenaPart("shield"),at:1); #expect(s2.accepted)
        #expect(loadout.gear[0]?.level == 2 && loadout.gear[1] == nil)
        let s3 = loadout.install(ArenaPart("shield"),at:1); #expect(s3.accepted)
        let s4 = loadout.install(ArenaPart("shield"),at:0); #expect(!s4.accepted)
        let s5 = loadout.install(ArenaPart("unknown"),at:0); #expect(!s5.accepted)
        #expect(loadout.isValid)
    }
    @Test func lootIsOneTimeAndCampaignRestoresHealth() throws {
        var winning: ArenaGame?
        for seed in 0..<25 {
            var game = ArenaGame(seed:UInt64(seed),mode:.campaign); game.resume()
            for _ in 0..<1500 { game.advance(seconds:1/30) }
            if game.phase == .loot { winning = game; break }
        }
        var game = try #require(winning)
        let invalid = game.takeLoot(at:99); #expect(!invalid)
        let taken = game.takeLoot(at:0); #expect(taken)
        let duplicate = game.takeLoot(at:0); #expect(!duplicate)
        #expect(game.inventory.count == 1)
        let installed = game.install(at:0,slot:0); #expect(installed)
        game.nextRound()
        #expect(game.level == 2 && game.phase == .ready)
        #expect(game.player.hp == game.player.loadout.maxHP)
        #expect(game.enemy.loadout.power == 118)
        let level = game.level; game.nextRound(); #expect(game.level == level)
    }
}
