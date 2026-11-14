const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const {webcrypto} = require('node:crypto');
const root = require('node:path').resolve(__dirname, '..');
let saved, fail = false;
const commands = [];
const sandbox = {console, structuredClone, crypto:webcrypto, setInterval(){}, document:{hidden:false,addEventListener(){}}, toast(){}, config:{}, modal:{open:true}, refresh:async()=>{}};
sandbox.window = {webkit:{messageHandlers:{dobi:{postMessage(message){
    let value;
    if(message.kind === 'load') value = saved || {ip:'192.168.1.5',name:'Dobi',room:'Bedroom',favorites:[],schedules:[]};
    if(message.kind === 'save') {saved=structuredClone(message.value); value=true;}
    if(message.kind === 'command') {
        commands.push(message);
        value=message.method==='get_prop'?['on','7','1700','65535','180','100','2','0']:['ok'];
    }
    queueMicrotask(()=>sandbox.window.dobiReply({id:message.id,value:structuredClone(value),error:fail&&message.kind==='command'?'offline':null}));
}}}}};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(root+'/Dobi/Web/native.js','utf8'),sandbox);
(async()=>{
    const api=sandbox.nativeAPI;
    assert.equal((await api('settings')).name,'Dobi');
    assert.equal((await api('status')).ct,'1700');
    await assert.rejects(api('settings',{ip:'8.8.8.8',name:'bad',room:''}));
    await api('settings',{ip:'192.168.1.9',name:'Bedroom lamp',room:'Bedroom'});
    await api('favorite',{name:'Warm'});
    assert.equal(saved.favorites[0].state.bright,'7');
    await api('favorite',{delete:saved.favorites[0].id});
    assert.equal(saved.favorites.length,0);
    await assert.rejects(api('schedule',{time:'12:00',action:'on',repeat:'custom',days:[]}));
    await api('schedule',{time:'12:00',action:'on',repeat:'custom',days:['0','2']});
    assert.ok([1,3].includes(new Date(saved.schedules[0].next).getDay()));
    await api('schedule',{delete:saved.schedules[0].id});
    await api('schedule',{time:'12:00',action:'off',repeat:'once',days:[]});
    vm.runInContext('nativeData.schedules[0].next=Date.now()-1000',sandbox);
    await sandbox.tickSchedules();
    assert.equal(saved.schedules[0].enabled,false);
    assert.equal(commands.at(-1).method,'set_power');
    assert.equal(commands.at(-1).params[0],'off');
    await api('schedule',{time:'12:00',action:'on',repeat:'once',days:[]});
    vm.runInContext('nativeData.schedules[1].next=Date.now()-120000',sandbox);
    const count=commands.length; await sandbox.tickSchedules();
    assert.equal(commands.length,count);
    assert.match(saved.schedules[1].error,/Missed/);
    fail=true; await assert.rejects(api('command',{method:'set_rgb',params:[65535,'smooth',300]}),/offline/);
    assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(root+'/Dobi/Web/style.css')).digest('hex'), '4b48d7773bed4382e834dc68b4d281a00bc41225603d74f95b635cb75b4571b4');
    console.log('PASS: status, private IP validation, persistence, favorites, custom schedule days, execution, missed events, network errors, original CSS parity');
})().catch(e=>{console.error(e);process.exit(1)});
