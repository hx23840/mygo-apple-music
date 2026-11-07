import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const title = process.env.APPLE_MUSIC_TEST_TITLE;
const artist = process.env.APPLE_MUSIC_TEST_ARTIST;
assert.ok(title && artist, 'Set APPLE_MUSIC_TEST_TITLE and APPLE_MUSIC_TEST_ARTIST to a library song with synchronized lyrics.');

const directory = fileURLToPath(new URL('../', import.meta.url));
const saved = new Map();
const processes = [];
const methods = [];
const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
globalThis.host = {
  platform: 'darwin', language: () => 'en', t: text => text,
  storage: { get: key => clone(saved.get(key)), set: (key, value) => saved.set(key, clone(value)) },
  spawn(executable, args) {
    const child = spawn(directory + executable, args, { stdio: ['pipe', 'pipe', 'inherit'] });
    processes.push(child);
    const lines = [], readers = [];
    let ended = false;
    createInterface({ input: child.stdout }).on('line', line => {
      if (readers.length) readers.shift()(line); else lines.push(line);
    });
    child.on('exit', () => { ended = true; while (readers.length) readers.shift()(null); });
    return {
      write(text) { methods.push(JSON.parse(text).method); child.stdin.write(text); },
      readLine() { if (lines.length) return Promise.resolve(lines.shift()); if (ended) return Promise.resolve(null); return new Promise(resolve => readers.push(resolve)); },
      kill() { child.kill(); }
    };
  }
};

try {
  const api = await import('../index.js?local-live=first');
  const found = await api.search({ query: title, kind: 'tracks', offset: 0 });
  const selected = found.tracks.find(track => track.name === title && track.artists.some(credit => credit.name === artist));
  assert.ok(selected, 'The verification song is not in this library.');
  await api.like({ id: selected.id, on: true });
  const list = api.createPlaylist({ name: 'Isolated verification' });
  await api.addToPlaylist({ id: list.id, trackIds: [selected.id] });
  api.renamePlaylist({ id: list.id, name: 'Renamed isolated verification' });
  const imported = (await api.playlists()).find(item => item.id !== list.id);
  if (imported) {
    const source = await api.playlist({ id: imported.id });
    assert.ok(source.tracks.length > 0);
    const originalCount = source.tracks.length;
    await api.removeFromPlaylist({ id: imported.id, trackIds: [source.tracks[0].id] });
    assert.ok((await api.playlist({ id: imported.id })).tracks.length < originalCount);
    assert.equal((await api.playlists()).find(item => item.id === imported.id).fixed, false);
  }
  const restarted = await import('../index.js?local-live=reloaded');
  assert.equal(restarted.isLiked({ ids: [selected.id] })[selected.id], true);
  const restored = await restarted.playlist({ id: list.id });
  assert.equal(restored.name, 'Renamed isolated verification');
  assert.equal(restored.tracks[0].id, selected.id);
  const lyrics = await restarted.lyrics({ id: selected.id });
  assert.ok(lyrics.lrc?.includes('['), 'No real synchronized lyrics matched.');
  api.deletePlaylist({ id: list.id });
  assert.ok(methods.every(method => ['search', 'playlist', 'playlists', 'tracks'].includes(method)), 'Local management sent a mutation to the native source.');
  console.log('Real source metadata, local favorites, playlist import/edit/reload and LRCLIB timed lyrics passed.');
  console.log('Only isolated in-memory host storage changed; no Apple Music data was written.');
} finally {
  for (const child of processes) child.kill();
}
