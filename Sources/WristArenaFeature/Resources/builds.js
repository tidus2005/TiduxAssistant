// Serializable loadouts, three-level modules and an explicit linear power budget.
export const catalog={
 spike:{name:'三棱尖刺',icon:'✦',category:'近战武器',slot:'weapon',cost:12,mass:.20,desc:['三枚短刃 · 伤害×1','刃长+12% · 伤害×1.2','刃长+24% · 伤害×1.4']},
 staff:{name:'回旋长棍',icon:'━',category:'近战武器',slot:'weapon',cost:12,mass:.32,desc:['双端长棍','棍长+12% · 伤害×1.2','棍长+24% · 伤害×1.4']},
 hammer:{name:'重击战锤',icon:'⚒',category:'近战武器',slot:'weapon',cost:16,mass:.8,desc:['重锤 · 高惯量','锤头增大 · 伤害×1.2','巨锤 · 伤害×1.4']},
 ranger:{name:'连射弓',icon:'➶',category:'远程攻击',slot:'weapon',cost:14,mass:.12,desc:['发射实体箭矢','双箭 · 间隔缩短','三箭 · 间隔再缩短']},
 mage:{name:'奥术法杖',icon:'✧',category:'法术武器',slot:'weapon',cost:16,mass:.15,desc:['奥术弹 · 近距脉冲','双法球 · 强化脉冲','三法球 · 扩大脉冲']},
 shield:{name:'实体弧盾',icon:'◔',category:'护盾装备',slot:'gear',cost:10,mass:.3,desc:['60°实体盾 · 单层盾沿','90°实体盾 · 加厚盾沿','120°实体盾 · 重型盾沿']},
 plate:{name:'重装甲',icon:'⬡',category:'护盾装备',slot:'gear',cost:9,mass:.48,desc:['减伤10% · 生命+12','减伤20% · 生命+24','减伤30% · 生命+36']},
 poison:{name:'淬毒',icon:'☣',category:'附加技能',slot:'skill',cost:9,desc:['每秒1毒伤，持续3秒','每秒2毒伤，持续3秒','每秒3毒伤，持续3秒']},
 barrier:{name:'防御罩',icon:'◎',category:'防护技能',slot:'skill',cost:11,desc:['每8秒获得12吸收盾','每8秒获得24吸收盾','每8秒获得36吸收盾']},
 invincible:{name:'无敌',icon:'✺',category:'防护技能',slot:'skill',cost:12,desc:['每10秒无敌0.5秒','每10秒无敌0.9秒','每10秒无敌1.3秒']},
 dash:{name:'冲刺',icon:'»',category:'身法技能',slot:'skill',cost:8,desc:['每5秒朝对手加速0.3秒','加速0.5秒 · 更高推力','加速0.7秒 · 更高推力']},
 blink:{name:'瞬移',icon:'⌁',category:'身法技能',slot:'skill',cost:10,desc:['每7秒瞬移0.14距离','瞬移0.20距离','瞬移0.26距离']},
 shrink:{name:'缩小',icon:'⊙',category:'身法技能',slot:'skill',cost:9,desc:['每8秒缩至85%，持续2秒','缩至70%，持续2秒','缩至55%，持续2秒']},
 grow:{name:'巨大化',icon:'◉',category:'身法技能',slot:'skill',cost:10,desc:['每8秒增至115%，持续2秒','增至130%，持续2秒','增至145%，持续2秒']},
 heal:{name:'再生',icon:'+',category:'恢复技能',slot:'skill',cost:10,desc:['每6秒回复5生命','每6秒回复10生命','每6秒回复15生命']},
 leech:{name:'吸血',icon:'♥',category:'恢复技能',slot:'skill',cost:10,desc:['回复实际伤害的10%','回复实际伤害的20%','回复实际伤害的30%']},
 reflect:{name:'反伤',icon:'↩',category:'反击技能',slot:'skill',cost:11,desc:['反弹实际伤害的12%','反弹实际伤害的24%','反弹实际伤害的36%']}
};
export const tiers=['','I','II','III'];
export const levelOf=(a,id)=>[a.loadout?.weapon,...(a.loadout?.gear||[]),...(a.loadout?.skills||[])].find(x=>x?.id===id)?.level||0;
export function moduleCost(m){return m?catalog[m.id].cost*m.level:0;}
export function strength(a){if(!a.loadout)return 0;const ms=[a.loadout.weapon,...a.loadout.gear,...a.loadout.skills].filter(Boolean);const synergy=(levelOf(a,'leech')&&levelOf(a,'reflect')?4:0)+(levelOf(a,'grow')&&a.weapon==='hammer'?4:0);return Math.round(40+ms.reduce((s,m)=>s+moduleCost(m),0)+(a.loadout.core||0)+synergy);}
export function recalc(a,full=false){a.weapon=a.loadout.weapon.id;a.weaponLevel=a.loadout.weapon.level;a.scaleFactor=1;a.radius=.055;a.baseMass=1+catalog[a.weapon].mass*a.weaponLevel+a.loadout.gear.reduce((s,m)=>s+(m?catalog[m.id].mass*m.level:0),0);a.mass=a.baseMass;a.maxHp=80+(a.loadout.core||0)*2+levelOf(a,'plate')*12;a.hp=full?a.maxHp:Math.min(a.hp,a.maxHp);a.power=strength(a);a.modifiers={poison:0,leech:0,speed:0,health:0,power:Math.round((a.weaponLevel-1)*3)};a.armor=null;a.durability=60;a.maxDurability=60;a.disarmedRemaining=0;a.states={};a.timers={};a.barrierHp=0;a.poison={stacks:0,remaining:0,level:0};a.skillCooldown=0;a.slowRemaining=0;a.cooldown=0;a.flash=0;a.fireCooldown=.4;}
export function rollLoadout(r,budget,rand){const keys=Object.keys(catalog),weapon=keys.filter(k=>catalog[k].slot==='weapon');const a={weapon:weapon[Math.floor(rand(r)*weapon.length)],loadout:{weapon:null,gear:[null,null],skills:[null,null,null],core:0}};a.loadout.weapon={id:a.weapon,level:1};
 for(let tries=0;tries<60;tries++){const id=keys[Math.floor(rand(r)*keys.length)],def=catalog[id];if(def.slot==='weapon')continue;const arr=def.slot==='gear'?a.loadout.gear:a.loadout.skills;const same=arr.findIndex(m=>m?.id===id),idx=same>=0?same:arr.indexOf(null);if(idx<0||arr[idx]?.level===3)continue;const old=arr[idx];arr[idx]={id,level:(old?.level||0)+1};if(strength(a)>budget)arr[idx]=old;}
 while(a.loadout.weapon.level<3&&strength(a)+catalog[a.weapon].cost<=budget)a.loadout.weapon.level++;
 a.loadout.core=Math.max(0,budget-strength(a));return a.loadout;}
export function createRuntime(a){recalc(a,true);}
export function moduleText(m){return m?`${catalog[m.id].icon} ${catalog[m.id].name} ${tiers[m.level]}`:'空槽';}
export function moduleDesc(m){return m?catalog[m.id].desc[m.level-1]:'';}
export function updateSkills(r,a,b,dt,rand,emit){
 const state=a.states;for(const k of Object.keys(state))state[k]=Math.max(0,state[k]-dt);
 const oldScale=a.scaleFactor; a.scaleFactor=(state.shrink>0?1-.15*levelOf(a,'shrink'):1)*(state.grow>0?1+.15*levelOf(a,'grow'):1);a.radius=.055*a.scaleFactor;a.mass=a.baseMass*a.scaleFactor*a.scaleFactor;
 // Size changes are handled by the same capsule solver, including weapon shape scaling.
 for(const m of a.loadout.skills){if(!m||['poison','leech','reflect'].includes(m.id))continue;a.timers[m.id]=(a.timers[m.id]??(1.3+rand(r)*1.3))-dt;if(a.timers[m.id]>0)continue;
 const n=m.level,id=m.id;a.timers[id]={barrier:8,invincible:10,dash:5,blink:7,shrink:8,grow:8,heal:6}[id];
 if(id==='barrier'){a.barrierHp=12*n;state.barrier=4;}
 if(id==='invincible')state.invincible=.1+.4*n;
 if(id==='heal'){a.hp=Math.min(a.maxHp,a.hp+5*n);state.heal=.6;}
 if(id==='dash'){const dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy)||1;a.vx+=dx/d*(.25+.18*n);a.vy+=dy/d*(.25+.18*n);state.dash=.1+.2*n;}
 if(id==='blink'){const angle=rand(r)*Math.PI*2,d=.08+.06*n;a.blinkFrom={x:a.x,y:a.y};a.x=Math.max(.20,Math.min(.8,a.x+Math.cos(angle)*d));a.y=Math.max(.20,Math.min(r.arena.height-.20,a.y+Math.sin(angle)*d));state.blink=.45;}
 if(id==='shrink'||id==='grow')state[id]=2;
 emit(r,{type:'ability',ability:id,source:a.id,target:a.id,damage:0,x:a.x,y:a.y,time:r.totalTime,tick:r.tick});
 }
 if(!state.barrier)a.barrierHp=0;
}
export function mitigate(a,damage){if(a.states?.invincible>0)return 0;let out=damage*(1-.1*levelOf(a,'plate'));if(a.barrierHp>0){const block=Math.min(a.barrierHp,out);a.barrierHp-=block;out-=block;}return out;}
