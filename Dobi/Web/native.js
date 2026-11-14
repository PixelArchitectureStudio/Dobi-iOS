// Native iPhone adapter for the unchanged Dobi Controller v1.1 screens.
let nativeSequence = 0, nativeData, scheduleTickBusy = false;
const nativePending = new Map();
window.dobiReply = ({id, value, error}) => {
    const pending = nativePending.get(id);
    if (!pending) return;
    nativePending.delete(id);
    error ? pending.reject(Error(error)) : pending.resolve(value);
};
function nativeCall(kind, body = {}) {
    return new Promise((resolve, reject) => {
        const id = ++nativeSequence;
        nativePending.set(id, {resolve, reject});
        try { window.webkit.messageHandlers.dobi.postMessage({id, kind, ...body}); }
        catch (error) { nativePending.delete(id); reject(error); }
    });
}
async function persistNative() { await nativeCall('save', {value: nativeData}); }
async function lampCommand(method, params) {
    return nativeCall('command', {ip: nativeData.ip, method, params});
}
async function lampStatus() {
    const keys = ['power','bright','ct','rgb','hue','sat','color_mode','flowing'];
    const values = await lampCommand('get_prop', keys);
    if (!Array.isArray(values) || values.length !== keys.length) throw Error('Incomplete lamp status');
    return Object.fromEntries(keys.map((key, i) => [key, String(values[i])]));
}
function nextOccurrence(item, after = new Date()) {
    const [hour, minute] = item.time.split(':').map(Number);
    let due = new Date(after);
    due.setHours(hour, minute, 0, 0);
    if (due <= after) due.setDate(due.getDate() + 1);
    if (item.repeat === 'custom') {
        if (!item.days.length) throw Error('Choose at least one day');
        while (!item.days.includes((due.getDay() + 6) % 7)) due.setDate(due.getDate() + 1);
    }
    return due.getTime();
}
async function nativeAPI(path, body) {
    if (!nativeData) nativeData = await nativeCall('load');
    if (path === 'settings') {
        if (!body) return structuredClone(nativeData);
        const octets = String(body.ip).split('.');
        const n = octets.map(Number);
        if (octets.length !== 4 || octets.some(v => !/^\d{1,3}$/.test(v)) || n.some(v => v > 255) ||
            !(n[0] === 10 || (n[0] === 192 && n[1] === 168) || (n[0] === 172 && n[1] >= 16 && n[1] <= 31))) throw Error('Enter a local IPv4 address');
        Object.assign(nativeData, {ip: n.join('.'), name: String(body.name).slice(0,60), room: String(body.room).slice(0,60)});
    } else if (path === 'status') return lampStatus();
    else if (path === 'command') return {result: await lampCommand(body.method, body.params)};
    else if (path === 'favorite') {
        if (body.delete) nativeData.favorites = nativeData.favorites.filter(f => f.id !== body.delete);
        else nativeData.favorites.push({id: crypto.randomUUID(), name: String(body.name).slice(0,60), state: await lampStatus()});
    } else if (path === 'schedule') {
        if (body.delete) nativeData.schedules = nativeData.schedules.filter(s => s.id !== body.delete);
        else {
            if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(body.time) || !['on','off'].includes(body.action) || !['once','daily','custom'].includes(body.repeat)) throw Error('Invalid schedule');
            const item = {...body, id: crypto.randomUUID(), days: (body.days || []).map(Number).filter(n => Number.isInteger(n) && n >= 0 && n <= 6), enabled: true, error: ''};
            item.next = nextOccurrence(item);
            nativeData.schedules.push(item);
        }
    } else throw Error('Unknown operation');
    await persistNative();
    return {ok: true};
}
async function tickSchedules() {
    if (!nativeData || scheduleTickBusy || document.hidden) return;
    scheduleTickBusy = true;
    try {
        const now = Date.now(); let changed = false;
        for (const item of nativeData.schedules) {
            if (!item.enabled || item.next > now) continue;
            const late = now - item.next;
            item.enabled = item.repeat !== 'once';
            if (item.enabled) item.next = nextOccurrence(item, new Date(now));
            item.error = 'Interrupted before confirmation';
            await persistNative(); // Never repeat an uncertain command after a restart.
            try {
                if (late > 90000) throw Error('Missed: app was not active at the scheduled time');
                await lampCommand('set_power', [item.action, 'smooth', 500]);
                item.error = '';
            } catch (error) { item.error = error.message; }
            changed = true;
        }
        if (changed) {
            await persistNative();
            config = structuredClone(nativeData);
            if (!modal.open) await refresh();
        }
    } finally { scheduleTickBusy = false; }
}
setInterval(() => tickSchedules().catch(error => toast(error.message)), 2000);
document.addEventListener('visibilitychange', () => {
    if (!document.hidden && nativeData) { tickSchedules().catch(error => toast(error.message)); refresh(); }
});
