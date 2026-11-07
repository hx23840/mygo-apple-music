import assert from 'node:assert/strict';
import test from 'node:test';

let nonce = 0;
const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const song = n => ({ id: 'am1:' + Buffer.from(JSON.stringify(['library', 'i.' + n])).toString('base64'), name: 'Song ' + n, artists: [{ id: 'a', name: 'Artist' }], album: { id: 'al', name: 'Album' }, duration: 253000 });
const tracks = [song(1), song(2), song(3)];

async function environment(options = {}) {
  const saved = options.saved ?? new Map();
  const requests = [];
  const readers = [];
  const lines = [];
  let closed = false;
  const send = value => {
    const line = JSON.stringify(value);
    if (readers.length) readers.shift()(line); else lines.push(line);
  };
  const child = {
    write(text) {
      const r = JSON.parse(text); requests.push(r);
      Promise.resolve().then(async () => {
        if (options.handle) return options.handle(r);
        if (r.method === 'tracks') return r.params.ids.map(id => tracks.find(t => t.id === id));
        if (r.method === 'playlists') return [{ id: 'apple.1', name: 'Apple original', trackCount: 3 }];
        if (r.method === 'playlist') return { id: 'apple.1', name: 'Apple original', tracks };
        if (r.method === 'browse') return { sections: [{ tracks }] };
        return null;
      }).then(result => send({ id: r.id, result }), error => send({ id: r.id, error: { code: 'unavailable', message: error.message } }));
    },
    readLine() { if (lines.length) return Promise.resolve(lines.shift()); if (closed) return Promise.resolve(null); return new Promise(resolve => readers.push(resolve)); },
    kill() { closed = true; while (readers.length) readers.shift()(null); }
  };
  globalThis.host = { platform: 'darwin', language: () => 'en', t: s => s, spawn: () => child, storage: {
    get: key => clone(saved.get(key)),
    set: (key, value) => { if (options.writeFails?.()) throw Error('disk full'); saved.set(key, clone(value)); }
  } };
  const api = await import(`../plugin/index.js?local=${++nonce}`);
  return { api, saved, requests, close: () => child.kill() };
}

test('favorites persist through reload and need no Apple writes', async () => {
  const first = await environment();
  await first.api.home();
  await first.api.like({ id: tracks[0].id, on: true });
  await first.api.like({ id: tracks[1].id, on: true });
  await first.api.like({ id: tracks[0].id, on: true });
  assert.deepEqual(first.api.liked().tracks.map(t => t.id), [tracks[1].id, tracks[0].id]);
  assert.deepEqual(first.requests.map(r => r.method), ['browse']);
  first.close();
  const second = await environment({ saved: first.saved });
  assert.equal(second.api.isLiked({ ids: [tracks[0].id] })[tracks[0].id], true);
  await second.api.like({ id: tracks[0].id, on: false });
  assert.equal(second.api.liked().tracks.length, 1);
  assert.equal(second.requests.length, 0);
  second.close();
});

test('local playlist CRUD, duplicate add and order survive reload', async () => {
  const first = await environment();
  const list = first.api.createPlaylist({ name: '  Evening  ' });
  assert.equal(list.name, 'Evening'); assert.equal(list.fixed, false);
  await first.api.addToPlaylist({ id: list.id, trackIds: tracks.map(t => t.id) });
  await first.api.addToPlaylist({ id: list.id, trackIds: [tracks[0].id] });
  await first.api.movePlaylistTrack({ id: list.id, from: 2, to: 0 });
  await first.api.removeFromPlaylist({ id: list.id, trackIds: [tracks[1].id] });
  first.api.renamePlaylist({ id: list.id, name: 'Night' });
  assert.deepEqual((await first.api.playlist({ id: list.id })).tracks.map(t => t.id), [tracks[2].id, tracks[0].id]);
  assert.ok(first.requests.every(r => r.method === 'tracks'));
  first.close();
  const second = await environment({ saved: first.saved });
  const restored = await second.api.playlist({ id: list.id });
  assert.equal(restored.name, 'Night'); assert.equal(restored.tracks.length, 2);
  assert.equal(second.requests.length, 0);
  second.api.deletePlaylist({ id: list.id });
  await assert.rejects(second.api.playlist({ id: list.id }), /no longer exists/);
  second.close();
});

test('Apple imports hydrate once, preserve local edits and do not resurrect after deletion', async () => {
  const env = await environment();
  const [list] = await env.api.playlists();
  assert.equal(list.fixed, false); assert.equal(list.trackCount, 3);
  assert.deepEqual(env.requests.map(r => r.method), ['playlists']);
  await env.api.playlist({ id: list.id });
  env.api.renamePlaylist({ id: list.id, name: 'My copy' });
  await env.api.removeFromPlaylist({ id: list.id, trackIds: [tracks[0].id] });
  assert.equal((await env.api.playlists())[0].name, 'My copy');
  assert.equal((await env.api.playlist({ id: list.id })).tracks.length, 2);
  assert.equal(env.requests.filter(r => r.method === 'playlist').length, 1);
  env.api.deletePlaylist({ id: list.id });
  assert.deepEqual(await env.api.playlists(), []);
  assert.ok(env.requests.every(r => ['playlists', 'playlist'].includes(r.method)));
  env.close();
});

test('hydration preserves concurrent rename and refuses to recreate deleted copies', async () => {
  let release;
  const env = await environment({ handle: r => r.method === 'playlists' ? [{ id: 'apple.1', name: 'Original' }] : new Promise(resolve => { release = () => resolve({ tracks }); }) });
  const [list] = await env.api.playlists();
  const loading = env.api.playlist({ id: list.id });
  await new Promise(resolve => setImmediate(resolve));
  env.api.renamePlaylist({ id: list.id, name: 'Renamed' });
  release();
  assert.equal((await loading).name, 'Renamed');
  env.close();
  const other = await environment({ handle: r => r.method === 'playlists' ? [{ id: 'apple.1', name: 'Original' }] : new Promise(resolve => { release = () => resolve({ tracks }); }) });
  const [copy] = await other.api.playlists();
  const pending = other.api.playlist({ id: copy.id });
  await new Promise(resolve => setImmediate(resolve));
  other.api.deletePlaylist({ id: copy.id }); release();
  await assert.rejects(pending, /no longer exists/);
  assert.deepEqual(await other.api.playlists(), []);
  other.close();
});

test('late favorite metadata cannot reverse a newer unlike', async () => {
  let release;
  const env = await environment({ handle: () => new Promise(resolve => { release = () => resolve([tracks[0]]); }) });
  const liking = env.api.like({ id: tracks[0].id, on: true });
  await new Promise(resolve => setImmediate(resolve));
  await env.api.like({ id: tracks[0].id, on: false }); release(); await liking;
  assert.deepEqual(env.api.liked().tracks, []);
  env.close();
});

test('failed storage writes leave the previous local collection intact', async () => {
  let fail = false;
  const env = await environment({ writeFails: () => fail });
  const list = env.api.createPlaylist({ name: 'Original' });
  fail = true;
  assert.throws(() => env.api.renamePlaylist({ id: list.id, name: 'Lost' }), /disk full/);
  assert.equal((await env.api.playlist({ id: list.id })).name, 'Original');
  env.close();
});

test('invalid persisted collections fail without replacing data', async () => {
  const broken = { version: 99, tracks: {} };
  const saved = new Map([['localLibrary.v1', broken]]);
  const env = await environment({ saved });
  assert.throws(() => env.api.liked(), /preserved/);
  assert.deepEqual(saved.get('localLibrary.v1'), broken);
  env.close();
});

test('source failure leaves existing local playlists usable', async () => {
  const env = await environment({ handle: () => { throw Error('offline'); } });
  const local = env.api.createPlaylist({ name: 'Offline' });
  assert.equal((await env.api.playlists())[0].id, local.id);
  assert.deepEqual((await env.api.playlist({ id: local.id })).tracks, []);
  env.close();
});
