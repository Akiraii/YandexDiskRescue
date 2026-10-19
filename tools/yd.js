// Yandex unlimited photo rescue (based on KenGuru66/yandex-disk-rescue tools/yd.js, MIT).
// list: read-only; move: modifies locations in the user's Yandex Disk after GUI approval.
// All HTTP requests execute inside an existing disk.yandex.ru tab using that origin's cookies.
'use strict';
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');
const [action, stateDir, rawLimit, rawBatch] = process.argv.slice(2);
const endpoint = process.env.YD_CDP;
if (!endpoint || !/^http:\/\/127\.0\.0\.1:\d{4,5}$/.test(endpoint)) throw Error('YD_CDP должен быть локальным адресом Chrome');
if (!stateDir) throw Error('Не указан каталог состояния');
const listFile = path.join(stateDir, 'unlim_list.json');
const movedFile = path.join(stateDir, 'moved.jsonl');
const limit = Math.min(Math.max(parseInt(rawLimit || '1', 10), 1), 2147483647);
const batch = Math.min(Math.max(parseInt(rawBatch || '40', 10), 1), 40);
const dest = '/disk/Безлимит/'; // fixed destination: one account, one safe rescue folder
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = msg => console.log(new Date().toISOString(), msg);
class Stop extends Error {}
async function api(page, uid) {
  let sk;
  return async (method, params) => {
    if (!sk) sk = await page.evaluate(() => (document.documentElement.innerHTML.match(/"sk":"([^"]+)"/) || [])[1]);
    if (!sk) throw new Stop('Не найден ключ веб-сессии, обновите вкладку Яндекс Диска');
    for (let attempt = 0; attempt < 5; ++attempt) {
      const request = { sk, connection_id: `${uid}${Date.now()}`, apiMethod: method };
      if (params !== undefined) request.requestParams = params;
      const r = await page.evaluate(async ({ method, request }) => {
        const response = await fetch(`/models-v2?m=${encodeURIComponent(method)}`, {
          method: 'POST', credentials: 'include',
          headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
          body: JSON.stringify(request)
        });
        return { status: response.status, text: await response.text() };
      }, { method, request });
      let obj; try {obj = JSON.parse(r.text);} catch {obj = null;}
      if (obj?.type === 'captcha') throw new Stop('Капча: пройдите её в Chrome');
      if (obj?.error?.code === 'CKEY') {sk = null; continue;}
      if (r.status === 429 || r.status >= 500) {await sleep(10000 * (attempt + 1)); continue;}
      if (r.status !== 200 || !obj) throw new Stop(`${method}: HTTP ${r.status}`);
      return obj;
    }
    throw new Stop(`${method}: исчерпаны попытки`);
  };
}
async function list(call) {
  if (fs.existsSync(movedFile) && fs.readFileSync(movedFile, 'utf8').trim())
    throw new Stop('Нельзя перезаписать список после начатого переноса: сначала сохраните архив');
  const init = await call('intapi/photo-init-snapshot');
  const snap = await call('intapi/photo-get-snapshot', { id: init.photoslice_id, locale: 'ru' });
  if (!Array.isArray(snap.items)) throw new Stop('Нет кластеров фотографии');
  const clusters = snap.items.filter(c => c.albums && c.albums.photounlim > 0);
  const expected = clusters.reduce((sum, c) => sum + c.albums.photounlim, 0);
  const items = new Set();
  for (let i = 0; i < clusters.length; i += 50) {
    const req = {};
    clusters.slice(i, i + 50).forEach(c => { req[c.id] = { range: [0, c.size - 1] }; });
    const r = await call('intapi/photo-get-clusters-with-resources', {
      photosliceId: init.photoslice_id, clusters: req, hideScreenshots: false
    });
    for (const c of r?.clusters?.fetched || []) for (const item of c.items || [])
      if (typeof item.id === 'string' && item.id.startsWith('/photounlim/')) items.add(item.id);
    log(`Список: кластеров ${Math.min(i + 50, clusters.length)}/${clusters.length}, фото ${items.size}`);
    await sleep(350);
  }
  const result = { at: new Date().toISOString(), expected, items: [...items].sort() };
  if (expected === 0 || result.items.length !== expected)
    throw new Stop(`Список неполный: найдено ${result.items.length}, ожидалось ${expected}. Исходные данные не менялись`);
  const temp = listFile + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(result)); fs.renameSync(temp, listFile);
  log(`Список завершён: ${result.items.length}`);
}
async function move(call) {
  if (!fs.existsSync(listFile)) throw new Stop('Нет списка фотографий');
  const snapshot = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  const items = snapshot.items;
  if (!Array.isArray(items) || !items.length || snapshot.expected !== items.length)
    throw new Stop('Список неполный; изменение облака заблокировано');
  const done = new Set(fs.existsSync(movedFile) ? fs.readFileSync(movedFile, 'utf8').split('\n')
    .filter(Boolean).map(line => {try{return JSON.parse(line);}catch{return null;}})
    .filter(x => x && x.ok === true).map(x => x.src) : []);
  const todo = items.filter(x => !done.has(x)).slice(0, limit);
  let success = 0, failed = 0;
  for (let i = 0; i < todo.length; i += batch) {
    const operations = todo.slice(i, i + batch).map(src => {
      if (!src.startsWith('/photounlim/') || src.slice(12).split('/').some(x => !x || x === '.' || x === '..'))
        throw new Stop('Некорректный путь фотографии');
      return { src, dst: dest + src.slice('/photounlim/'.length), force: 0 };
    });
    const started = await call('mpfs/bulk-async-move', { operations });
    if (!Array.isArray(started)) throw new Stop('Неизвестный формат ответа на перенос');
    const pending = new Map();
    for (let k = 0; k < operations.length; k++) {
      if (started[k]?.oid) pending.set(started[k].oid, operations[k].src);
      else {failed++; fs.appendFileSync(movedFile, JSON.stringify({ src: operations[k].src, ok: false }) + '\n');}
    }
    for (let elapsed = 0; pending.size && elapsed < 300000; elapsed += 2000) {
      await sleep(2000);
      const status = await call('mpfs/bulk-operation-status', { oids: [...pending.keys()] });
      for (const [oid, src] of [...pending]) {
        const s = status[oid];
        if (!s || ['WAITING', 'EXECUTING'].includes(s.status)) continue;
        const ok = s.status === 'DONE';
        fs.appendFileSync(movedFile, JSON.stringify({ src, ok }) + '\n');
        ok ? success++ : failed++;
        pending.delete(oid);
      }
    }
    if (pending.size) throw new Stop('Истекло ожидание операции. Повтор после проверки состояния в облаке');
    log(`Партия ${Math.floor(i / batch) + 1}: успешно ${success}, с ошибками ${failed}`);
    if (failed > 20 && failed > success * 0.05) throw new Stop('Слишком много ошибок, прекращаю перенос');
    await sleep(2000);
  }
  log(`Готово: перенесено ${success}, ошибок ${failed}`);
  if (failed) process.exitCode = 2;
}
(async () => {
  if (!['list', 'move'].includes(action)) throw new Stop('Неизвестное действие');
  fs.mkdirSync(stateDir, { recursive: true });
  const browser = await chromium.connectOverCDP(endpoint);
  const page = browser.contexts()[0]?.pages().find(p => /^https:\/\/disk\.yandex\.ru\//.test(p.url()));
  if (!page) throw new Stop('Откройте disk.yandex.ru в отдельном окне Chrome');
  const uid = await page.evaluate(() => (document.documentElement.innerHTML.match(/"uid":"?(\d+)/) || [])[1]);
  if (!uid || uid !== process.env.YD_EXPECTED_UID)
    throw new Stop('В Chrome открыт другой аккаунт Яндекса либо личность не подтверждена. Перенос заблокирован');
  const call = await api(page, uid);
  if (action === 'list') await list(call); else await move(call);
})().catch(e => {console.error('СТОП:', e.message);process.exitCode = 1;}).finally(() => {
  // Never close the user's browser or remove its cookies without explicit consent.
  process.exit(process.exitCode || 0);
});
