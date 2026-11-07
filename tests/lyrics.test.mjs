import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const manifest = JSON.parse(await readFile(new URL('../plugin/plugin.json', import.meta.url), 'utf8'));
const pluginSource = await readFile(new URL('../plugin/index.js', import.meta.url), 'utf8');
const source = pluginSource.slice(pluginSource.indexOf('function createLyricsProvider'), pluginSource.indexOf('const lyricProvider ='));
const track = { id: 'track1', name: 'Test Song', artists: [{ name: 'Test Artist' }], album: { name: 'Test Album' }, duration: 253000 };
const record = { trackName: track.name, artistName: 'Test Artist', albumName: 'Test Album', duration: 253, syncedLyrics: '[00:01.00]Test line\n[00:04.00]Another line', instrumental: false };
const clean = value => JSON.parse(JSON.stringify(value));
const response = (data = record, status = 200, headers = {}) => new Response(typeof data === 'string' ? data : JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json', ...headers } });

function environment(fetcher, options = {}) {
  const store = options.store ?? new Map();
  const calls = [];
  let offset = 0;
  class Clock extends Date { static now() { return Date.now() + offset; } }
  const context = vm.createContext({
    Date: Clock, Math, Map, Promise, JSON, Number, Error, encodeURIComponent, AbortController,
    setTimeout: options.setTimeout ?? setTimeout, clearTimeout,
    host: { storage: {
      get: key => clean(store.get(key) ?? null),
      set: (key, value) => { if (options.writeFails) throw Error('disk full'); store.set(key, clean(value)); }
    } },
    fetch: async (...args) => { calls.push(args); return fetcher(...args); }
  });
  const create = vm.runInContext(source + '\ncreateLyricsProvider', context);
  return { store, calls, create: (resolve = async () => track) => create(resolve), advance: ms => { offset += ms; } };
}

test('returns timed lyrics and sends metadata with milliseconds converted to seconds', async () => {
  const env = environment(async () => response());
  const lyrics = env.create();
  assert.deepEqual(clean(await lyrics({ id: track.id })), { lrc: record.syncedLyrics });
  const [url, options] = env.calls[0];
  const query = new URL(url).searchParams;
  assert.equal(query.get('duration'), '253');
  assert.equal(query.get('track_name'), track.name);
  assert.equal(query.get('artist_name'), 'Test Artist');
  assert.equal(query.get('album_name'), 'Test Album');
  assert.equal(options.headers['User-Agent'].split(' ')[0], `MyGoAppleMusic/${manifest.version}`);
});

test('persists matches across provider reload and expires them after 30 days', async () => {
  const env = environment(async () => response());
  await env.create()({ id: track.id });
  assert.deepEqual(clean(await env.create()({ id: track.id })), { lrc: record.syncedLyrics });
  assert.equal(env.calls.length, 1);
  env.advance(31 * 86400000);
  await env.create()({ id: track.id });
  assert.equal(env.calls.length, 2);
});

test('concurrent requests for the same metadata share a request', async () => {
  let release;
  const env = environment(() => new Promise(resolve => { release = () => resolve(response()); }));
  const lyrics = env.create();
  const first = lyrics({ id: 'one' });
  const second = lyrics({ id: 'two' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(env.calls.length, 1);
  release();
  assert.deepEqual(clean(await first), clean(await second));
});

test('rejects mismatched title artist album and duration', async () => {
  for (const update of [{ trackName: 'Different Song' }, { artistName: 'Different Artist' }, { albumName: 'Live Album' }, { duration: 256 }]) {
    const env = environment(async () => response({ ...record, ...update }));
    assert.deepEqual(clean(await env.create()({ id: track.id })), {});
  }
  const env = environment(async () => response({ ...record, duration: 251 }));
  assert.deepEqual(clean(await env.create()({ id: track.id })), { lrc: record.syncedLyrics });
});

test('does not invent timing for plain lyrics or instrumental music', async () => {
  for (const update of [{ syncedLyrics: null, plainLyrics: 'Unscheduled words' }, { instrumental: true }, { syncedLyrics: 'No timestamps' }]) {
    const env = environment(async () => response({ ...record, ...update }));
    assert.deepEqual(clean(await env.create()({ id: track.id })), {});
    assert.equal(env.store.get('lyrics.lrclib.v1').entries[0].lrc, null);
  }
});

test('404 is briefly cached and transient server or network errors are not', async () => {
  const missing = environment(async () => response({}, 404));
  const lyrics = missing.create();
  await lyrics({ id: track.id });
  await lyrics({ id: track.id });
  assert.equal(missing.calls.length, 1);
  missing.advance(7 * 3600000);
  await lyrics({ id: track.id });
  assert.equal(missing.calls.length, 2);
  for (const fetcher of [async () => response({}, 500), async () => { throw Error('offline'); }]) {
    const env = environment(fetcher);
    const get = env.create();
    assert.deepEqual(clean(await get({ id: track.id })), {});
    assert.deepEqual(clean(await get({ id: track.id })), {});
    assert.equal(env.calls.length, 2);
    assert.equal(env.store.get('lyrics.lrclib.v1')?.entries?.length ?? 0, 0);
  }
});

test('honors rate-limit and overload cooldown through reload without sleeping for it', async () => {
  for (const status of [429, 503]) {
    const env = environment(async () => response({}, status, { 'Retry-After': '60' }));
    assert.deepEqual(clean(await env.create()({ id: track.id })), {});
    assert.deepEqual(clean(await env.create()({ id: track.id })), {});
    assert.equal(env.calls.length, 1);
    const saved = env.store.get('lyrics.lrclib.v1');
    assert.ok(saved.retryAt >= Date.now() + 59000);
    assert.equal(saved.entries.length, 0);
    env.advance(70000);
    await env.create()({ id: track.id });
    assert.equal(env.calls.length, 2);
  }
});

test('malformed responses and oversized bodies fail softly without persisting misses', async () => {
  for (const fetcher of [
    async () => response('{bad json'),
    async () => response('html', 200, { 'Content-Type': 'text/html' }),
    async () => response(record, 200, { 'Content-Length': '2000000' }),
    async () => response('x'.repeat(512001))
  ]) {
    const env = environment(fetcher);
    assert.deepEqual(clean(await env.create()({ id: track.id })), {});
    assert.equal(env.store.size, 0);
  }
});

test('storage failure does not hide fetched lyrics', async () => {
  const env = environment(async () => response(), { writeFails: true });
  assert.deepEqual(clean(await env.create()({ id: track.id })), { lrc: record.syncedLyrics });
});

test('missing or invalid metadata avoids network access', async () => {
  const env = environment(async () => { throw Error('must not fetch'); });
  for (const item of [null, { ...track, duration: 0 }, { ...track, duration: 3600001 }, { ...track, artists: [] }, { ...track, name: '' }]) {
    assert.deepEqual(clean(await env.create(async () => item)({ id: track.id })), {});
  }
  assert.deepEqual(clean(await env.create(async () => { throw Error('source unavailable'); })({ id: track.id })), {});
  assert.equal(env.calls.length, 0);
});

test('fetch timeouts abort and return no lyrics', async () => {
  let signal;
  const env = environment((url, options) => {
    signal = options.signal;
    return new Promise((_, reject) => signal.addEventListener('abort', () => reject(Error('aborted'))));
  }, { setTimeout: (fn, ms) => setTimeout(fn, ms >= 9000 ? 5 : ms) });
  assert.deepEqual(clean(await env.create()({ id: track.id })), {});
  assert.equal(signal.aborted, true);
});

test('distinct requests are sequential with a gap', async () => {
  const times = [];
  let active = 0;
  const env = environment(async () => {
    active++;
    assert.equal(active, 1);
    times.push(Date.now());
    await new Promise(resolve => setTimeout(resolve, 10));
    active--;
    return response();
  });
  const lyrics = env.create(async id => ({ ...track, name: id }));
  await Promise.all([lyrics({ id: 'A' }), lyrics({ id: 'B' })]);
  assert.equal(times.length, 2);
  assert.ok(times[1] - times[0] >= 190);
});
