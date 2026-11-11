import {catalog,levelOf,recalc,rollLoadout,strength,updateSkills,mitigate} from './builds.js';
// Browser prototype rules v1, compound contact physics revision 4. Pure serializable simulation; no DOM or wall-clock reads.
export const weapons = {
 spike:{name:'三棱尖刺',base:9,omega:Math.PI*2/3},
 staff:{name:'回旋长棍',base:11,omega:Math.PI*5/6},
 hammer:{name:'重击战锤',base:16,omega:Math.PI*2},
 ranger:{name:'游侠弓',base:6,omega:Math.PI/2,ranged:true},
 mage:{name:'秘法杖',base:8,omega:Math.PI/2,ranged:true}
};
export const difficulties={preview:{name:'试玩难度',enemyHp:[45,48,56,65,78],enemyDamage:.88},design:{name:'设计难度',enemyHp:[45,60,75,90,110],enemyDamage:1}};
export const FIXED_DT=1/120;
// Per-run geometry is immutable configuration, not shared mutable solver state.
export const duelArena=Object.freeze({width:1,height:242/198,corner:.20});
export const duelPalettes=Object.freeze([
 {id:'coral',name:'珊瑚红',color:'#ed6576',light:'#ffb5bf',dark:'#9f394b'},
 {id:'lime',name:'青柠绿',color:'#b7d850',light:'#e3f6ae',dark:'#6f8f2a'},
 {id:'aqua',name:'湖水青',color:'#56c9cb',light:'#b0eeee',dark:'#287f87'},
 {id:'gold',name:'暖金黄',color:'#e7b44b',light:'#fbe1a0',dark:'#a57326'},
 {id:'lilac',name:'丁香紫',color:'#b28ae3',light:'#e1c9fa',dark:'#7653a8'},
 {id:'sky',name:'晴空蓝',color:'#6aa9ec',light:'#bddbff',dark:'#3b6fa6'}
].map(Object.freeze));
const emptyModifiers=Object.freeze({poison:0,leech:0,speed:0,health:0,power:0});
const modifiers=(r,a)=>a.loadout?(a.modifiers||emptyModifiers):r.mode==='duel'?(a.modifiers||emptyModifiers):(a===r.p?r.build:emptyModifiers);
const arenaFor=r=>r.arena||rules;

const TAU=Math.PI*2, clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
export const rules={width:1,height:.72,radius:.055,cooldown:.35,limit:45,corner:.07,durabilityMax:60,damageWear:.65,recoverySeconds:2.5,skillCooldown:6,skillRadius:.30,skillDamage:12,projectileCap:24};
function random(r){let t=r.rng+=0x6D2B79F5;t=Math.imul(t^t>>>15,t|1);t^=t+Math.imul(t^t>>>7,t|61);r.rng>>>=0;return ((t^t>>>14)>>>0)/4294967296;}
export function speedFactor(level){return [1,1.15,1.25][clamp(level,0,2)];}
function entity(id,weapon,hp){return {id,weapon,hp,maxHp:hp,radius:rules.radius,x:0,y:0,vx:0,vy:0,angle:0,angularVelocity:weapons[weapon].omega,spinKick:0,armor:null,poison:{stacks:0,remaining:0,level:0},durability:rules.durabilityMax,maxDurability:rules.durabilityMax,disarmedRemaining:0,fireCooldown:.4,skillCooldown:0,slowRemaining:0,cooldown:0,flash:0};}
export function createRun(seed=1,weapon='spike',difficulty='preview'){
 if(!weapons[weapon]) weapon='spike';
 if(!difficulties[difficulty])difficulty='preview';
 const r={version:1,physicsRevision:4,mode:'campaign',arena:{width:1,height:.72,corner:.07},eventSeq:0,projectileSeq:0,projectiles:[],droppedWeapons:[],difficulty,seed:seed>>>0,rng:seed>>>0,phase:'battle',level:1,p:entity('p',weapon,weapon==='hammer'?150:100),e:null,build:{poison:0,leech:0,speed:0,health:0,power:0},choices:[],elapsed:0,totalTime:0,tick:0,accumulator:0,stats:{firstHit:null,hits:0,damage:0,kills:0,timeouts:0,levels:[]},outcome:null,events:[],lastTemplate:null};startLevel(r);return r;
}
// Both seats use independent samples of exactly the same class/color/shield distribution.
// Color is cosmetic. Matching colors/classes and no-shield pairs are intentionally legal.
export function createDuel(seed=1){
 const r=createRun(seed);r.mode='duel';r.difficulty='duel';r.arena={...duelArena};r.rng=r.seed;
 const classes=Object.keys(weapons),sample=id=>{
  const weapon=classes[Math.floor(random(r)*classes.length)],palette={...duelPalettes[Math.floor(random(r)*duelPalettes.length)]},shield=random(r)<.35,shieldAngle=random(r)*TAU,angle=random(r)*TAU;
  const a=entity(id,weapon,weapon==='hammer'?150:100);a.palette=palette;a.color=palette.color;a.modifiers={...emptyModifiers};a.angle=angle;
  if(shield)a.armor={angle:shieldAngle,arc:Math.PI/2};
  return a;
 };
 r.p=sample('p');r.e=sample('e');r.build={...emptyModifiers};r.enemyName=weapons[r.e.weapon].name;
 const heading=(random(r)-.5)*.8,slope=(random(r)-.5)*.20;
 for(const [a,sign] of [[r.p,1],[r.e,-1]]){
  a.x=.5-sign*Math.cos(heading)*.27;a.y=r.arena.height/2-sign*Math.sin(heading)*.27;
  a.vx=sign*Math.cos(heading+slope)*.45;a.vy=sign*Math.sin(heading+slope)*.45;
 }
 r.config={mode:'duel',seed:r.seed,arena:{...r.arena},shieldChance:.35,autoSkill:true,fighters:{}};
 for(const a of [r.p,r.e])r.config.fighters[a.id]={weapon:a.weapon,palette:a.palette.id,color:a.color,maxHp:a.maxHp,armor:a.armor?{...a.armor}:null,angle:a.angle,x:a.x,y:a.y,vx:a.vx,vy:a.vy,modifiers:{...a.modifiers}};
 return r;
}
function startLevel(r){
 let template='charge';
 if(r.level===5)template='boss';
 else if(r.level>1){const pool=['charge','staff','armor','ranger'].filter(x=>x!==r.lastTemplate);template=pool[Math.floor(random(r)*pool.length)];}
 r.lastTemplate=template;r.enemyName={charge:'直冲球',staff:'扫棍球',armor:'护甲球',boss:'铁甲重锤',ranger:'游侠弓手'}[template];
 r.e=entity('e',template==='ranger'?'ranger':template==='staff'?'staff':template==='boss'?'hammer':'spike',difficulties[r.difficulty||'design'].enemyHp[r.level-1]);
 if(template==='armor'||template==='boss')r.e.armor={angle:random(r)*TAU,arc:Math.PI/2};
 r.projectiles=[];r.droppedWeapons=[];r.elapsed=0;r.accumulator=0;r.phase='battle';r.choices=[];r.events=[];
 // Opening trajectories intersect; compound weapons can parry before a damaging contact.
 const y=.30+random(r)*.12, slope=(random(r)-.5)*.20;
 for(const [e,sign] of [[r.p,1],[r.e,-1]]){e.x=sign===1?.22:.78;e.y=y+sign*.014;e.angle=(sign===1?0:Math.PI)-weapons[e.weapon].omega*.43+(random(r)-.5)*.2;e.durability=e.maxDurability;e.disarmedRemaining=0;e.fireCooldown=.4;e.skillCooldown=0;e.slowRemaining=0;e.cooldown=0;e.spinDirection=Math.sign(weapons[e.weapon].omega)||1;e.spinKick=0;e.angularVelocity=weapons[e.weapon].omega;e.poison={stacks:0,remaining:0,level:0};const speed=.45*(e===r.p?speedFactor(r.build.speed):template==='staff'?.88:1);e.vx=sign*speed/Math.sqrt(1+slope*slope);e.vy=sign*slope*speed/Math.sqrt(1+slope*slope);}
}
export function weaponShapes(e){
 if(e.disarmedRemaining>0)return [];
 const point=(a,d)=>({x:e.x+Math.cos(a)*d,y:e.y+Math.sin(a)*d});
 const segment=(a,d1,d2,radius)=>{const p=point(a,d1*1.2*(e.scaleFactor||1)*(1+.12*((e.weaponLevel||1)-1))),q=point(a,d2*1.2*(e.scaleFactor||1)*(1+.12*((e.weaponLevel||1)-1)));return {x1:p.x,y1:p.y,x2:q.x,y2:q.y,radius:radius*1.2*(e.scaleFactor||1)*(1+.08*((e.weaponLevel||1)-1))};};
 if(e.weapon==='ranger')return [segment(e.angle,-.075,.075,.009),segment(e.angle+Math.PI/2,.035,.075,.012)];
 if(e.weapon==='mage')return [segment(e.angle,.035,.11,.010),segment(e.angle,.11,.11,.021)];
 if(e.weapon==='staff')return [segment(e.angle,-.14,.14,.012)];
 if(e.weapon==='hammer')return [segment(e.angle,.035,.10,.010),segment(e.angle,.10,.10,.032)];
 return [0,TAU/3,TAU*2/3].map(a=>segment(e.angle+a,.045,.090,.012));
}
export function damageForSpeed(base,v){return v<.05?0:clamp(Math.round(base*clamp(v/.60,.65,1.8)),4,18);}
export function armored(e,angle){if(e.loadout)return false;if(!e.armor)return false;const d=Math.atan2(Math.sin(angle-e.armor.angle),Math.cos(angle-e.armor.angle));return Math.abs(d)<=e.armor.arc/2+1e-10;}
export function leechAmount(actual,level){return Math.min(4,actual*([0,.15,.25][level]||0));}
function hit(a,b,power){
 if(a.cooldown>1e-9||a.disarmedRemaining>0||weapons[a.weapon].ranged)return null;let best=null;
 for(const s of weaponShapes(a)){
  const dx=s.x2-s.x1,dy=s.y2-s.y1,l=dx*dx+dy*dy,t=l?clamp(((b.x-s.x1)*dx+(b.y-s.y1)*dy)/l,0,1):0;
  const x=s.x1+t*dx,y=s.y1+t*dy,rx=b.x-x,ry=b.y-y,d=Math.hypot(rx,ry);
  if(d>b.radius+s.radius)continue;
  const nx=d>1e-8?rx/d:1,ny=d>1e-8?ry/d:0,w=angular(a);
  const v=(a.vx-w*(y-a.y)-b.vx)*nx+(a.vy+w*(x-a.x)-b.vy)*ny;
  let damage=a.loadout?impactDamage(a,b,v,weapons[a.weapon].base+power):damageForSpeed(weapons[a.weapon].base+power,v);if(!damage)continue;
  const armor=armored(b,Math.atan2(-ny,-nx));if(armor)damage=Math.max(1,Math.ceil(damage*.25));
  if(!best||damage>best.damage)best={source:a.id,target:b.id,damage,x:b.x-nx*b.radius,y:b.y-ny*b.radius,nx,ny,speed:v,armor,type:'hit'};
 }return best;
}
// Compound rigid body: circle plus attached capsules; internal overlaps are structural.
// Unit mass and shape-dependent inertia; both contact impulses and position corrections
// act on the shared transform. Capsules remain attached under every contact.
const inertia={spike:.00432,staff:.006912,hammer:.012,ranger:.0040,mage:.0050};
export const contactTolerance=.00002;
const cross=(x,y,nx,ny)=>x*ny-y*nx;
function parts(e){return [...shieldShapes(e),{x1:e.x,y1:e.y,x2:e.x,y2:e.y,radius:e.radius,kind:'body'},...weaponShapes(e).map(s=>({...s,kind:'weapon'}))];}
function closest(a,b){
 const ux=a.x2-a.x1,uy=a.y2-a.y1,vx=b.x2-b.x1,vy=b.y2-b.y1,wx=a.x1-b.x1,wy=a.y1-b.y1;
 const aa=ux*ux+uy*uy,bb=ux*vx+uy*vy,cc=vx*vx+vy*vy,dd=ux*wx+uy*wy,ee=vx*wx+vy*wy;
 let t=0,u=0;
 if(aa<1e-16)u=cc?clamp(ee/cc,0,1):0;
 else if(cc<1e-16)t=clamp(-dd/aa,0,1);
 else {const den=aa*cc-bb*bb;t=den>1e-16?clamp((bb*ee-cc*dd)/den,0,1):0;u=(bb*t+ee)/cc;if(u<0){u=0;t=clamp(-dd/aa,0,1);}else if(u>1){u=1;t=clamp((bb-dd)/aa,0,1);}}
 return {ax:a.x1+t*ux,ay:a.y1+t*uy,bx:b.x1+u*vx,by:b.y1+u*vy};
}
function contacts(r,margin=0){
 const out=[],a=r.p,b=r.e,arena=arenaFor(r),halfW=arena.width/2,halfH=arena.height/2;
 const near=Math.hypot(a.x-b.x,a.y-b.y)<=extent(a)+extent(b)+margin;
 const wallNear=e=>e.x<extent(e)+arena.corner+margin||e.x>arena.width-extent(e)-arena.corner-margin||e.y<extent(e)+arena.corner+margin||e.y>arena.height-extent(e)-arena.corner-margin;
 const aw=wallNear(a),bw=wallNear(b);if(!near&&!aw&&!bw)return out;
 const ap=near||aw?parts(a):[],bp=near||bw?parts(b):[];
 if(near)for(const sa of ap)for(const sb of bp){const q=closest(sa,sb),dx=q.bx-q.ax,dy=q.by-q.ay,d=Math.hypot(dx,dy),depth=sa.radius+sb.radius-d;if(depth < -margin)continue;
 let nx,ny;if(d>1e-10){nx=dx/d;ny=dy/d;}else{const cd=Math.hypot(b.x-a.x,b.y-a.y)||1;nx=(b.x-a.x)/cd;ny=(b.y-a.y)/cd;if(!nx&&!ny)nx=1;}
 out.push({a,b,nx,ny,x:(q.ax+nx*sa.radius+q.bx-nx*sb.radius)/2,y:(q.ay+ny*sa.radius+q.by-ny*sb.radius)/2,depth,kind:sa.kind+'-'+sb.kind});
 }
 // Signed distance to the rounded rectangle. It is convex, so constraining
 // both segment endpoints to the radius-eroded boundary contains the entire capsule.
 for(const [e,shapes] of [[a,aw?ap:[]],[b,bw?bp:[]]])for(const s of shapes)for(const [x,y] of [[s.x1,s.y1],...(s.x1===s.x2&&s.y1===s.y2?[]:[[s.x2,s.y2]])]){
 const qx=Math.abs(x-halfW)-(halfW-arena.corner),qy=Math.abs(y-halfH)-(halfH-arena.corner),ox=Math.max(qx,0),oy=Math.max(qy,0),len=Math.hypot(ox,oy),sd=len+Math.min(Math.max(qx,qy),0)-arena.corner,depth=sd+s.radius;
 if(depth < -margin)continue;let nx=0,ny=0;if(len>1e-12){nx=ox/len*Math.sign(x-halfW);ny=oy/len*Math.sign(y-halfH);}else if(qx>qy)nx=Math.sign(x-halfW);else ny=Math.sign(y-halfH);
 out.push({a:e,b:null,nx,ny,x:x+nx*s.radius,y:y+ny*s.radius,depth,kind:s.kind+'-wall'});
 }return out;
}
export function inspectContacts(r){const cs=contacts(r);return {maxPenetration:Math.max(0,...cs.map(c=>c.depth)),contacts:cs.map(({a,b,...c})=>({...c,a:a.id,b:b?.id||'wall'}))};}
function applyContact(c,j,position=false){
 const {a,b,nx,ny,x,y}=c,ra=cross(x-a.x,y-a.y,nx,ny),rb=b?cross(x-b.x,y-b.y,nx,ny):0;
 if(position){a.x-=nx*j/(a.mass||1);a.y-=ny*j/(a.mass||1);a.angle-=ra*j/bodyInertia(a);if(b){b.x+=nx*j/(b.mass||1);b.y+=ny*j/(b.mass||1);b.angle+=rb*j/bodyInertia(b);}}
 else {a.vx-=nx*j/(a.mass||1);a.vy-=ny*j/(a.mass||1);a.angularVelocity-=ra*j/bodyInertia(a);if(b){b.vx+=nx*j/(b.mass||1);b.vy+=ny*j/(b.mass||1);b.angularVelocity+=rb*j/bodyInertia(b);}}
}
function mass(c){return 1/(c.a.mass||1)+(c.b?1/(c.b.mass||1):0)+cross(c.x-c.a.x,c.y-c.a.y,c.nx,c.ny)**2/bodyInertia(c.a)+(c.b?cross(c.x-c.b.x,c.y-c.b.y,c.nx,c.ny)**2/bodyInertia(c.b):0);}
function closing(c){const {a,b,x,y,nx,ny}=c;return (a.vx-angular(a)*(y-a.y)-(b?b.vx-angular(b)*(y-b.y):0))*nx+(a.vy+angular(a)*(x-a.x)-(b?b.vy+angular(b)*(x-b.x):0))*ny;}
function solve(r,emit=true){
 const cs=contacts(r,.00004).map(c=>({...c,bounce:Math.max(0,closing(c))*.82,impulse:0}));
 for(let k=0;k<12;k++)for(const c of cs){const j=(closing(c)+c.bounce)/mass(c),next=Math.max(0,c.impulse+j);applyContact(c,next-c.impulse);c.impulse=next;}
 // A real weapon impulse may reverse the motor direction until the next clash.
 for(const c of cs)if(c.b&&c.kind==='weapon-weapon'&&c.impulse>1e-6&&c.bounce>.041){for(const q of [c.a,c.b])if(Math.abs(q.angularVelocity)>.8)q.spinDirection=Math.sign(q.angularVelocity);}
 // Cosmetic contact events do not apply additional impulses.
 if(emit&&r.totalTime-(Number.isFinite(r.lastClashTime)?r.lastClashTime:-Infinity)>=.12-1e-10){
  const clash=cs.filter(c=>c.b&&c.kind==='weapon-weapon'&&c.bounce>.05*.82&&c.impulse>1e-6).sort((a,b)=>b.impulse-a.impulse)[0];
  if(clash){r.lastClashTime=r.totalTime;if(r.stats.firstClash==null)r.stats.firstClash=r.totalTime;event(r,{type:'clash',damage:0,armor:true,x:clash.x,y:clash.y,nx:clash.nx,ny:clash.ny,speed:clash.bounce/.82,source:'p',target:'e',time:r.totalTime,tick:r.tick});}
 }
 let residual=0;
 for(let k=0;k<(r.system===8?96:48);k++){const list=contacts(r);residual=Math.max(0,...list.map(c=>c.depth));if(residual<=contactTolerance)break;for(const c of list)if(c.depth>contactTolerance)applyContact(c,Math.min(.01,(c.depth-contactTolerance*.5)*.65)/mass(c),true);}
 // Deeply interlocked imported/edited states may have crossed capsule centerlines,
 // where local normals cannot find an escape. Deterministic radial de-interlocking
 // is a positional recovery (not simulated impact); expose its use to callers.
 if(residual>(r.system===8?contactTolerance*2:.002)){
  r.physicsRecoveries=(r.physicsRecoveries||0)+1;
  for(let k=0;k<160;k++){
   const list=contacts(r),pair=list.filter(c=>c.b),wall=list.filter(c=>!c.b);
   if(Math.max(0,...list.map(c=>c.depth))<=contactTolerance*2)break;
   if(pair.some(c=>c.depth>contactTolerance)){const dx=r.e.x-r.p.x,dy=r.e.y-r.p.y,d=Math.hypot(dx,dy)||1,nx=dx/d||(!dy?1:0),ny=dy/d;
    r.p.x-=nx*.002;r.p.y-=ny*.002;r.e.x+=nx*.002;r.e.y+=ny*.002;}
   for(const c of wall)if(c.depth>contactTolerance)applyContact(c,(c.depth-contactTolerance)*.8/mass(c),true);
  }
 }
 r.physicsMaxPenetration=inspectContacts(r).maxPenetration;
 // Residual is observable, never silently claimed to be an exact nonpenetration guarantee.
 r.physicsSolverWarning=r.physicsMaxPenetration>contactTolerance*2;
}
function complete(r,win,reason,draw=false){if(r.system===8){finishBuild(r,win,reason,draw);return;}
 if(r.mode==='duel'){
  const tied=draw||reason==='mutual';r.stats.levels.push({level:1,time:r.elapsed,reason,win:win&&!tied});
  if(reason==='timeout')r.stats.timeouts++;if(win&&!tied)r.stats.kills++;
  r.phase='result';r.choices=[];r.winner=tied?null:win?'p':'e';r.outcome=reason==='mutual'?'mutual':tied?'draw':win?'victory':'defeat';r.reason=reason;return;
 }
r.stats.levels.push({level:r.level,time:r.elapsed,reason,win});if(reason==='timeout')r.stats.timeouts++;if(win){r.stats.kills++;if(r.level<5){r.p.hp=Math.min(r.p.maxHp,r.p.hp+r.p.maxHp*.15);r.phase='upgrade';r.choices=choices(r);return;}}r.phase='result';r.outcome=win?'victory':reason==='mutual'?'mutual':'defeat';r.reason=reason;}
const caps={poison:2,leech:2,speed:2,health:2,power:3};
function choices(r){const list=Object.keys(caps).filter(k=>r.build[k]<caps[k]);for(let i=list.length-1;i>0;i--){const j=Math.floor(random(r)*(i+1));[list[i],list[j]]=[list[j],list[i]];}return list.slice(0,3);}
export function upgradeDescription(id,runOrLevel=0){const level=typeof runOrLevel==='object'?runOrLevel.build[id]:runOrLevel;const titles={poison:'淬毒',leech:'汲取',speed:'疾速',health:'生命强化',power:'锋刃强化'};const descriptions={poison:level?'每层毒伤提升至 3 / 秒':'命中附毒：每层 2 / 秒，最多 3 层',leech:level?'回复实际伤害的 25%，每击上限 4':'回复实际伤害的 15%，每击上限 4',speed:level?'移动速度总提升至 25%':'移动速度提升 15%',health:'最大生命 +15，立即回复 15',power:'武器基础伤害 +1'};return {id,name:titles[id],title:titles[id],description:descriptions[id],text:descriptions[id],level:level+1};}
export function chooseUpgrade(r,id){if(r.phase!=='upgrade'||!r.choices.includes(id)||r.build[id]>=caps[id])return false;r.build[id]++;if(id==='health'){r.p.maxHp+=15;r.p.hp=Math.min(r.p.maxHp,r.p.hp+15);}r.level++;startLevel(r);return true;}
// Adaptive sampling uses the drawn capsules, with <= .0015 relative tip travel
// at the supported capped linear/angular speeds. This is substepping, not exact CCD.
const tipRadius={spike:.1224,staff:.1824,hammer:.1584,ranger:.1008,mage:.1572};
function angular(e){return Number.isFinite(e.angularVelocity)?e.angularVelocity:weapons[e.weapon].omega+(e.spinKick||0);}
function event(r,e){r.events.push({...e,id:++r.eventSeq});}
function capMotion(r){for(const q of [r.p,r.e]){q.angularVelocity=clamp(angular(q),-24,24);q.spinKick=q.angularVelocity-weapons[q.weapon].omega;const max=q.loadout?(q.states?.dash>0?1.6:1.15):.90*(speedFactor(modifiers(r,q).speed)),v=Math.hypot(q.vx,q.vy);if(v>max){q.vx*=max/v;q.vy*=max/v;}}}

function tick(r,dt){
 r.tick++;capMotion(r);
 const travel=(Math.hypot(r.p.vx-r.e.vx,r.p.vy-r.e.vy)+Math.abs(angular(r.p))*extent(r.p)+Math.abs(angular(r.e))*extent(r.e))*dt;
 const count=clamp(Math.ceil(travel/.0015),1,64);
 for(let i=0;i<count&&r.phase==='battle';i++)microstep(r,dt/count);
}
function microstep(r,dt){
 r.elapsed+=dt;r.totalTime+=dt;
 r.events=r.events.filter(e=>r.totalTime-e.time<.65);
 const p=r.p,e=r.e;
 const previous={p:{x:p.x,y:p.y},e:{x:e.x,y:e.y}};
 for(const a of [p,e]){if(r.system===8)updateSkills(r,a,a===p?e:p,dt,random,event);a.fireCooldown=Math.max(0,a.fireCooldown-dt);a.skillCooldown=Math.max(0,a.skillCooldown-dt);a.slowRemaining=Math.max(0,a.slowRemaining-dt);
  if(a.disarmedRemaining>0){a.disarmedRemaining=Math.max(0,a.disarmedRemaining-dt);if(!a.disarmedRemaining){a.durability=a.maxDurability;r.droppedWeapons=r.droppedWeapons.filter(w=>w.owner!==a.id);event(r,{type:'recover',source:a.id,target:a.id,x:a.x,y:a.y,nx:0,ny:0,speed:0,damage:0,time:r.totalTime,tick:r.tick});}}
  a.cooldown=Math.max(0,a.cooldown-dt);a.flash=Math.max(0,a.flash-dt);a.spinDirection=a.spinDirection||Math.sign(weapons[a.weapon].omega)||1;a.angularVelocity=angular(a)+clamp(Math.abs(weapons[a.weapon].omega)*a.spinDirection-angular(a),-8*dt,8*dt);a.angle=(a.angle+angular(a)*dt)%TAU;if(a.armor)a.armor.angle=(a.armor.angle+.42*dt)%TAU;
  // Gentle symmetric pursuit keeps this compact preview active, with elastic wall/body bounces retained.
  const b=a===p?e:p,dx=r.mode==='duel'?previous[b.id].x-previous[a.id].x:b.x-a.x,dy=r.mode==='duel'?previous[b.id].y-previous[a.id].y:b.y-a.y,d=Math.hypot(dx,dy)||1;
  const accel=a.loadout?.35/(a.mass||1):.22;a.vx+=dx/d*accel*dt;a.vy+=dy/d*accel*dt;
  const factor=speedFactor(modifiers(r,a).speed),target=(a.loadout?.48/Math.sqrt(a.mass||1):.45)*factor*(a.slowRemaining>0?.55:1)*(r.mode!=='duel'&&a.weapon==='staff'&&a===e?.88:1),speed=Math.hypot(a.vx,a.vy);
  if(speed<.001){a.vx=r.mode==='duel'?dx/d*target:target;a.vy=r.mode==='duel'?dy/d*target:0;}else{const norm=clamp(speed+(target-speed)*dt*(a.states?.dash>0?.1:1.2),0,.90*factor)/speed;a.vx*=norm;a.vy*=norm;}
  a.x+=a.vx*dt;a.y+=a.vy*dt;
 }
 const attacks=[hit(p,e,modifiers(r,p).power),hit(e,p,modifiers(r,e).power),...advanceProjectiles(r,dt,previous),...autoSkills(r),...(r.system===8?bodyAttacks(r):[])].filter(Boolean);
 for(const h of attacks)if(r.system!==8&&r.mode!=='duel'&&h.source==='e'&&r.level>1)h.damage=Math.max(1,Math.round(h.damage*difficulties[r.difficulty||'design'].enemyDamage));
 // Snapshot damage and healing first; traversal order never cancels a valid same-tick attack.
 const old={p:p.hp,e:e.hp},loss={p:0,e:0},heal={p:0,e:0};
 for(const h of attacks){if(['hit','projectile'].includes(h.type)&&!h.armor&&h.damage>0){h.critical=random(r)<.18;if(h.critical)h.damage=Math.round(h.damage*1.75);}const a=h.source==='p'?p:e,b=h.target==='p'?p:e;const actual=Math.min(Math.max(0,old[h.target]-loss[h.target]),r.system===8?mitigate(b,h.damage):h.damage);loss[h.target]+=actual;if(h.type==='hit')a.cooldown=a.weapon==='hammer'?.22:rules.cooldown;b.flash=.16;wear(r,b,actual);
  const build=modifiers(r,a);heal[a.id]+=r.system===8?actual*.1*levelOf(a,'leech'):leechAmount(actual,build.leech);if(r.system===8){if(actual>0&&levelOf(a,'poison')){b.poison.stacks=1;b.poison.remaining=3;b.poison.level=levelOf(a,'poison');}const reflected=Math.min(Math.max(0,old[a.id]-loss[a.id]),mitigate(a,actual*.12*levelOf(b,'reflect')));if(reflected>0){loss[a.id]+=reflected;event(r,{type:'reflect',source:b.id,target:a.id,damage:reflected,x:a.x,y:a.y,time:r.totalTime,tick:r.tick});}}if(h.source==='p')r.stats.damage+=actual;if(build.poison&&actual>0){b.poison.stacks=Math.min(3,b.poison.stacks+1);b.poison.remaining=3;b.poison.level=build.poison;}if(h.type==='skill'&&actual>0)b.slowRemaining=2;
  r.stats.hits++;if(r.stats.firstHit===null)r.stats.firstHit=r.totalTime;event(r,{...h,damage:actual,time:r.totalTime,tick:r.tick});
 }
 // Poison uses shared whole-second boundaries. Refresh never adds an immediate bonus tick.
 const poisonTick=Math.floor(r.elapsed+1e-9)>Math.floor(r.elapsed-dt+1e-9);
 for(const a of [p,e]){if(a.poison.remaining>0){if(poisonTick){const amount=Math.min(Math.max(0,old[a.id]-loss[a.id]),r.system===8?mitigate(a,a.poison.level):a.poison.stacks*(a.poison.level===2?3:2));loss[a.id]+=amount;event(r,{type:'poison',target:a.id,damage:amount,x:a.x,y:a.y,time:r.totalTime,tick:r.tick});if(a===e)r.stats.damage+=amount;}a.poison.remaining=Math.max(0,a.poison.remaining-dt);if(!a.poison.remaining)a.poison.stacks=0;}}
 for(const a of [p,e])a.hp=old[a.id]-loss[a.id]<=0?0:clamp(old[a.id]-loss[a.id]+heal[a.id],0,a.maxHp);
 solve(r);capMotion(r);
 if(p.hp<=0||e.hp<=0)complete(r,p.hp>0&&e.hp<=0,p.hp<=0&&e.hp<=0?'mutual':'ko');
 else if(r.elapsed>=rules.limit-1e-8){const gap=p.hp/p.maxHp-e.hp/e.maxHp,tied=r.mode==='duel'&&Math.abs(gap)<=1e-9;complete(r,gap>0,'timeout',tied);}
}
export function step(r,dt=FIXED_DT){if(r.phase!=='battle'||r.paused)return r;if(!Number.isFinite(dt)||dt<=0)return r;// Additive migration keeps existing version-1 saves usable and never reuses an id.
 if(r.physicsRevision!==4){r.physicsRevision=4;r.projectiles=[];r.projectileSeq=0;r.droppedWeapons=[];if(r.p.weapon==='hammer'){const bonus=Math.max(0,150+15*r.build.health-r.p.maxHp);r.p.maxHp+=bonus;r.p.hp+=bonus;}r.eventSeq=Math.max(r.eventSeq||0,...r.events.map(e=>e.id||0));r.events=r.events.filter(e=>Number.isInteger(e.id)&&e.id>0);for(const e of [r.p,r.e]){e.maxDurability=rules.durabilityMax;e.durability=rules.durabilityMax;e.disarmedRemaining=0;e.fireCooldown=.4;e.skillCooldown=0;e.slowRemaining=0;e.spinKick=e.spinKick||0;e.angularVelocity=weapons[e.weapon].omega+e.spinKick;}capMotion(r);solve(r,false);capMotion(r);}
 r.accumulator+=Math.min(dt,.25);while(r.accumulator>=FIXED_DT-1e-10&&r.phase==='battle'){r.accumulator=Math.max(0,r.accumulator-FIXED_DT);tick(r,FIXED_DT);}if(r.accumulator<1e-10)r.accumulator=0;return r;}

// Durability is damage absorption wear, never a weapon-contact counter.
function wear(r,b,actual){
 if(actual<=0||b.disarmedRemaining>0)return;
 b.durability=Math.max(0,b.durability-actual*rules.damageWear);
 if(b.durability>0)return;
 b.disarmedRemaining=rules.recoverySeconds;
 r.droppedWeapons.push({id:++r.projectileSeq,owner:b.id,weapon:b.weapon,x:b.x,y:b.y,angle:b.angle,remaining:rules.recoverySeconds});
 event(r,{type:'disarm',source:b.id,target:b.id,x:b.x,y:b.y,nx:0,ny:0,speed:0,damage:0,time:r.totalTime,tick:r.tick});
}
function wallDistance(r,x,y){const arena=arenaFor(r),qx=Math.abs(x-arena.width/2)-(arena.width/2-arena.corner),qy=Math.abs(y-arena.height/2)-(arena.height/2-arena.corner);return Math.hypot(Math.max(qx,0),Math.max(qy,0))+Math.min(Math.max(qx,qy),0)-arena.corner;}
function circleSweep(x,y,dx,dy,radius){
 const c=x*x+y*y-radius*radius;if(c<=0)return 0;
 const a=dx*dx+dy*dy,b=2*(x*dx+y*dy),disc=b*b-4*a*c;
 if(a<1e-18||disc<0)return Infinity;
 const t=(-b-Math.sqrt(disc))/(2*a);return t>=0&&t<=1?t:Infinity;
}
function advanceProjectiles(r,dt,previous){
 const attacks=[];
 for(const a of [r.p,r.e]){
  if(!weapons[a.weapon].ranged||a.disarmedRemaining>0||a.fireCooldown>0||r.projectiles.length>=rules.projectileCap)continue;
  const b=a===r.p?r.e:r.p,dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy)||1,speed=a.weapon==='ranger'?.85:.85;
  a.fireCooldown=(a.weapon==='ranger'?1.4:1.15)/(1+.18*((a.weaponLevel||1)-1));
  for(let shot=0;shot<(a.loadout?a.weaponLevel:1)&&r.projectiles.length<rules.projectileCap;shot++){const spread=(shot-((a.loadout?a.weaponLevel:1)-1)/2)*.12,heading=Math.atan2(dy,dx)+spread;r.projectiles.push({id:++r.projectileSeq,source:a.id,target:b.id,kind:a.weapon==='ranger'?'arrow':'orb',x:a.x,y:a.y,vx:Math.cos(heading)*speed,vy:Math.sin(heading)*speed,radius:a.weapon==='ranger'?.008:.014,remaining:2,damage:weapons[a.weapon].base+modifiers(r,a).power});}
 }
 r.projectiles=r.projectiles.filter(q=>{
  const b=q.target==='p'?r.p:r.e,old=previous[b.id],dx=q.vx*dt,dy=q.vy*dt;
  let body=circleSweep(q.x-old.x,q.y-old.y,dx-(b.x-old.x),dy-(b.y-old.y),b.radius+q.radius);
  let shield=Infinity;if(r.system===8){for(const sh of shieldShapes(b)){const pt={x1:q.x,y1:q.y,x2:q.x+dx,y2:q.y+dy};const close=closest(pt,sh);if(Math.hypot(close.ax-close.bx,close.ay-close.by)<=q.radius+sh.radius){shield=0;break;}}}if(shield<=body&&shield<=1){event(r,{type:'clash',armor:true,source:q.source,target:b.id,damage:0,x:q.x,y:q.y,time:r.totalTime,tick:r.tick});return false;}let wall=Infinity;
  if(wallDistance(r,q.x,q.y)+q.radius>=0)wall=0;
  else if(wallDistance(r,q.x+dx,q.y+dy)+q.radius>=0){let lo=0,hi=1;for(let k=0;k<24;k++){const mid=(lo+hi)/2;if(wallDistance(r,q.x+dx*mid,q.y+dy*mid)+q.radius>=0)hi=mid;else lo=mid;}wall=hi;}
  const lifetime=q.remaining/dt,t=Math.min(body,wall,lifetime,1);
  q.x+=dx*t;q.y+=dy*t;q.remaining-=dt;
  if(body<=wall&&body<=lifetime&&body<=1){
   const bx=old.x+(b.x-old.x)*body,by=old.y+(b.y-old.y)*body,len=Math.hypot(bx-q.x,by-q.y),speed=Math.hypot(q.vx,q.vy)||1,nx=len?(bx-q.x)/len:q.vx/speed,ny=len?(by-q.y)/len:q.vy/speed;
   const armor=armored(b,Math.atan2(-ny,-nx));
   attacks.push({type:'projectile',projectileId:q.id,source:q.source,target:q.target,x:q.x,y:q.y,nx,ny,speed:Math.hypot(q.vx,q.vy),damage:armor?Math.max(1,Math.ceil(q.damage*.25)):q.damage,armor});return false;
  }
  return wall>1&&q.remaining>0;
 });
 for(const w of r.droppedWeapons)w.remaining=Math.max(0,w.remaining-dt);
 return attacks;
}
// Collect both skills before damage is resolved, so lethal spells can trade fairly.
// Duel skills trigger automatically only when an opponent enters their real radius.
function autoSkills(r){
 if(r.mode!=='duel'&&r.system!==8)return [];
 const attacks=[];
 for(const a of [r.p,r.e]){
  if(a.weapon!=='mage'||a.disarmedRemaining>0||a.skillCooldown>1e-9)continue;
  const b=a===r.p?r.e:r.p,dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy);
  const range=rules.skillRadius+.04*((a.weaponLevel||1)-1);if(d>range+b.radius)continue;
  a.skillCooldown=rules.skillCooldown;
  attacks.push({type:'skill',source:a.id,target:b.id,x:a.x,y:a.y,nx:d?dx/d:1,ny:d?dy/d:0,speed:0,damage:rules.skillDamage+modifiers(r,a).power,radius:range});
 }
 return attacks;
}
export function castSkill(r){
 if(r.mode==='duel')return false;

 if(r.phase!=='battle'||r.paused||r.p.weapon!=='mage'||r.p.disarmedRemaining>0||r.p.skillCooldown>1e-9)return false;
 const a=r.p,b=r.e,dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy),nx=d?dx/d:1,ny=d?dy/d:0;
 a.skillCooldown=rules.skillCooldown;
 const actual=d<=rules.skillRadius+b.radius?Math.min(b.hp,rules.skillDamage+r.build.power):0;
 if(actual>0){b.hp-=actual;b.flash=.16;b.slowRemaining=2;wear(r,b,actual);r.stats.damage+=actual;r.stats.hits++;if(r.stats.firstHit===null)r.stats.firstHit=r.totalTime;a.hp=Math.min(a.maxHp,a.hp+leechAmount(actual,r.build.leech));if(r.build.poison){b.poison.stacks=Math.min(3,b.poison.stacks+1);b.poison.remaining=3;b.poison.level=r.build.poison;}}
 event(r,{type:'skill',source:'p',target:'e',x:a.x,y:a.y,nx,ny,speed:0,damage:actual,radius:rules.skillRadius,time:r.totalTime,tick:r.tick});
 if(b.hp<=0)complete(r,true,'ko');
 return true;
}

// V8 uses the same visible capsules for rendering and collision, including shield arcs.
function bodyInertia(a){return inertia[a.weapon]*(a.mass||1)*(a.scaleFactor||1)**2;}
function extent(a){return Math.max(a.radius,tipRadius[a.weapon]*(a.scaleFactor||1)*(1+.13*((a.weaponLevel||1)-1)),a.loadout?(.086*(a.scaleFactor||1)):0);}
export function shieldShapes(a){const n=levelOf(a,'shield');if(!n)return [];const radius=.080*(a.scaleFactor||1),arc=(30+30*n)*Math.PI/180,start=a.angle-arc/2,out=[];for(let i=0;i<n+3;i++){const t=start+arc*i/(n+3),u=start+arc*(i+1)/(n+3);out.push({x1:a.x+Math.cos(t)*radius,y1:a.y+Math.sin(t)*radius,x2:a.x+Math.cos(u)*radius,y2:a.y+Math.sin(u)*radius,radius:.004+.001*n,kind:'shield'});}return out;}
export function impactDamage(a,b,v,base=0){if(v<.08)return 0;const reduced=(a.mass||1)*(b.mass||1)/((a.mass||1)+(b.mass||1)),energy=.5*reduced*v*v;return Math.min(42,Math.max(1,base*.40+energy*30));}
function bodyAttacks(r){const a=r.p,b=r.e,dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy)||1;if(d>a.radius+b.radius+.00002||r.totalTime-(r.lastBodyImpact??-1)<.35)return [];const nx=dx/d,ny=dy/d,v=(a.vx-b.vx)*nx+(a.vy-b.vy)*ny;if(v<.16)return [];r.lastBodyImpact=r.totalTime;const sum=a.mass+b.mass;return [[a,b,a.mass/sum],[b,a,b.mass/sum]].map(([src,dst,ratio])=>({type:'impact',source:src.id,target:dst.id,x:dst.x,y:dst.y,nx,ny,speed:v,damage:impactDamage(src,dst,v)*ratio*1.5}));}
export function createGame(seed=1,mode='duel',tier=1){const r=createDuel(seed);r.system=8;r.mode=mode==='campaign'?'campaign':'duel';r.level=1;r.tier=Math.max(1,Math.min(10,Math.round(tier)));r.inventory=[];r.loot=[];r.initialBudget=100;r.campaignLimit=10;setupBuildRound(r,true);return r;}
function setupBuildRound(r,first=false){const budget=r.mode==='campaign'?100+(r.level-1)*18:100+(r.tier-1)*18;r.targetPower=budget;
 for(const [a,sign] of [[r.p,1],[r.e,-1]]){if(first||a===r.e)a.loadout=rollLoadout(r,budget,random);recalc(a,true);a.x=sign===1?.25:.75;a.y=r.arena.height/2;a.angle=sign===1?0:Math.PI;a.angularVelocity=weapons[a.weapon].omega;a.spinDirection=1;a.vx=sign*.4;a.vy=(random(r)-.5)*.1;}
 r.phase='battle';r.outcome=null;r.winner=null;r.reason=null;r.elapsed=0;r.accumulator=0;r.projectiles=[];r.events=[];r.droppedWeapons=[];r.lastBodyImpact=-1;r.lastClashTime=-1;r.choices=[];
}
function finishBuild(r,win,reason,draw){const tied=draw||reason==='mutual';r.stats.levels.push({level:r.level,time:r.elapsed,reason,win:win&&!tied});r.winner=tied?null:win?'p':'e';r.outcome=tied?'draw':win?'victory':'defeat';r.reason=reason;if(win&&!tied)r.stats.kills++;if(reason==='timeout')r.stats.timeouts++;
 if(r.mode==='campaign'&&win&&!tied){r.phase='loot';r.loot=[r.e.loadout.weapon,...r.e.loadout.gear,...r.e.loadout.skills].filter(Boolean).map(m=>({...m}));}else r.phase='result';}
export function takeLoot(r,index){if(r.phase!=='loot'||!r.loot[index])return false;const item={...r.loot[index]};r.inventory.push(item);r.loot=[];r.phase='workshop';return item;}
export function installModule(r,inventoryIndex,slot,index=0){if(!['workshop','ready'].includes(r.phase))return false;const item=r.inventory[inventoryIndex];if(!item||catalog[item.id].slot!==slot)return false;const arr=slot==='weapon'?[r.p.loadout.weapon]:slot==='gear'?r.p.loadout.gear:r.p.loadout.skills;if(index<0||index>=arr.length)return false;const same=arr.findIndex(m=>m?.id===item.id);if(same>=0&&same!==index)return false;const old=arr[index];if(old?.id===item.id&&old.level>=3)return false;r.inventory.splice(inventoryIndex,1);const next=old?.id===item.id?{id:item.id,level:Math.min(3,Math.max(old.level,item.level)+1)}:{...item};if(old&&old.id!==item.id)r.inventory.push(old);if(slot==='weapon')r.p.loadout.weapon=next;else arr[index]=next;recalc(r.p,true);return true;}
export function unequipModule(r,slot,index){if(!['workshop','ready'].includes(r.phase)||!['gear','skill'].includes(slot))return false;const arr=slot==='gear'?r.p.loadout.gear:r.p.loadout.skills;if(!arr[index])return false;r.inventory.push(arr[index]);arr[index]=null;recalc(r.p,true);return true;}
export function nextRound(r){if(r.phase!=='workshop')return false;if(r.level>=r.campaignLimit){r.phase='result';r.outcome='victory';return true;}r.level++;setupBuildRound(r);return true;}
