import Foundation

public struct ArenaFighter: Codable, Sendable {
    public var loadout: ArenaLoadout
    public var x: Double
    public var y: Double = 0.6
    public var vx: Double
    public var vy: Double = 0.08
    public var angle: Double = 0
    public var spin: Double = 1
    public var hp: Double
    public var barrier: Double = 0
    public var cooldown: Double = 0
    public var poison: Double = 0
    public var poisonTime: Double = 0
    public var effects: [String: Double] = [:]
    public var timers: [String: Double] = [:]
    public var scale: Double {
        (effects["shrink", default: 0] > 0 ? 1 - 0.15 * Double(loadout.level("shrink")) : 1)
        * (effects["grow", default: 0] > 0 ? 1 + 0.15 * Double(loadout.level("grow")) : 1)
    }
    public var radius: Double { 0.055 * scale }
    public var mass: Double { loadout.mass * scale * scale }
    public var reach: Double {
        let base: Double = switch loadout.weapon.id { case "staff": 0.14; case "hammer", "mage": 0.11; default: 0.09 }
        return base * 1.2 * scale * (1 + 0.12 * Double(loadout.weapon.level - 1))
    }
    init(loadout: ArenaLoadout, player: Bool) {
        self.loadout = loadout; hp = loadout.maxHP; x = player ? 0.25 : 0.75
        vx = player ? 0.4 : -0.4; angle = player ? 0 : .pi
    }
}
public struct ArenaProjectile: Codable, Sendable {
    public var x, y, vx, vy: Double
    public var owner: Int
    public var life: Double = 2
}
public struct ArenaGame: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case ready, battle, finishing, loot, workshop, result }
    public enum Mode: String, Codable, CaseIterable, Sendable { case duel, campaign }
    public var version = 1
    public private(set) var mode: Mode
    public private(set) var phase: Phase = .ready
    public private(set) var level = 1
    public private(set) var tier: Int
    public private(set) var player: ArenaFighter
    public private(set) var enemy: ArenaFighter
    public private(set) var inventory: [ArenaPart] = []
    public private(set) var loot: [ArenaPart] = []
    public private(set) var projectiles: [ArenaProjectile] = []
    public private(set) var elapsed: Double = 0
    public private(set) var finishTime: Double = 0
    public private(set) var outcome = ""
    public private(set) var hitSequence = 0
    public private(set) var critical = false
    public private(set) var paused = true
    private var rng: ArenaRandom
    public init(seed: UInt64 = UInt64(Date().timeIntervalSince1970), mode: Mode = .duel, tier: Int = 1) {
        self.mode = mode; self.tier = min(10, max(1, tier)); rng = ArenaRandom(state: seed)
        let budget = 100 + (mode == .duel ? self.tier - 1 : 0) * 18
        player = ArenaFighter(loadout: .roll(budget: budget, rng: &rng), player: true)
        enemy = ArenaFighter(loadout: .roll(budget: budget, rng: &rng), player: false)
    }
    public mutating func pause() { paused = true }
    public mutating func resume() {
        guard [.ready, .battle, .finishing].contains(phase) else { return }
        if phase == .ready { phase = .battle }; paused = false
    }
    /// A bounded fixed-step clock: no catch-up simulation when the wrist is lowered or app is hidden.
    public mutating func advance(seconds: Double) {
        guard !paused, seconds.isFinite, seconds > 0 else { return }
        let dt = min(seconds, 0.1)
        if phase == .finishing {
            finishTime += dt
            if finishTime >= 2.2 {
                phase = mode == .campaign && outcome == "胜利" ? .loot : .result
                loot = phase == .loot ? enemy.loadout.parts : []; paused = true
            }
            return
        }
        guard phase == .battle else { return }
        let steps = max(1, Int(ceil(dt * 120)))
        for _ in 0..<steps {
            tick(dt / Double(steps))
            if phase != .battle { break }
        }
    }
    private mutating func tick(_ dt: Double) {
        elapsed += dt
        var fighters = [player, enemy]
        for i in 0..<2 {
            let target = fighters[1-i]
            var a = fighters[i]
            a.cooldown = max(0, a.cooldown - dt)
            for key in Array(a.effects.keys) { a.effects[key] = max(0, a.effects[key, default: 0] - dt) }
            for part in a.loadout.skills.compactMap({ $0 }) where !["poison", "leech", "reflect"].contains(part.id) {
                a.timers[part.id] = a.timers[part.id, default: 1.5] - dt
                guard a.timers[part.id, default: 0] <= 0 else { continue }
                let n = Double(part.level)
                let period: Double = switch part.id { case "invincible": 10; case "dash": 5; case "blink": 7; case "heal": 6; default: 8 }
                a.timers[part.id] = period
                switch part.id {
                case "barrier": a.barrier = 12*n; a.effects["barrier"] = 4
                case "invincible": a.effects["invincible"] = 0.1 + 0.4*n
                case "heal": a.hp = min(a.loadout.maxHP, a.hp + 5*n); a.effects["heal"] = 0.6
                case "dash":
                    let d = max(0.01, hypot(target.x-a.x, target.y-a.y))
                    a.vx += (target.x-a.x)/d * (0.25+0.18*n)
                    a.vy += (target.y-a.y)/d * (0.25+0.18*n)
                    a.effects["dash"] = 0.1+0.2*n
                case "blink":
                    let t = rng.next() * .pi * 2
                    a.x += cos(t) * (0.08+0.06*n); a.y += sin(t) * (0.08+0.06*n)
                    a.effects["blink"] = 0.4
                case "grow", "shrink": a.effects[part.id] = 2
                default: break
                }
            }
            if a.effects["barrier", default: 0] <= 0 { a.barrier = 0 }
            if a.poisonTime > 0 { a.poisonTime -= dt; _ = damage(&a, amount: a.poison * dt) }
            let d = max(0.01, hypot(target.x-a.x, target.y-a.y))
            a.vx += (target.x-a.x)/d * dt * 0.4/a.mass
            a.vy += (target.y-a.y)/d * dt * 0.4/a.mass
            let speed = hypot(a.vx, a.vy)
            if speed > 1.2 { a.vx *= 1.2/speed; a.vy *= 1.2/speed }
            a.x += a.vx * dt; a.y += a.vy * dt
            let margin = max(a.radius, a.reach)
            if a.x < margin || a.x > 1-margin { a.vx *= -0.82; a.x = min(1-margin, max(margin, a.x)) }
            if a.y < margin || a.y > 1.22-margin { a.vy *= -0.82; a.y = min(1.22-margin, max(margin, a.y)) }
            let omega: Double = switch a.loadout.weapon.id { case "hammer": .pi*2; case "staff": .pi*5/6; case "ranger", "mage": .pi/2; default: .pi*2/3 }
            a.angle += omega * a.spin * dt
            if ["ranger", "mage"].contains(a.loadout.weapon.id) && a.cooldown <= 0 {
                for k in 0..<a.loadout.weapon.level where projectiles.count < 24 {
                    let angle = atan2(target.y-a.y, target.x-a.x) + Double(k)*0.09
                    projectiles.append(ArenaProjectile(x:a.x, y:a.y, vx:cos(angle)*0.9, vy:sin(angle)*0.9, owner:i))
                }
                a.cooldown = 1.2 - 0.15 * Double(a.loadout.weapon.level)
            }
            fighters[i] = a
        }
        // Native watch adaptation: circular bodies and rotating weapon tips share displayed geometry.
        let dx = fighters[1].x-fighters[0].x, dy = fighters[1].y-fighters[0].y
        let distance = max(0.001, hypot(dx,dy)), nx = dx/distance, ny = dy/distance
        if distance < fighters[0].radius + fighters[1].radius {
            let closing = (fighters[0].vx-fighters[1].vx)*nx + (fighters[0].vy-fighters[1].vy)*ny
            let inv0 = 1/fighters[0].mass, inv1 = 1/fighters[1].mass
            let overlap = fighters[0].radius + fighters[1].radius - distance
            fighters[0].x -= nx*overlap*inv0/(inv0+inv1); fighters[0].y -= ny*overlap*inv0/(inv0+inv1)
            fighters[1].x += nx*overlap*inv1/(inv0+inv1); fighters[1].y += ny*overlap*inv1/(inv0+inv1)
            if closing > 0 {
                let impulse = 1.82*closing/(inv0+inv1)
                fighters[0].vx -= impulse*nx*inv0; fighters[0].vy -= impulse*ny*inv0
                fighters[1].vx += impulse*nx*inv1; fighters[1].vy += impulse*ny*inv1
            }
        }
        for i in 0..<2 {
            let a = fighters[i], b = fighters[1-i]
            guard a.cooldown <= 0, !["ranger", "mage"].contains(a.loadout.weapon.id) else { continue }
            let offsets: [Double] = a.loadout.weapon.id == "spike" ? [0, .pi*2/3, .pi*4/3] : a.loadout.weapon.id == "staff" ? [0, .pi] : [0]
            if offsets.contains(where: { hypot(a.x+cos(a.angle+$0)*a.reach-b.x, a.y+sin(a.angle+$0)*a.reach-b.y) < b.radius+0.02 }) {
                let relativeSpeed = hypot(a.vx-b.vx,a.vy-b.vy) + a.reach * 2
                let reducedMass = a.mass*b.mass/(a.mass+b.mass)
                let base: Double = a.loadout.weapon.id == "hammer" ? 16 : 9
                attack(i, amount:min(42, base*0.4 + 15*reducedMass*relativeSpeed*relativeSpeed), fighters:&fighters)
                fighters[i].cooldown = 0.35
                if rng.next() < 0.2 { fighters[i].spin *= -1 }
            }
        }
        var remaining: [ArenaProjectile] = []
        for var p in projectiles {
            p.x += p.vx*dt; p.y += p.vy*dt; p.life -= dt
            let target = fighters[1-p.owner]
            if hypot(p.x-target.x,p.y-target.y) < target.radius+0.014 {
                attack(p.owner, amount:6+Double(fighters[p.owner].loadout.weapon.level)*2, fighters:&fighters)
            } else if p.life > 0 && p.x > 0 && p.x < 1 && p.y > 0 && p.y < 1.22 { remaining.append(p) }
        }
        projectiles = remaining; player = fighters[0]; enemy = fighters[1]
        if player.hp <= 0 || enemy.hp <= 0 || elapsed >= 45 {
            let ratio = player.hp/player.loadout.maxHP - enemy.hp/enemy.loadout.maxHP
            outcome = abs(ratio) < 0.0001 ? "平局" : ratio > 0 ? "胜利" : "再接再厉"
            phase = .finishing; finishTime = 0
        }
    }
    private func damage(_ target: inout ArenaFighter, amount: Double) -> Double {
        if target.effects["invincible", default:0] > 0 { return 0 }
        var value = amount * (1 - 0.1*Double(target.loadout.level("plate")))
        let absorbed = min(target.barrier, value); target.barrier -= absorbed; value -= absorbed
        let actual = min(target.hp, max(0,value)); target.hp -= actual; return actual
    }
    private mutating func attack(_ i: Int, amount: Double, fighters: inout [ArenaFighter]) {
        var a = fighters[i], b = fighters[1-i]
        critical = rng.next() < 0.18
        var value = amount * (critical ? 1.75 : 1)
        let shield = b.loadout.level("shield")
        let angle = atan2(a.y-b.y,a.x-b.x)-b.angle
        if shield > 0 && abs(atan2(sin(angle),cos(angle))) < Double(30+30*shield)*Double.pi/360 { value *= 0.25 }
        let actual = damage(&b, amount:value)
        if actual > 0 {
            hitSequence += 1
            a.hp = min(a.loadout.maxHP, a.hp+actual*0.1*Double(a.loadout.level("leech")))
            _ = damage(&a, amount:actual*0.12*Double(b.loadout.level("reflect")))
            if a.loadout.level("poison") > 0 { b.poison = Double(a.loadout.level("poison")); b.poisonTime = 3 }
        }
        fighters[i] = a; fighters[1-i] = b
    }
    @discardableResult public mutating func takeLoot(at index: Int) -> Bool {
        guard phase == .loot, loot.indices.contains(index) else { return false }
        inventory.append(loot[index]); loot = []; phase = .workshop; return true
    }
    @discardableResult public mutating func install(at index: Int, slot: Int) -> Bool {
        guard phase == .workshop, inventory.indices.contains(index) else { return false }
        let result = player.loadout.install(inventory[index], at:slot)
        guard result.accepted else { return false }
        inventory.remove(at:index)
        player.hp = min(player.hp, player.loadout.maxHP)
        if let returned = result.returned { inventory.append(returned) }
        return true
    }
    @discardableResult public mutating func unequip(slot: String, index: Int) -> Bool {
        guard phase == .workshop, ["gear", "skill"].contains(slot) else { return false }
        var items = slot == "gear" ? player.loadout.gear : player.loadout.skills
        guard items.indices.contains(index), let item = items[index] else { return false }
        inventory.append(item); items[index] = nil
        if slot == "gear" { player.loadout.gear = items } else { player.loadout.skills = items }
        player.hp = min(player.hp, player.loadout.maxHP)
        return true
    }
    public mutating func nextRound() {
        guard phase == .workshop else { return }
        guard level < 10 else { phase = .result; outcome = "十关通关"; return }
        level += 1; player = ArenaFighter(loadout:player.loadout, player:true)
        enemy = ArenaFighter(loadout:.roll(budget:100+(level-1)*18,rng:&rng),player:false)
        elapsed = 0; projectiles = []; phase = .ready; paused = true; outcome = ""
    }
    public var isValid: Bool {
        version == 1 && (1...10).contains(level) && (1...10).contains(tier)
        && player.loadout.isValid && enemy.loadout.isValid
        && [player.hp, enemy.hp, player.x, player.y, enemy.x, enemy.y, elapsed, finishTime].allSatisfy(\.isFinite)
        && elapsed >= 0 && elapsed < 46 && finishTime >= 0 && finishTime < 3
        && inventory.count <= 100 && loot.count <= 6
        && (inventory + loot).allSatisfy { ArenaCatalog.parts[$0.id] != nil && (1...3).contains($0.level) }
        && [player, enemy].allSatisfy { fighter in
            [fighter.x, fighter.y, fighter.vx, fighter.vy, fighter.angle, fighter.spin, fighter.hp,
             fighter.barrier, fighter.cooldown, fighter.poison, fighter.poisonTime].allSatisfy(\.isFinite)
            && fighter.hp >= 0 && fighter.hp <= fighter.loadout.maxHP
            && fighter.effects.values.allSatisfy(\.isFinite) && fighter.timers.values.allSatisfy(\.isFinite)
        }
        && projectiles.count <= 24 && projectiles.allSatisfy {
            (0...1).contains($0.owner) && [$0.x, $0.y, $0.vx, $0.vy, $0.life].allSatisfy(\.isFinite)
        }
    }
    public static func restore(from data: Data) -> Self? {
        guard data.count < 1_000_000, var game = try? JSONDecoder().decode(Self.self,from:data), game.isValid else { return nil }
        game.pause(); return game
    }
}
