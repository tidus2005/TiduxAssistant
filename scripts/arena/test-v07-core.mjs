import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {createDuel,createRun,step,castSkill,chooseUpgrade,inspectContacts,weapons,rules,duelArena,duelPalettes,contactTolerance,FIXED_DT} from '../../Sources/WristArenaFeature/Resources/core.js';
let passed=0;
const test=(name,fn)=>{fn();passed++;console.log('PASS',name);};
const copy=x=>JSON.parse(JSON.stringify(x));
const hpFor=w=>w==='hammer'?150:100;
function finish(r){let steps=0;while(r.phase==='battle'&&steps++<5500){step(r);assert(!r.physicsSolverWarning,`solver warning seed ${r.seed}`);}assert.equal(r.phase,'result');return r;}
function quietMageDuel(){const r=createDuel(8);for(const [a,x] of [[r.p,.34],[r.e,.66]])Object.assign(a,{weapon:'mage',hp:100,maxHp:100,armor:null,x,y:r.arena.height/2,vx:0,vy:0,angle:Math.PI/2,angularVelocity:0,cooldown:100,fireCooldown:100,skillCooldown:0});return r;}

test('duel configuration is deterministic, portrait and independently owned',()=>{
 const a=createDuel(20261016),b=createDuel(20261016);assert.deepEqual(a,b);assert.equal(a.mode,'duel');assert.deepEqual(a.arena,duelArena);assert.equal(a.arena.height/a.arena.width,242/198);assert.equal(a.config.seed,a.seed);assert.equal(a.config.autoSkill,true);
 for(const p of [a.p,a.e]){assert.equal(p.maxHp,hpFor(p.weapon));assert.deepEqual(p.modifiers,{poison:0,leech:0,speed:0,health:0,power:0});assert(duelPalettes.some(q=>q.id===p.palette.id&&q.color===p.color));assert.equal(a.config.fighters[p.id].color,p.color);}
 a.arena.height=2;a.p.palette.color='#ffffff';assert.deepEqual(b.arena,duelArena);assert.notEqual(a.p.palette.color,b.p.palette.color);assert.deepEqual(createDuel(20261016),b);assert.equal(createDuel(-1).seed,4294967295);
});
test('campaign and arena-less legacy saves keep their original short arena',()=>{
 const a=createRun(92,'staff'),b=copy(a);delete b.arena;delete b.mode;
 for(let i=0;i<300;i++){step(a);step(b);}const normalized=copy(a);delete normalized.arena;delete normalized.mode;assert.deepEqual(normalized,b);assert.equal(rules.height,.72);assert.equal(a.arena.height,.72);
});
test('portrait boundaries do not contain a phantom landscape wall',()=>{
 const r=quietMageDuel();for(const a of [r.p,r.e]){a.skillCooldown=100;a.y=.96;a.vy=.4;a.vx=0;}
 for(let i=0;i<24;i++)step(r);assert(r.p.y>.96);assert(r.e.y>.96);assert(inspectContacts(r).maxPenetration<=contactTolerance*2);
 // A shot in the lower half reaches its target before the actual portrait boundary.
 const p=quietMageDuel();for(const a of [p.p,p.e]){a.y=1.05;a.skillCooldown=100;}p.projectiles.push({id:++p.projectileSeq,source:'p',target:'e',kind:'arrow',x:.55,y:1.05,vx:30,vy:0,radius:.008,remaining:1,damage:9});step(p);assert.equal(p.e.hp,91);assert.equal(p.projectiles.length,0);
});
test('both mage auto-skills damage, slow and enter the identical cooldown',()=>{
 const r=quietMageDuel();assert.equal(castSkill(r),false);step(r);assert.equal(r.p.hp,88);assert.equal(r.e.hp,88);assert.equal(r.p.skillCooldown,r.e.skillCooldown);assert(r.p.skillCooldown>5.99);assert.equal(r.p.slowRemaining,r.e.slowRemaining);assert(r.p.slowRemaining>1.99);assert.deepEqual(new Set(r.events.filter(x=>x.type==='skill').map(x=>x.source)),new Set(['p','e']));
});
test('same-tick lethal auto-skills settle as a mutual draw without first-seat survival',()=>{
 const r=quietMageDuel();r.p.hp=r.e.hp=10;step(r);assert.equal(r.p.hp,0);assert.equal(r.e.hp,0);assert.equal(r.phase,'result');assert.equal(r.outcome,'mutual');assert.equal(r.winner,null);assert.equal(r.stats.levels.length,1);assert.equal(r.events.filter(x=>x.type==='skill').length,2);
});
test('duel power, leech, poison and speed modifiers follow both combatants equally',()=>{
 const r=quietMageDuel();for(const a of [r.p,r.e]){a.hp=50;a.modifiers={poison:2,leech:2,speed:2,health:0,power:3};}step(r);assert.equal(r.p.hp,38.75);assert.equal(r.e.hp,38.75);assert.equal(r.p.poison.level,2);assert.equal(r.e.poison.level,2);assert.equal(r.p.poison.stacks,1);assert.equal(r.e.poison.stacks,1);assert.equal(Math.hypot(r.p.vx,r.p.vy),Math.hypot(r.e.vx,r.e.vy));
});
test('single duel has no campaign upgrades; exact timeout tie is a draw',()=>{
 const a=quietMageDuel();a.e.hp=0;step(a);assert.equal(a.phase,'result');assert.equal(a.outcome,'victory');assert.equal(a.winner,'p');assert.equal(a.level,1);assert.equal(chooseUpgrade(a,'power'),false);assert.deepEqual(a.choices,[]);
 const b=quietMageDuel();b.p.skillCooldown=b.e.skillCooldown=100;b.elapsed=rules.limit-FIXED_DT;step(b);assert.equal(b.outcome,'draw');assert.equal(b.winner,null);assert.equal(b.reason,'timeout');
});
test('both seats retain class stats and identical pursuit without enemy-only staff penalty',()=>{
 for(const weapon of Object.keys(weapons)){
  const r=quietMageDuel();for(const a of [r.p,r.e])Object.assign(a,{weapon,angularVelocity:weapons[weapon].omega,skillCooldown:100});r.p.x=.24;r.e.x=.76;r.p.vx=.45;r.e.vx=-.45;step(r);assert(Math.abs(Math.hypot(r.p.vx,r.p.vy)-Math.hypot(r.e.vx,r.e.vy))<1e-12,weapon);
 }
});
test('fixed-step replay, save/load and simultaneous different arena simulations agree',()=>{
 for(const seed of [1,8,22,45,73,99]){const a=createDuel(seed),b=createDuel(seed),campaign=createRun(seed);for(let i=0;i<240;i++){step(a);step(campaign);}for(let i=0;i<60;i++)step(b,1/30);assert.deepEqual(a,b);const resumed=copy(a);for(let i=0;i<120;i++){step(a);step(resumed);}assert.deepEqual(a,resumed);assert.deepEqual(a.config,createDuel(seed).config);}
});
test('all classes resolve full portrait rounded-corner contacts',()=>{
 for(const w of Object.keys(weapons))for(const other of Object.keys(weapons)){
  const r=createDuel(6);r.p.weapon=w;r.e.weapon=other;
  for(const a of [r.p,r.e])Object.assign(a,{hp:10000,maxHp:10000,cooldown:100,fireCooldown:100,skillCooldown:100,angularVelocity:24});
  Object.assign(r.p,{x:.10,y:r.arena.height-.10,vx:-.9,vy:.9});Object.assign(r.e,{x:.22,y:r.arena.height-.16,vx:-.9,vy:.9});
  for(let i=0;i<60;i++){step(r);assert(inspectContacts(r).maxPenetration<=contactTolerance*2);assert(!r.physicsSolverWarning);}
 }
});
const summary={runs:300,seedRange:[1,300],arena:duelArena,playerWins:0,opponentWins:0,mutual:0,tiedTimeouts:0,timeouts:0,firstHitUnder5:0,meanSeconds:0,maxPenetration:0,recoveries:0,solverWarnings:0,serializedReplays:0,bySeat:{p:{classes:{},colors:{},shield:0},e:{classes:{},colors:{},shield:0}},classPairs:{},shieldPairs:{},sameColor:0,fixtures:[]};
test('300 random single duels complete with independent diversity and bounded physics',()=>{
 for(let seed=1;seed<=300;seed++){
  const r=createDuel(seed),config=copy(r.config);for(const a of [r.p,r.e]){const seat=summary.bySeat[a.id];seat.classes[a.weapon]=(seat.classes[a.weapon]||0)+1;seat.colors[a.palette.id]=(seat.colors[a.palette.id]||0)+1;seat.shield+=!!a.armor;}
  const key=r.p.weapon+'-'+r.e.weapon;summary.classPairs[key]=(summary.classPairs[key]||0)+1;const shields=Number(!!r.p.armor)+'-'+Number(!!r.e.armor);summary.shieldPairs[shields]=(summary.shieldPairs[shields]||0)+1;summary.sameColor+=r.p.color===r.e.color;
  let count=0,replay=null;while(r.phase==='battle'&&count++<5500){step(r);if(seed%25===0&&count===120)replay=copy(r);else if(replay)step(replay);summary.maxPenetration=Math.max(summary.maxPenetration,r.physicsMaxPenetration||0);summary.solverWarnings+=!!r.physicsSolverWarning;assert(!r.physicsSolverWarning,`seed ${seed}`);for(const a of [r.p,r.e]){assert(Number.isFinite(a.hp+a.x+a.y+a.vx+a.vy));assert(a.hp>=0&&a.hp<=a.maxHp);assert(a.x>=a.radius-contactTolerance*2&&a.x<=r.arena.width-a.radius+contactTolerance*2);assert(a.y>=a.radius-contactTolerance*2&&a.y<=r.arena.height-a.radius+contactTolerance*2);}}
  assert.equal(r.phase,'result',`seed ${seed}`);assert.equal(r.stats.levels.length,1);assert.deepEqual(r.config,config);assert.deepEqual(r.choices,[]);if(replay){assert.deepEqual(r,replay);summary.serializedReplays++;}
  summary.playerWins+=r.winner==='p';summary.opponentWins+=r.winner==='e';summary.mutual+=r.outcome==='mutual';summary.tiedTimeouts+=r.outcome==='draw';summary.timeouts+=r.reason==='timeout';summary.firstHitUnder5+=r.stats.firstHit!==null&&r.stats.firstHit<=5;summary.meanSeconds+=r.elapsed;summary.recoveries+=r.physicsRecoveries||0;
  summary.fixtures.push({seed,classes:[r.p.weapon,r.e.weapon],palettes:[r.p.palette.id,r.e.palette.id],shields:[!!r.p.armor,!!r.e.armor],winner:r.winner,outcome:r.outcome,reason:r.reason,seconds:r.elapsed,hp:[r.p.hp,r.e.hp],firstHit:r.stats.firstHit,finalStateSha256:crypto.createHash('sha256').update(JSON.stringify(r)).digest('hex')});
  if(seed%50===0)console.log('duel seed',seed);
 }
 summary.meanSeconds/=summary.runs;
 for(const seat of Object.values(summary.bySeat)){assert.equal(Object.keys(seat.classes).length,5);assert.equal(Object.keys(seat.colors).length,6);assert(seat.shield>60&&seat.shield<150);for(const n of Object.values(seat.classes))assert(n>30&&n<95);}
 assert.equal(Object.keys(summary.classPairs).length,25);assert.equal(Object.keys(summary.shieldPairs).length,4);assert(summary.sameColor>20&&summary.sameColor<90);assert.equal(summary.serializedReplays,12);assert(summary.maxPenetration<=contactTolerance*2);
 // A diagnostic, not a false guarantee that unequal random matchups are perfectly balanced.
 summary.seatWinRate=summary.playerWins/(summary.playerWins+summary.opponentWins);summary.seatFairnessWithin40To60Percent=summary.seatWinRate>=.4&&summary.seatWinRate<=.6;
});
summary.byClass={};
for(const fixture of summary.fixtures)for(const [index,id] of ['p','e'].entries()){
 const weapon=fixture.classes[index],row=summary.byClass[weapon]??={appearances:0,wins:0,draws:0};row.appearances++;row.wins+=fixture.winner===id;row.draws+=fixture.winner===null;
}
const evidence={version:'v07',coreSha256:crypto.createHash('sha256').update(fs.readFileSync(new URL('../../Sources/WristArenaFeature/Resources/core.js',import.meta.url))).digest('hex'),passed,summary};
fs.writeFileSync(new URL('./physics-v07-duel-balance.json',import.meta.url),JSON.stringify(evidence,null,2)+'\n');
console.log(JSON.stringify({...evidence,summary:{...summary,fixtures:undefined}},null,2));
