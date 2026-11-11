// Browser audio is unlocked only from an explicit user gesture. No remote assets.
export class AudioBus{
 constructor(){this.context=null;this.status='等待点按启动';this.lastHit=-Infinity;}
 async unlock(){try{const C=globalThis.AudioContext||globalThis.webkitAudioContext;if(!C){this.status='此浏览器不支持音频';return false;}if(!this.context)this.context=new C();if(this.context.state!=='running')await this.context.resume();this.status=this.context.state==='running'?'音频已启动':'音频暂停，请点测试声音';return this.context.state==='running';}catch{this.status='音频受限，请点测试声音';return false;}}
 async play(kind='hit',strength=1){if(!await this.unlock())return false;const c=this.context,t=c.currentTime;if(['hit','clash','disarm'].includes(kind)&&t-this.lastHit<.07)return false;if(['hit','clash','disarm'].includes(kind))this.lastHit=t;try{
 // Inharmonic sine partials ring like steel; their combined peak stays below .08.
 if(kind==='clash'||kind==='disarm'){
  const base=kind==='disarm'?540:690,level=Math.max(.35,Math.min(1.25,Number.isFinite(strength)?strength:1));
  for(const [ratio,amp,decay] of [[1,.028,.46],[1.47,.019,.34],[2.09,.011,.25],[2.71,.006,.18]]){
   const osc=c.createOscillator(),gain=c.createGain();osc.type='sine';osc.frequency.setValueAtTime(base*ratio,t);osc.frequency.exponentialRampToValueAtTime(base*ratio*.985,t+decay);gain.gain.setValueAtTime(.0001,t);gain.gain.exponentialRampToValueAtTime(amp*level,t+.003);gain.gain.exponentialRampToValueAtTime(.0001,t+decay);osc.connect(gain);gain.connect(c.destination);osc.start(t);osc.stop(t+decay+.01);
  }return true;
 }
 const duration=kind==='clash'?.07:kind==='hit'?.095:.2,amp=kind==='clash'?.04:kind==='hit'?.075:.09,osc=c.createOscillator(),gain=c.createGain();osc.type=kind==='clash'?'square':kind==='hit'?'triangle':'sine';osc.frequency.setValueAtTime(kind==='clash'?1050:kind==='hit'?180+Math.min(strength,2)*70:kind==='end'?520:660,t);osc.frequency.exponentialRampToValueAtTime(kind==='clash'?650:kind==='hit'?55:kind==='end'?880:440,t+duration);gain.gain.setValueAtTime(amp,t);gain.gain.exponentialRampToValueAtTime(.001,t+duration);osc.connect(gain);gain.connect(c.destination);osc.start(t);osc.stop(t+duration);
 if(kind==='hit'){const n=Math.floor(c.sampleRate*.045),buffer=c.createBuffer(1,n,c.sampleRate),data=buffer.getChannelData(0);let seed=12345;for(let i=0;i<n;i++){seed=(seed*1664525+1013904223)>>>0;data[i]=((seed/4294967296)*2-1)*(1-i/n);}const noise=c.createBufferSource(),ng=c.createGain();noise.buffer=buffer;ng.gain.setValueAtTime(.035,t);noise.connect(ng);ng.connect(c.destination);noise.start(t);noise.stop(t+.05);}
 return true;}catch{this.status='音频输出失败，请重试';return false;}}
}
