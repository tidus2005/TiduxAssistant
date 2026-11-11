// Keep module scope while bundling the original offline V0.8 game for WKWebView.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
const root=path.resolve(import.meta.dirname,'../../Sources/WristArenaFeature/Resources');
const files=['builds.js','core.js','effects.js','audio.js','app.js'];
let js='const modules={};\n';
for(const file of files){
 const source=fs.readFileSync(path.join(root,file),'utf8');
 const names=[...source.matchAll(/export (?:const|let|class|function) (\w+)/g)].map(m=>m[1]);
 const body=source.replace(/^import \{([^}]+)\} from '\.\/(\w+\.js)';/gm,(_,names,dependency)=>`const {${names}}=modules['${dependency}'];`).replace(/export /g,'');
 js+=`modules['${file}']=(()=>{\n${body}\n${file==='app.js'?'window.__codexPause=()=>{pause();save();sound.context?.suspend();};':''}\nreturn {${names.join(',')}};})();\n`;
}
new vm.Script(js); // Fail generation on lexical collisions or invalid packaging.
let html=fs.readFileSync(path.join(root,'index.html'),'utf8');
html=html.replace('<script type="module" src="app.js"></script>',`<script>(()=>{${js}})();</script>`);
fs.mkdirSync(path.join(root,'Web'),{recursive:true});
fs.writeFileSync(path.join(root,'Web/native.html'),html);
fs.copyFileSync(path.join(root,'style.css'),path.join(root,'Web/style.css'));
console.log('Offline arena bundle validated');
