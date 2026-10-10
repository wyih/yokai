// Codex's native Chrome adapter. Reuses the user's signed-in tab, without cookies.
// The capture is consumed by weread_export.py --capture; no auth data is saved.
import { mkdir, writeFile, rename } from 'node:fs/promises';
import { dirname } from 'node:path';

const methods = ['Network.requestWillBeSent', 'Network.responseReceived', 'Network.loadingFinished'];
const selector = '.readerCatalog_list_item_title_text';
const parts = { txt: ['t_0', 't_1'], epub: ['e_0', 'e_1', 'e_3'] };
const decodeId = code => {
    const width = parseInt(code.slice(7, 9), 16);
    const uid = parseInt(code.slice(9, 9 + width), 16);
    if (!Number.isInteger(uid) || uid < 1) throw Error('Invalid chapter identifier');
    return uid;
};

export async function createCollector(tab, path, { cursor, resume } = {}) {
    const cdp = await tab.capabilities.get('cdp');
    await cdp.send('Network.enable');
    let sequence = cursor ?? (await cdp.readEvents({ methods })).cursor;
    let capture = resume ?? { chapters: {}, catalog: [], position: {} };
    let originalUrl = await tab.url();
    let takePosition = !capture.position.chapterUid;
    let next = 1;
    const requests = new Map(), responses = new Map(), finished = new Set();
    const ready = uid => parts[capture.bookInfo?.format]?.every(p => capture.chapters[uid]?.[p]);

    async function save() {
        await mkdir(dirname(path), { recursive: true });
        await writeFile(path + '.tmp', JSON.stringify(capture), { mode: 0o600 });
        await rename(path + '.tmp', path);
    }
    async function drain(timeoutMs = 100) {
        let events;
        do {
            events = await cdp.readEvents({ afterSequence: sequence, methods, limit: 1000, timeoutMs });
            sequence = events.cursor;
            if (events.truncated) throw Error('Browser event buffer expired; restart this capture');
            for (const e of events.events) {
                if (e.method === 'Network.requestWillBeSent') {
                    const r = e.params.request;
                    const endpoint = new URL(r.url).pathname;
                    if (endpoint.startsWith('/web/book/chapter/') && r.postData) {
                        // Read only the chapter identifier, never signatures or session fields.
                        requests.set(e.params.requestId, decodeId(JSON.parse(r.postData).c));
                    } else if (endpoint === '/web/book/read' && takePosition && r.postData) {
                        const p = JSON.parse(r.postData);
                        capture.position = { chapterUid: decodeId(p.c), chapterOffset: p.co, fraction: p.pr / 100 };
                    }
                } else if (e.method === 'Network.responseReceived') {
                    const r = e.params.response, endpoint = new URL(r.url).pathname;
                    if (r.status === 200 && (endpoint === '/web/book/readInfo' || endpoint.startsWith('/web/book/chapter/')))
                        responses.set(e.params.requestId, endpoint);
                } else finished.add(e.params.requestId);
            }
        } while (events.hasMore);
        for (const [id, endpoint] of responses) {
            if (!finished.has(id)) continue;
            const p = await cdp.send('Network.getResponseBody', { requestId: id });
            const body = p.base64Encoded ? Buffer.from(p.body, 'base64').toString('utf8') : p.body;
            if (endpoint === '/web/book/readInfo') {
                const info = JSON.parse(body).bookInfo;
                if (!info.bookId.startsWith('CB_') || !parts[info.format]) throw Error('Select an uploaded TXT or EPUB');
                if (capture.bookInfo && capture.bookInfo.version !== info.version) throw Error('Book version changed');
                capture.bookInfo = info;
            } else if (endpoint.endsWith('/e_2')) capture.cssShard = body;
            else {
                const uid = requests.get(id), segment = endpoint.split('/').pop();
                if (uid && Object.values(parts).flat().includes(segment))
                    (capture.chapters[uid] ??= {})[segment] = body;
            }
            responses.delete(id);
        }
    }
    async function wait(predicate, timeoutMs = 30000) {
        if (predicate()) return;
        const end = Date.now() + timeoutMs;
        while (Date.now() < end) {
            await drain(500);
            if (predicate()) return;
        }
        throw Error('Timed out loading chapter content: ' + JSON.stringify({
            chapters: Object.fromEntries(Object.entries(capture.chapters).map(([u, p]) => [u, Object.keys(p)])),
            requests: [...requests.values()], pending: [...responses.values()], finished: finished.size,
        }));
    }
    await wait(() => capture.bookInfo && capture.position.chapterUid);
    takePosition = false;
    await cdp.send('Network.setBlockedURLs', { urls: ['https://weread.qq.com/web/book/read'] });
    async function openCatalog() {
        const visible = await tab.playwright.locator(selector).first().isVisible();
        if (!visible) {
            await tab.playwright.getByRole('button', { name: '目录', exact: true }).click();
            await tab.playwright.domSnapshot();
        }
    }
    await openCatalog();
    const catalog = await tab.playwright.evaluate(s => [...document.querySelectorAll(s)].map((e, index) => ({
        index, title: e.textContent.trim(), level: Number((e.closest('.readerCatalog_list_item')?.className.match(/level_?(\d+)/) || [])[1] || 1),
    })), selector);
    capture.catalog = catalog;
    capture.readerUrl = originalUrl;
    const simple = capture.bookInfo.format === 'txt' && catalog.length === capture.bookInfo.lastChapterIdx + 1 && catalog[0].title === '扉页';
    await save();

    return {
        async nextBatch(count = 15) {
            const end = Math.min(catalog.length, next + count);
            for (; next < end; next++) {
                const item = catalog[next];
                if (item.title === '扉页') continue;
                const expected = simple ? next : null;
                if (expected && ready(expected)) { item.chapterUid = expected; continue; }
                await openCatalog();
                await tab.playwright.locator(selector).nth(next).click();
                await tab.playwright.locator('.readerCatalog_list_item_selected ' + selector)
                    .filter({ hasText: item.title }).waitFor({ state: 'attached', timeoutMs: 10000 });
                const state = await tab.playwright.evaluate(() => ({
                    selected: document.querySelector('.readerCatalog_list_item_selected .readerCatalog_list_item_title_text')?.textContent.trim(),
                    url: location.href,
                }));
                if (state.selected !== item.title) throw Error('Chapter selection did not change');
                const uid = expected ?? decodeId(new URL(state.url).pathname.split('k').pop());
                await wait(() => ready(uid));
                item.chapterUid = uid;
                await save();
            }
            await save();
            const total = capture.bookInfo.lastChapterIdx;
            return { next, rows: catalog.length, complete: next >= catalog.length,
                captured: Array.from({ length: total }, (_, i) => i + 1).filter(ready).length, total };
        },
        async finish() {
            await wait(() => Array.from({ length: capture.bookInfo.lastChapterIdx }, (_, i) => i + 1).every(ready));
            capture.position.chapter = catalog.find(c => c.chapterUid === capture.position.chapterUid)?.title || '';
            await save();
            await tab.goto(originalUrl);
            await tab.playwright.domSnapshot();
            await cdp.send('Network.setBlockedURLs', { urls: [] });
            await cdp.send('Network.disable');
            return { path, chapters: Object.keys(capture.chapters).length, position: capture.position };
        },
        async release() {
            await cdp.send('Network.setBlockedURLs', { urls: [] });
            await cdp.send('Network.disable');
        },
    };
}
