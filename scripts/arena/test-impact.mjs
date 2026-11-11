import assert from 'node:assert/strict';
import {createDuel,step} from '../../Sources/WristArenaFeature/Resources/core.js';
import {ParticleFX} from '../../Sources/WristArenaFeature/Resources/effects.js';
let crit=0,normal=0,reverse=0;
for(let seed=1;seed<=25;seed++){const r=createDuel(seed);for(let i=0;i<5400&&r.phase==='battle';i++){step(r,1/120);for(const q of [r.p,r.e])if(q.spinDirection<0)reverse++;for(const ev of r.events.filter(e=>e.id>(r.testCursor||0))){if(ev.critical)crit++;else if(ev.damage>0)normal++;r.testCursor=ev.id;}assert(Number.isFinite(r.p.x)&&Number.isFinite(r.e.x));}}
assert(crit>0&&normal>0&&reverse>0);
const fx=new ParticleFX();fx.consume({seed:1,events:[{id:1,type:'hit',damage:4,target:'e',x:.5,y:.4}]});assert(fx.timeScale()<1);fx.update(.3);assert.equal(fx.timeScale(),1);
console.log({crit,normal,reverse});
