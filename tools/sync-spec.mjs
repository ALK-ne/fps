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
console.log('Generated game configuration and hash manifest.');
