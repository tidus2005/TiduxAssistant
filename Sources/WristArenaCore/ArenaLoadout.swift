import Foundation

public struct ArenaPart: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var level: Int
    public init(_ id: String, level: Int = 1) { self.id = id; self.level = min(3, max(1, level)) }
    public var title: String { "\(ArenaCatalog.parts[id]?.name ?? id) \(["", "I", "II", "III"][min(3, max(1, level))])" }
}
public struct ArenaPartDefinition: Codable, Sendable {
    public let name: String
    public let icon: String
    public let slot: String
    public let cost: Int
    public let mass: Double?
    public let desc: [String]
}
public enum ArenaCatalog {
    public static let parts: [String: ArenaPartDefinition] = {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parts = try? JSONDecoder().decode([String: ArenaPartDefinition].self, from: data) else {
            preconditionFailure("Missing bundled arena catalog")
        }
        return parts
    }()
}
public struct ArenaLoadout: Codable, Equatable, Sendable {
    public var weapon = ArenaPart("spike")
    public var gear: [ArenaPart?] = [nil, nil]
    public var skills: [ArenaPart?] = [nil, nil, nil]
    public var core = 0
    public var parts: [ArenaPart] { [weapon] + gear.compactMap { $0 } + skills.compactMap { $0 } }
    public func level(_ id: String) -> Int { parts.first { $0.id == id }?.level ?? 0 }
    public var power: Int {
        40 + core + parts.reduce(0) { $0 + (ArenaCatalog.parts[$1.id]?.cost ?? 0) * $1.level }
        + (level("leech") > 0 && level("reflect") > 0 ? 4 : 0)
        + (level("grow") > 0 && weapon.id == "hammer" ? 4 : 0)
    }
    public var maxHP: Double { Double(80 + core * 2 + level("plate") * 12) }
    public var mass: Double { 1 + parts.reduce(0) { $0 + (ArenaCatalog.parts[$1.id]?.mass ?? 0) * Double($1.level) } }
    public var isValid: Bool {
        gear.count == 2 && skills.count == 3 && core >= 0 && core <= 1000
        && parts.allSatisfy { ArenaCatalog.parts[$0.id] != nil && (1...3).contains($0.level) }
        && ArenaCatalog.parts[weapon.id]?.slot == "weapon"
        && gear.compactMap { $0 }.allSatisfy { ArenaCatalog.parts[$0.id]?.slot == "gear" }
        && skills.compactMap { $0 }.allSatisfy { ArenaCatalog.parts[$0.id]?.slot == "skill" }
        && Set(parts.map(\.id)).count == parts.count
    }
    static func roll(budget: Int, rng: inout ArenaRandom) -> Self {
        var result = Self()
        let keys = ArenaCatalog.parts.keys.sorted()
        let weapons = keys.filter { ArenaCatalog.parts[$0]?.slot == "weapon" }
        result.weapon = ArenaPart(weapons[rng.index(weapons.count)])
        for _ in 0..<60 {
            let key = keys[rng.index(keys.count)]
            guard let def = ArenaCatalog.parts[key], def.slot != "weapon" else { continue }
            var slots = def.slot == "gear" ? result.gear : result.skills
            guard let i = slots.firstIndex(where: { $0?.id == key }) ?? slots.firstIndex(where: { $0 == nil }),
                  (slots[i]?.level ?? 0) < 3 else { continue }
            slots[i] = ArenaPart(key, level: (slots[i]?.level ?? 0) + 1)
            var candidate = result
            if def.slot == "gear" { candidate.gear = slots } else { candidate.skills = slots }
            if candidate.power <= budget { result = candidate }
        }
        while result.weapon.level < 3 && result.power + ArenaCatalog.parts[result.weapon.id]!.cost <= budget {
            result.weapon.level += 1
        }
        result.core = max(0, budget - result.power)
        return result
    }
    // Replace only the requested slot; merge duplicate parts up to III without losing max-level items.
    public mutating func install(_ item: ArenaPart, at index: Int) -> (accepted: Bool, returned: ArenaPart?) {
        guard let def = ArenaCatalog.parts[item.id], (1...3).contains(item.level) else { return (false, nil) }
        if def.slot == "weapon" {
            guard index == 0 else { return (false, nil) }
            if weapon.id == item.id {
                guard weapon.level < 3 else { return (false, nil) }
                weapon.level = min(3, max(weapon.level, item.level) + 1)
                return (true, nil)
            }
            let previous = weapon; weapon = item; return (true, previous)
        }
        var slots = def.slot == "gear" ? gear : skills
        guard slots.indices.contains(index) else { return (false, nil) }
        let target = slots.firstIndex { $0?.id == item.id } ?? index
        let previous = slots[target]
        if previous?.id == item.id {
            guard previous!.level < 3 else { return (false, nil) }
            slots[target] = ArenaPart(item.id, level: min(3, max(previous!.level, item.level) + 1))
        } else { slots[target] = item }
        if def.slot == "gear" { gear = slots } else { skills = slots }
        return (true, previous?.id == item.id ? nil : previous)
    }
}
struct ArenaRandom: Codable, Sendable {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9007199254740992
    }
    mutating func index(_ count: Int) -> Int { min(count - 1, Int(next() * Double(count))) }
}
