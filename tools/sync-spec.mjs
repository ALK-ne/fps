import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const out=root+'game/data/'; mkdirSync(out,{recursive:true});
const manifest={schema:1,files:{}};
for(const [src,dest] of [['spec.json','game_config.json'],['arena.json','arena.json'],['design-validation.json','spawn_graph.json']]){
 const bytes=readFileSync(root+'docs/implementation/'+src);
 writeFileSync(out+dest,bytes); manifest.files[dest]=createHash('sha256').update(bytes).digest('hex');
}
const keys={forward:87,back:83,left:65,right:68,jump:32,sprint:4194325,crouch:4194326,reload:82,interact:69,weapon_1:49,weapon_2:50,melee:86,heal:52,heal_1:53,heal_2:54,heal_3:55,heal_4:56,grenade:71,pause:4194305};
writeFileSync(out+'input_defaults.json',JSON.stringify(keys,null,2)+'\n');
manifest.files['input_defaults.json']=createHash('sha256').update(readFileSync(out+'input_defaults.json')).digest('hex');
writeFileSync(out+'manifest.json',JSON.stringify(manifest,null,2)+'\n');
// Keep wire compatibility separate from gameplay hashes. Preserve explicit field order.
const wire=JSON.parse(readFileSync(root+'docs/implementation/wire-vectors.json','utf8'));
function ordered(t){
 if(typeof t==='string')return t;
 if(t.fields)return {fields:Object.entries(t.fields).map(([name,type])=>[name,ordered(type)])};
 if(t.array)return {...t,array:ordered(t.array)};
 if(t.tagged)return {tagged:Object.fromEntries(Object.entries(t.tagged).map(([id,s])=>[id,ordered(s)]))};
 return t;
}
writeFileSync(out+'wire_schema.json',JSON.stringify({protocol:wire.protocol,messages:Object.fromEntries(wire.vectors.map(v=>[v.type,ordered(v.schema)])),events:Object.fromEntries(wire.events.map(v=>[v.type,ordered(v.schema)]))})+'\n');
console.log('Generated game configuration and hash manifest.');
