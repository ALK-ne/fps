// Protocol 2 normative field order and design-only vector encoder.
// Run: node docs/implementation/wire-schema.mjs
// Does not import product code, touch product data, or assert acceptance PASS.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const S = (fields) => ({fields});
const A = (type,max,min=0) => ({array:type,max,min});
const B = (max,min=0) => ({bytes:max,min});
const E = (type,values) => ({enum:type,values});
const e8=(...v)=>E('u8',v);
const vec=S({x:'f32',y:'f32',z:'f32'});
const weapon=S({id:'u32',kind:e8(0,1,2,3),magazine:'u16'});
const inventory=S({revision:'u32',activeSlot:E('i8',[-1,0,1]),weapon0:weapon,weapon1:weapon,
 reserveRifle:'u16',reserveShotgun:'u16',reservePistol:'u16',healthSmall:'u8',healthFull:'u8',armorSmall:'u8',armorFull:'u8',frag:'u8',incendiary:'u8',selectedHeal:e8(1,2,3,4),selectedGrenade:e8(1,2)});
const player=S({slot:e8(0,1),position:vec,velocity:vec,yaw:'f32',pitch:'f32',hp:'i32',armor:'i32',armorMax:'i32',flags:'u8',action:e8(0,1,2,3,4,5,6,7),actionEndTick:'u64',actionKind:'u8',ackInputSeq:'u64',slideRemaining:'u16',vaultStart:vec,vaultEnd:vec,vaultProgress:'u16',recoilPitch:'f32',recoilYaw:'f32',inventory});
const input=S({seq:'u64',sampleTick:'u64',axisX:'i16',axisY:'i16',yaw:'f32',pitch:'f32',held:'u16'});
const projectile=S({id:'u32',owner:e8(0,1),kind:e8(1,2,3),position:vec,velocity:vec,spawnTick:'u64',expiryTick:'u64',shotId:'u64',pelletIndex:'u8'});
const grenade=S({id:'u32',owner:e8(0,1),kind:e8(1,2),position:vec,velocity:vec,spawnTick:'u64',expiryTick:'u64'});
const flame=S({id:'u32',owner:e8(0,1),spawnTick:'u64',expiryTick:'u64',nextDamageTick:'u64',cells:A(vec,81,1)});
const pickup=S({id:'u32',revision:'u32',kind:e8(1,2,3,4),subtype:'u8',amount:'u16',position:vec,weapon});
export const eventTypes={
 1:S({shotId:'u64',weaponId:'u32',owner:e8(0,1),recoilPitch:'f32',recoilYaw:'f32',projectiles:A(projectile,8,1)}),
 2:S({id:'u32',reason:e8(1,2,3),point:vec,normal:vec}),
 3:S({target:e8(0,1),amountMilli:'i32',hitKind:e8(0,1,2,3),sourceId:'u64'}),
 4:S({slot:e8(0,1),inventory}),5:pickup,6:grenade,7:flame,8:S({slot:e8(0,1)}),
 9:S({kind:e8(2,3),id:'u32',reason:e8(1,2,3,4)})
};
const event={tagged:eventTypes};
// TimerStatus: unknown=0, running=1, expired=2, uncertain=3.
// ResumeBlock: none=0, windowClosed=1, policyPending=2, historyConflict=3, storeError=4, legacySchema=5, uncertain=6.
// ResultStatus: unresolved=0, forfeit=1, aborted=2, tenWins=3.
// Evidence bits: continuous=1, peerBootChanged=2, gracefulLeave=4, agreedStall=8,
// deadlineElapsed=16, durableTerminal=32, authenticatedNotice=64. Other bits invalid.
const timer=e8(0,1,2,3),block=e8(0,1,2,3,4,5,6),result=e8(0,1,2,3);
const resumeFields={oldEpoch:'u32',boot:'b16',oldHostBoot:'b16',oldGuestBoot:'b16',seq:'u64',hash:'b32',observedRound:'u32',remainingMs:'u32',continuous:e8(0,1),timerStatus:timer,resumeBlock:block,offender:E('i8',[-1,0,1]),evidence:'u16'};
export const messages={
 1:S({player:'b16',boot:'b16',nonce:'b32',rules:'b32',map:'b32'}),
 2:S({hostPlayer:'b16',hostBoot:'b16',hostNonce:'b32',guestNonce:'b32',epoch:'u32'}),
 3:S({hostNonce:'b32',guestNonce:'b32'}),
 4:S({epoch:'u32',boundGuest:'b16',hostLatestSeq:'u64',hash:'b32'}),
 5:S({sentMonoUs:'u64',echoMonoUs:'u64',lastServerTick:'u64'}),6:S({ready:e8(0,1)}),
 10:S({round:'u32',samples:A(input,3,1)}),11:S({round:'u32',serverTick:'u64',player0:player,player1:player}),
 12:S({round:'u32',tick:'u64',requiredEventSeq:'u64',entities:A(S({kind:e8(1,2),id:'u32',position:vec,velocity:vec}),24,1)}),
 20:S({round:'u32',actionId:'u64',inputSeq:'u64',sampleTick:'u64',actionType:e8(0,1,2,3,4,5,6,7,8,9,10,11),targetId:'u32',expectedRevision:'u32',argument:'i32'}),
 21:S({round:'u32',actionId:'u64',resultCode:E('u16',[0,1,2,3,4,5,6,7,8,9,10,11,12]),inventoryRevision:'u32',acceptedTick:'u64',completeTick:'u64'}),
 22:S({round:'u32',firstEventSeq:'u64',serverTick:'u64',events:A(event,64,1)}),
 23:S({round:'u32',revision:'u32',phase:e8(0,1,2,3,4,5,6,7,8,9,10),firstSlot:e8(0,1),spawn0:E('i8',[-1,0,1,2,3,4,5]),spawn1:E('i8',[-1,0,1,2,3,4,5]),deadlineTick:'u64',serverTick:'u64'}),
 24:S({round:'u32',baselineId:'u64',tick:'u64',cutEventSeq:'u64',player0:player,player1:player,pickups:A(pickup,32),projectiles:A(projectile,128),grenades:A(grenade,4),flames:A(flame,8),hash:'b32'}),
 25:S({round:'u32',baselineId:'u64',hash:'b32'}),
 26:S({round:'u32',requestId:'u64',knownEventSeq:'u64',lastTick:'u64',reason:E('u16',[1,2,3,4,5])}),
 30:S({record:B(8192,128)}),
 31:S({ackKind:e8(0,1),seq:'u64',hash:'b32',epoch:'u32',checkpointHash:'b32'}),
 32:S(resumeFields),33:S({checkpointSeq:'u64',seq:'u64',hash:'b32'}),
 34:S({done:e8(0,1),seq:'u64',hash:'b32',record:B(8192)}),
 35:S({recoveryId:'b16',oldEpoch:'u32',newEpoch:'u32',interruptedRound:'u32',disposition:e8(0,1,2,3),offender:E('i8',[-1,0,1]),baseSeq:'u64',baseHash:'b32',remainingMs:'u32'}),
 36:S({recoveryId:'b16',baseHash:'b32',remainingMs:'u32'}),
 37:S({seq:'u64',hash:'b32',checkpointHash:'b32',stateBytes:B(16384,32)}),
 39:S({seq:'u64',hash:'b32',checkpointHash:'b32'}),40:S({ready:e8(0,1)}),
 41:S({reason:e8(2),oldEpoch:'u32'}),42:S({invite:{utf8:2048,min:1}}),
 43:S({requestId:'b16',oldEpoch:'u32',seq:'u64',hash:'b32'}),
 44:S({requestId:'b16',noticeId:'b16',oldEpoch:'u32',observerBoot:'b16',seq:'u64',hash:'b32',observedRound:'u32',timerStatus:timer,resumeBlock:block,resultStatus:result,winner:E('i8',[-1,0,1]),evidence:'u16',offender:E('i8',[-1,0,1]),observationHash:'b32'}),
 45:S({noticeId:'b16',oldEpoch:'u32'}),
 50:S({round:'u32',requestId:'u64',revision:'u32',spawn:e8(0,1,2,3,4,5)})
};
const widths={u8:1,i8:1,u16:2,i16:2,u32:4,i32:4,u64:8,f32:4,b16:16,b32:32};
function example(t) {
 if(typeof t==='string') return t[0]==='b'?'00'.repeat(widths[t]):t==='u64'?'0':0;
 if(t.fields)return Object.fromEntries(Object.entries(t.fields).map(([k,v])=>[k,example(v)]));
 if(t.enum)return t.values[0];
 if(t.array)return Array.from({length:t.min},()=>example(t.array));
 if(t.bytes!==undefined)return '00'.repeat(t.min);
 if(t.utf8)return 'x'.repeat(t.min);
 if(t.tagged)return {type:1,payload:example(t.tagged[1])};
 throw Error('schema');
}
function encode(t,v){
 if(typeof t==='string'){
  if(t[0]==='b')return Buffer.from(v,'hex');
  const b=Buffer.alloc(widths[t]);
  ({u8:()=>b.writeUInt8(v),i8:()=>b.writeInt8(v),u16:()=>b.writeUInt16LE(v),i16:()=>b.writeInt16LE(v),u32:()=>b.writeUInt32LE(v),i32:()=>b.writeInt32LE(v),u64:()=>b.writeBigUInt64LE(BigInt(v)),f32:()=>b.writeFloatLE(v)})[t]();return b;
 }
 if(t.fields)return Buffer.concat(Object.entries(t.fields).map(([k,s])=>encode(s,v[k])));
 if(t.enum)return encode(t.enum,v);
 if(t.array)return Buffer.concat([encode('u16',v.length),...v.map(x=>encode(t.array,x))]);
 if(t.bytes!==undefined||t.utf8){const b=Buffer.from(v,t.utf8?'utf8':'hex');return Buffer.concat([encode('u16',b.length),b]);}
 if(t.tagged){const b=encode(t.tagged[v.type],v.payload);return Buffer.concat([encode('u8',v.type),encode('u16',b.length),b]);}
}
function maxSize(t){
 if(typeof t==='string')return widths[t];
 if(t.fields)return Object.values(t.fields).reduce((s,v)=>s+maxSize(v),0);
 if(t.enum)return maxSize(t.enum);
 if(t.array)return 2+t.max*maxSize(t.array);
 if(t.bytes!==undefined)return 2+t.bytes;
 if(t.utf8)return 2+t.utf8;
 return 3+Math.max(...Object.values(t.tagged).map(maxSize));
}
const vectors=Object.entries(messages).map(([type,schema])=>{
 const value=example(schema);
 if(value.player1)value.player1.slot=1;
 const bytes=encode(schema,value);
 return {type:Number(type),scope:'payload structural decoding only; semantic context and opaque content are validated separately',schema,value,length:bytes.length,maxPayloadBytes:Math.min(32768,maxSize(schema)),normalHex:bytes.toString('hex'),truncatedHex:bytes.subarray(0,-1).toString('hex'),trailingByteHex:Buffer.concat([bytes,Buffer.from([0])]).toString('hex'),expected:{normal:'decode fields exactly',truncated:'TRUNCATED, no mutation',trailing:'TRAILING_BYTES, no mutation'}};
});
const events=Object.entries(eventTypes).map(([type,schema])=>{const value=example(schema);return {type:Number(type),schema,value,normalHex:encode(schema,value).toString('hex')};});
if(vectors.find(v=>v.type===11).length!==278)throw Error('snapshot size');
writeFileSync(fileURLToPath(new URL('wire-vectors.json',import.meta.url)),JSON.stringify({protocol:2,endian:'little',generatedBy:'design-only encoder; not a product test result',vectors,events},null,2)+'\n');
console.log(JSON.stringify({messageTypes:vectors.map(v=>v.type),snapshotBytes:278,eventTypes:events.length}));
