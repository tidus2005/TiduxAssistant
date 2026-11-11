import SwiftUI
import WristArenaCore
#if os(watchOS)
import WatchKit
#endif

public struct ArenaWatchView: View {
    public var isActive: Bool
    public var attentionCount: Int
    public var onReturnToAssistant: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage("com.tidux.codex.arena.watch.v1") private var saved = Data()
    @State private var game = ArenaGame()
    @State private var loaded = false
    @State private var visible = false
    @State private var showBuild = false
    @State private var showNewGame = false
    @State private var storageError = false
    @State private var challenge = 1
    @AppStorage("com.tidux.codex.arena.haptics") private var haptics = true
    public init(isActive: Bool = true, attentionCount: Int = 0, onReturnToAssistant: @escaping () -> Void = {}) {
        self.isActive = isActive; self.attentionCount = attentionCount; self.onReturnToAssistant = onReturnToAssistant
    }
    private var canRun: Bool { isActive && visible && scenePhase == .active && !isLuminanceReduced && !showBuild }
    private var clockRunning: Bool { canRun && !game.paused }
    public var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                HStack {
                    Text("大作战").font(.headline)
                    Spacer(minLength: 0)
                    if [.ready, .battle, .finishing].contains(game.phase) {
                        Button {
                            if game.paused { game.resume() } else { pause() }; persist()
                        } label: { Image(systemName: game.paused ? "play.fill" : "pause.fill").padding(5) }
                        .buttonStyle(.plain).tint(.mint)
                        .accessibilityLabel(game.paused ? "继续战斗" : "暂停")
                        .accessibilityIdentifier("arena.playPause")
                    }
                    Button { pause(); onReturnToAssistant() } label: { Image(systemName:"sparkles") }
                        .accessibilityLabel("返回 Codex 助手")
                        .accessibilityIdentifier("arena.returnAssistant")
                        .buttonStyle(.plain)
                }
                if attentionCount > 0 {
                    Button("\(attentionCount) 项任务待处理") { pause(); onReturnToAssistant() }
                        .font(.caption2).tint(.orange)
                }
                if game.phase == .battle || game.phase == .finishing || game.phase == .ready {
                    ArenaBattleCanvas(game:game)
                        .aspectRatio(1/1.22,contentMode:.fit)
                        .frame(maxHeight: 170)
                        .overlay(alignment:.top) {
                            Text(game.phase == .finishing ? game.outcome : "\(game.mode == .campaign ? "关卡" : "挑战") \(game.mode == .campaign ? game.level : game.tier) · \(Int(max(0,45-game.elapsed))) 秒")
                                .font(.caption2.bold()).padding(4).background(.black.opacity(0.6),in:Capsule())
                        }

                }
                if game.phase == .loot {
                    Text("胜利 · 拆取一件零件").font(.headline)
                    ForEach(Array(game.loot.enumerated()),id: \.offset) { i, item in
                        Button(item.title) { game.takeLoot(at:i); persist() }
                    }
                }
                if game.phase == .workshop { workshop }
                if game.phase == .result { Text(game.outcome).font(.title3.bold()).foregroundStyle(.mint) }
                Button("装备与技能") { pause(); showBuild = true }.font(.caption)
                    .accessibilityIdentifier("arena.build")
                if game.paused {
                    Button("新对局") { showNewGame = true }.font(.caption)
                }
                if storageError { Text("上次存档无法读取，已开启新对局。").font(.caption2).foregroundStyle(.orange) }
            }.padding(.horizontal,5)
        }
        .sheet(isPresented:$showBuild) { buildDetails }
        .sheet(isPresented:$showNewGame) { newGameSheet }
        .onAppear {
            visible = true
            if !loaded {
                if !saved.isEmpty {
                    if let restored = ArenaGame.restore(from:saved) { game = restored } else { storageError = true }
                }
                loaded = true
            }
        }
        .onDisappear { visible = false; pause() }
        .onChange(of:canRun) { _, active in if !active { pause() } }
        .onChange(of:attentionCount) { old, new in if new > old { pause() } }
        .task(id:clockRunning) {
            guard clockRunning else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(33)) } catch { return }
                guard !Task.isCancelled, canRun else { return }
                let previousPhase = game.phase
                game.advance(seconds:1/30)
                if previousPhase != game.phase {
                    persist()
                    #if os(watchOS)
                    if haptics && game.phase == .finishing { WKInterfaceDevice.current().play(.click) }
                    #endif
                }
            }
        }
    }
    private var buildDetails: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:8) {
                Text("我的构筑 · \(game.player.loadout.power)").font(.headline)
                ForEach(game.player.loadout.parts) { part in
                    Text(part.title).font(.caption.bold())
                    Text(ArenaCatalog.parts[part.id]?.desc[part.level-1] ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("结算触觉",isOn:$haptics)
                Text("手表原生适配 · 手机与 Mac 保留原版完整物理。存档各端独立；离开或手腕放下会暂停。").font(.caption2).foregroundStyle(.secondary)
            }.padding()
        }
    }
    private var newGameSheet: some View {
        ScrollView {
            VStack(spacing:10) {
                Text("开启新对局").font(.headline)
                Text("会替换本机当前对局进度").font(.caption2).foregroundStyle(.secondary)
                Stepper("挑战 \(challenge)/10", value: $challenge, in: 1...10)
                Button("随机对战") { game = ArenaGame(tier:challenge); showNewGame = false; persist() }
                Button("十关闯关") { game = ArenaGame(mode:.campaign); showNewGame = false; persist() }
                Button("取消") { showNewGame = false }
            }.padding()
        }
    }
    private var workshop: some View {
        VStack(spacing:7) {
            Text("战利品工坊").font(.headline)
            ForEach(Array(game.inventory.enumerated()),id: \.offset) { i, item in
                VStack {
                    Text(item.title).font(.caption)
                    let slotType = ArenaCatalog.parts[item.id]?.slot ?? "weapon"
                    let slots = slotType == "weapon" ? [Optional(game.player.loadout.weapon)] : slotType == "gear" ? game.player.loadout.gear : game.player.loadout.skills
                    ForEach(slots.indices,id: \.self) { slot in
                        Button("装配 → \(slots[slot]?.title ?? "空槽")") { _ = game.install(at:i,slot:slot); persist() }
                            .font(.caption2)
                    }
                }
            }
            ForEach(game.player.loadout.gear.indices, id: \.self) { i in
                if let item = game.player.loadout.gear[i] {
                    Button("卸下 " + item.title) { game.unequip(slot:"gear", index:i); persist() }.font(.caption2)
                }
            }
            ForEach(game.player.loadout.skills.indices, id: \.self) { i in
                if let item = game.player.loadout.skills[i] {
                    Button("卸下 " + item.title) { game.unequip(slot:"skill", index:i); persist() }.font(.caption2)
                }
            }
            Button(game.level == 10 ? "领取通关结算" : "下一关") { game.nextRound(); persist() }.tint(.mint)
        }
    }
    private func pause() { game.pause(); if loaded { persist() } }
    private func persist() {
        if let data = try? JSONEncoder().encode(game) { saved = data }
    }
}
private struct ArenaBattleCanvas: View {
    let game: ArenaGame
    var body: some View {
        Canvas { context,size in
            let s = size.width
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color(red:0.04,green:0.09,blue:0.07)))
            for y in stride(from:0.1,through:1.22,by:0.1) {
                var path = Path(); path.move(to:CGPoint(x:0,y:y*s)); path.addLine(to:CGPoint(x:s,y:y*s))
                context.stroke(path,with:.color(.mint.opacity(0.09)),lineWidth:0.5)
            }
            for (i,a) in [game.player,game.enemy].enumerated() {
                let color: Color = i == 0 ? .mint : .pink
                let center = CGPoint(x:a.x*s,y:a.y*s)
                let offsets: [Double] = a.loadout.weapon.id == "spike" ? [0,.pi*2/3,.pi*4/3] : a.loadout.weapon.id == "staff" ? [0,.pi] : [0]
                for offset in offsets {
                    var blade = Path(); blade.move(to:center)
                    let tip = CGPoint(x:(a.x+cos(a.angle+offset)*a.reach)*s,y:(a.y+sin(a.angle+offset)*a.reach)*s)
                    blade.addLine(to:tip); context.stroke(blade,with:.color(color),style:StrokeStyle(lineWidth:a.loadout.weapon.id == "hammer" ? 5 : 3,lineCap:.round))
                }
                if a.barrier > 0 || a.effects["invincible",default:0] > 0 {
                    let r = (a.radius+0.025)*s
                    context.stroke(Path(ellipseIn:CGRect(x:center.x-r,y:center.y-r,width:r*2,height:r*2)),with:.color(a.effects["invincible",default:0] > 0 ? .yellow : .cyan),lineWidth:2)
                }
                let shield = a.loadout.level("shield")
                if shield > 0 {
                    var arc = Path(); let half = Double(30+30*shield)*Double.pi/360
                    arc.addArc(center:center,radius:0.08*a.scale*s,startAngle:.radians(a.angle-half),endAngle:.radians(a.angle+half),clockwise:false)
                    context.stroke(arc,with:.color(.white.opacity(0.8)),lineWidth:Double(shield)+1)
                }
                let r = a.radius*s
                context.fill(Path(ellipseIn:CGRect(x:center.x-r,y:center.y-r,width:r*2,height:r*2)),with:.color(color))
                context.draw(Text("\(Int(max(0,a.hp)))").font(.system(size:9,weight:.heavy)).foregroundStyle(.black),at:center)
            }
            for p in game.projectiles {
                context.fill(Path(ellipseIn:CGRect(x:p.x*s-2,y:p.y*s-2,width:4,height:4)),with:.color(.yellow))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius:22))
        .accessibilityLabel("战场，我方生命 \(Int(game.player.hp))，对方生命 \(Int(game.enemy.hp))")
    }
}
