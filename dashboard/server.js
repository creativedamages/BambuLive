'use strict';
const http=require('http'),fs=require('fs'),path=require('path'),mqtt=require('mqtt');
const {spawn,spawnSync}=require('child_process');
const {randomUUID}=require('crypto');
const PORT=Number(process.env.PORT||8080),HOST=process.env.HOST||'0.0.0.0';
const BASE=__dirname, CONFIG=path.join(BASE,'printers.json'), PUBLIC=path.join(BASE,'public');
const FFMPEG=process.env.FFMPEG_PATH||'ffmpeg';
const ffmpegAvailable=spawnSync(FFMPEG,['-version'],{timeout:3000,stdio:'ignore'}).status===0;
const states=new Map(),connections=new Map(),listeners=new Set(),cameras=new Map();
let printers=[];
function readConfig(){try{const x=JSON.parse(fs.readFileSync(CONFIG,'utf8'));return Array.isArray(x)?x:[]}catch{return []}}
function persist(){const tmp=CONFIG+'.tmp';fs.writeFileSync(tmp,JSON.stringify(printers,null,2)+'\n',{mode:0o600});fs.chmodSync(tmp,0o600);fs.renameSync(tmp,CONFIG)}
function sanitize(p){return {id:p.id,name:p.name,host:p.host,serial:p.serial,cameraEnabled:p.cameraEnabled!==false,hasAccessCode:!!p.accessCode}}
function status(){return [...states.values()].map(s=>({...s}))}
function send(res,statusCode,obj){res.writeHead(statusCode,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'});res.end(JSON.stringify(obj))}
function broadcast(){const data=`data: ${JSON.stringify(status())}\n\n`;for(const r of listeners){try{r.write(data)}catch{listeners.delete(r)}}}
function disconnect(id){const c=connections.get(id);if(c){connections.delete(id);c.end(true)}const viewers=cameras.get(id);if(viewers){for(const r of [...viewers])r.end();cameras.delete(id)}states.delete(id)}
function connect(p){const s={id:p.id,name:p.name,online:false,progress:null,remaining:null,nozzle:null,bed:null,chamber:null,job:null,stage:null,ams:null,error:null,cameraEnabled:p.cameraEnabled!==false};states.set(p.id,s);
 if(!p.host||!p.serial||!p.accessCode){s.error='Missing IP, serial, or access code';broadcast();return}
 const c=mqtt.connect(`mqtts://${p.host}:8883`,{username:'bblp',password:p.accessCode,clientId:`x2dmonitor_${p.id.replace(/-/g,'').slice(0,18)}_${process.pid}`,rejectUnauthorized:false,reconnectPeriod:5000,connectTimeout:10000});connections.set(p.id,c);
 c.on('connect',()=>{s.online=true;s.error=null;c.subscribe(`device/${p.serial}/report`,err=>{if(err)s.error=err.message});broadcast()});
 c.on('close',()=>{s.online=false;broadcast()});c.on('error',e=>{s.error=e.message;broadcast()});
 c.on('message',(_topic,msg)=>{try{const d=JSON.parse(msg.toString()).print||{};s.progress=d.mc_percent??s.progress;s.remaining=d.mc_remaining_time??s.remaining;s.nozzle=d.nozzle_temper??s.nozzle;s.bed=d.bed_temper??s.bed;s.chamber=d.chamber_temper??s.chamber;s.job=d.subtask_name??s.job;s.stage=d.gcode_state??s.stage;s.ams=d.ams??s.ams;broadcast()}catch{}});broadcast();
}
printers=readConfig().map((p,i)=>({...p,id:p.id||randomUUID(),name:p.name||`X2D ${i+1}`,cameraEnabled:p.cameraEnabled!==false}));if(printers.length)persist();printers.forEach(connect);
function validate(body,existing){if(!body||typeof body!=='object'||Array.isArray(body))throw Error('Invalid printer data');const name=String(body.name||'').trim(),host=String(body.host||'').trim(),serial=String(body.serial||'').trim(),code=String(body.accessCode||'');
 if(!name||name.length>80)throw Error('Name must be 1–80 characters');if(!/^[a-zA-Z0-9.-]{1,253}$/.test(host))throw Error('Enter a valid LAN IP or hostname');if(!/^[a-zA-Z0-9_-]{5,80}$/.test(serial))throw Error('Enter the printer serial number');if(!existing&&!code)throw Error('LAN access code is required');if(code.length>128)throw Error('Access code is too long');
 return {id:existing?.id||randomUUID(),name,host,serial,accessCode:code||existing?.accessCode,cameraEnabled:body.cameraEnabled!==false};}
function bodyJSON(req){return new Promise((resolve,reject)=>{let b='';req.on('data',x=>{b+=x;if(b.length>8192){reject(Error('Request too large'));req.destroy()}});req.on('end',()=>{try{resolve(JSON.parse(b))}catch{reject(Error('Invalid JSON'))}});req.on('error',reject)})}
function camera(req,res,id){const p=printers.find(x=>x.id===id);if(!p)return send(res,404,{error:'Printer not found'});if(p.cameraEnabled===false)return send(res,409,{error:'Camera disabled in settings'});if(!ffmpegAvailable)return send(res,503,{error:'FFmpeg not found. Install with brew install ffmpeg and restart.'});
 const url=`rtsps://bblp:${encodeURIComponent(p.accessCode)}@${p.host}:322/streaming/live/1`;
 const args=['-hide_banner','-loglevel','error','-nostdin','-rtsp_transport','tcp','-tls_verify','0','-i',url,'-an','-vf','fps=15,scale=960:-2','-q:v','6','-f','mpjpeg','-boundary_tag','frame','pipe:1'];
 const ff=spawn(FFMPEG,args,{stdio:['ignore','pipe','pipe']});let started=false,closed=false,err='';const set=cameras.get(id)||new Set();set.add(res);cameras.set(id,set);
 // FFmpeg errors can contain the full RTSP URL, including the access code.
 function reportFailure(reason){console.warn(`Camera ${p.name}: ${reason}`)}
 function describeFailure(){
  if(/401|unauthorized/i.test(err))return 'Printer rejected the camera credentials';
  if(/connection refused|no route|network is unreachable/i.test(err))return 'Could not reach the camera on port 322';
  if(/unknown option|option .* not found|protocol not found/i.test(err))return 'FFmpeg does not support a required camera option';
  return 'FFmpeg ended before delivering a frame';
 }
 const timeout=setTimeout(()=>{if(!started&&!closed){reportFailure('Timed out waiting for the first frame on port 322');ff.kill('SIGTERM');if(!res.headersSent)send(res,504,{error:'Camera connection timed out. Check LAN Only Liveview and port 322.'})}},15000);
 ff.stdout.once('data',chunk=>{if(closed)return;started=true;res.writeHead(200,{'Content-Type':'multipart/x-mixed-replace; boundary=frame','Cache-Control':'no-store, no-cache','Connection':'keep-alive','X-Content-Type-Options':'nosniff'});res.write(chunk);ff.stdout.pipe(res,{end:false})});
 ff.stderr.on('data',b=>{err=(err+b.toString()).slice(-1200)});
 ff.on('error',e=>{err=e.message;finish()});ff.on('close',finish);
 function finish(){if(closed)return;closed=true;clearTimeout(timeout);set.delete(res);if(!set.size)cameras.delete(id);if(!res.headersSent){const reason=describeFailure();reportFailure(reason);send(res,502,{error:reason})}else res.end()}
 res.on('close',()=>{if(closed)return;closed=true;clearTimeout(timeout);set.delete(res);if(!set.size)cameras.delete(id);ff.kill('SIGTERM')});
}
const mime={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'application/javascript; charset=utf-8','.svg':'image/svg+xml'};
const server=http.createServer(async(req,res)=>{const pathname=decodeURIComponent((req.url||'/').split('?')[0]);
 if(pathname==='/api/status'&&req.method==='GET')return send(res,200,status());
 if(pathname==='/api/settings'&&req.method==='GET')return send(res,200,{printers:printers.map(sanitize),ffmpegAvailable});
 if(pathname==='/api/events'&&req.method==='GET'){res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive'});listeners.add(res);res.write(`data: ${JSON.stringify(status())}\n\n`);req.on('close',()=>listeners.delete(res));return}
 const cameraMatch=pathname.match(/^\/api\/printers\/([a-f0-9-]+)\/camera$/i);if(cameraMatch&&req.method==='GET')return camera(req,res,cameraMatch[1]);
 if(pathname==='/api/printers'&&req.method==='POST'){try{const p=validate(await bodyJSON(req));if(printers.some(x=>x.serial===p.serial))throw Error('Printer serial already exists');printers.push(p);persist();connect(p);return send(res,201,sanitize(p))}catch(e){return send(res,400,{error:e.message})}}
 const match=pathname.match(/^\/api\/printers\/([a-f0-9-]+)$/i);if(match&&(req.method==='PUT'||req.method==='DELETE')){const i=printers.findIndex(x=>x.id===match[1]);if(i<0)return send(res,404,{error:'Printer not found'});if(req.method==='DELETE'){disconnect(match[1]);printers.splice(i,1);persist();broadcast();return send(res,200,{ok:true})}
 try{const p=validate(await bodyJSON(req),printers[i]);if(printers.some((x,j)=>j!==i&&x.serial===p.serial))throw Error('Printer serial already exists');disconnect(p.id);printers[i]=p;persist();connect(p);return send(res,200,sanitize(p))}catch(e){return send(res,400,{error:e.message})}}
 if(req.method!=='GET')return send(res,405,{error:'Method not allowed'});
 const file=path.resolve(PUBLIC,'.'+(pathname==='/'?'/index.html':pathname));if(!file.startsWith(PUBLIC+path.sep))return send(res,403,{error:'Forbidden'});fs.readFile(file,(e,b)=>{if(e)return send(res,404,{error:'Not found'});res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});res.end(b)})
});server.listen(PORT,HOST,()=>console.log(`BambuLive: http://localhost:${PORT} | FFmpeg ${ffmpegAvailable?'found':'NOT FOUND'}`));
