import dgram from 'node:dgram';
import {writeFileSync} from 'node:fs';
const flags = Object.fromEntries(process.argv.slice(2).reduce((a,v,i,all)=>i%2===0?[...a,[v.replace(/^--/,''),all[i+1]]]:a,[]));
const number=(key,fallback)=>flags[key]===undefined?fallback:Number(flags[key]);
const config={port:number('port',27847),targetPort:number('target-port',27846),delay:number('delay',50),jitter:number('jitter',10),loss:number('loss',0.01),duplicate:number('duplicate',0.01),reorder:number('reorder',0.02),seed:number('seed',20260906)};
if(Object.values(config).some(v=>!Number.isFinite(v)) || config.port<1024 || config.port>65535 || config.targetPort<1024 || config.targetPort>65535 || config.delay<0 || config.delay>1000 || config.jitter<0 || config.jitter>1000 || [config.loss,config.duplicate,config.reorder].some(v=>v<0||v>1)) throw Error('Invalid proxy arguments');
let state=config.seed>>>0;
function random(){state^=state<<13;state^=state>>>17;state^=state<<5;return (state>>>0)/4294967296;}
const front=dgram.createSocket('udp4'),back=dgram.createSocket('udp4');
const pending=new Set();
let client=null;
const stats={config,up:{rx:0,tx:0,drop:0,bytes:0},down:{rx:0,tx:0,drop:0,bytes:0}};
function relay(bytes,direction,send){
 const stat=stats[direction];stat.rx++;stat.bytes+=bytes.length;
 if(flags.blackhole===direction || flags.blackhole==='both' || random()<config.loss){stat.drop++;return;}
 const copies=random()<config.duplicate?2:1;
 for(let n=0;n<copies;n++){
  const delay=Math.max(0,config.delay+(random()*2-1)*config.jitter+(random()<config.reorder?config.delay+30:0));
  const timer=setTimeout(()=>{pending.delete(timer);send(bytes);stat.tx++;},delay);pending.add(timer);
 }
}
front.on('message',(bytes,rinfo)=>{
 if(client&&(client.address!==rinfo.address||client.port!==rinfo.port)) return;
 client=rinfo;relay(bytes,'up',b=>back.send(b,config.targetPort,'127.0.0.1'));
});
back.on('message',bytes=>{if(client)relay(bytes,'down',b=>front.send(b,client.port,client.address));});
for(const socket of [front,back])socket.on('error',error=>{console.error(error.message);process.exitCode=1;close();});
let closed=false;
function close(){if(closed)return;closed=true;for(const timer of pending)clearTimeout(timer);front.close();back.close();save();}
function save(){if(flags.report)writeFileSync(flags.report,JSON.stringify(stats,null,2));}
const interval=setInterval(save,1000);interval.unref();
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,close);
back.bind(0,'127.0.0.1',()=>front.bind(config.port,'127.0.0.1',()=>console.log(JSON.stringify({ready:true,...config}))));
