import assert from "node:assert/strict";
import test from "node:test";

let nonce = 0;
function fakeProcess(onWrite) {
  const lines = [];
  const readers = [];
  let ended = false;
  let killed = false;
  const process = {
    writes: [],
    get killed() { return killed; },
    write(text) {
      const request = JSON.parse(text);
      process.writes.push(request);
      onWrite?.(request, process);
    },
    readLine() {
      if (lines.length) return Promise.resolve(lines.shift());
      if (ended) return Promise.resolve(null);
      return new Promise(resolve => readers.push(resolve));
    },
    send(value) {
      const line = typeof value === "string" ? value : JSON.stringify(value);
      if (readers.length) readers.shift()(line); else lines.push(line);
    },
    kill() { killed = true; process.end(); },
    end() { ended = true; while (readers.length) readers.shift()(null); }
  };
  return process;
}

async function plugin(spawn, platform = "darwin") {
  const saved = new Map();
  globalThis.host = { storage: { get: key => saved.get(key), set: (key, value) => saved.set(key, value) }, platform, language: () => "zh-CN", t: text => text, spawn };
  return import(`../index.js?test=${++nonce}`);
}

test("concurrent requests share one helper and match out-of-order responses", async () => {
  const child = fakeProcess();
  let starts = 0;
  const api = await plugin((executable, args) => {
    assert.equal(executable, "bin/MyGoAppleMusic.app/Contents/MacOS/MyGoAppleMusic");
    assert.deepEqual(args, ["--bridge", "--language", "zh-CN"]);
    starts++;
    return child;
  });
  const first = api.playlists();
  const second = api.home();
  child.send({ id: child.writes[1].id, result: { title: "Library" } });
  child.send({ id: child.writes[0].id, result: [{ id: "p.1", name: "Apple list" }] });
  assert.equal((await first)[0].name, "Apple list");
  assert.equal((await second).title, "Library");
  assert.equal(starts, 1);
  child.end();
});

test("helper EOF rejects pending calls and a later call starts a fresh helper", async () => {
  const children = [fakeProcess(), fakeProcess((r, p) => p.send({ id: r.id, result: null }))];
  let starts = 0;
  const api = await plugin(() => children[starts++]);
  const pending = api.remotePause();
  children[0].end();
  await assert.rejects(pending, error => error.code === "setup");
  assert.equal(await api.remoteState(), null);
  assert.equal(starts, 2);
  assert.equal(children[1].writes.length, 1);
  children[1].end();
});

test("helper error codes reach MyGo without tearing down a healthy connection", async () => {
  const child = fakeProcess((r, p) => p.send({ id: r.id, error: { code: "setup", message: "Allow music access, then retry" } }));
  const api = await plugin(() => child);
  await assert.rejects(api.playlists(), error => error.code === "setup" && error.message === "Allow music access, then retry");
  assert.equal(child.killed, false);
  child.end();
});

test("malformed replies fail all pending callers instead of leaving them hanging", async () => {
  const child = fakeProcess();
  const api = await plugin(() => child);
  const pending = [api.home(), api.playlists()];
  child.send({ id: 1, result: [], error: { code: "x", message: "x" } });
  for (const promise of pending) await assert.rejects(promise, error => error.code === "setup");
  assert.equal(child.killed, true);
});

test("playback mutations are not retried after a timeout", async () => {
  const originalTimeout = globalThis.setTimeout;
  globalThis.setTimeout = (fn, delay) => originalTimeout(fn, delay === 25000 ? 5 : delay);
  const child = fakeProcess();
  try {
    const api = await plugin(() => child);
    await assert.rejects(api.remotePlay({ ids: ["track"], start: 0, position: 0 }), error => error.code === "unavailable");
    assert.equal(child.writes.length, 1);
    assert.equal(child.killed, true);
  } finally { globalThis.setTimeout = originalTimeout; }
});

test("unsupported platforms and missing helper give actionable setup errors", async () => {
  const unsupported = await plugin(() => { throw new Error("must not spawn"); }, "linux");
  assert.throws(() => unsupported.remoteState(), error => error.code === "unsupported");
  const missing = await plugin(() => { throw new Error("ENOENT"); });
  assert.throws(() => missing.remoteState(), error => error.code === "setup" && error.message.includes("complete plugin"));
});

test("source exposes no account UI and local playlists work without a helper", async () => {
  const api = await plugin(() => { throw new Error("must not spawn"); });
  assert.equal(api.account, undefined);
  assert.equal(api.signIn, undefined);
  assert.equal(api.signOut, undefined);
  const created = api.createPlaylist({ name: "Local collection" });
  assert.equal(created.name, "Local collection");
  assert.equal((await api.playlist({ id: created.id })).name, "Local collection");
});

test("only the selected queue identifier and millisecond position cross the native boundary", async () => {
  const child = fakeProcess((r, p) => p.send({ id: r.id, result: null }));
  const api = await plugin(() => child);
  const queue = { ids: ["am1:duplicate", "am1:duplicate", "am1:other"], start: 1, position: 65432 };
  await api.remotePlay(queue);
  await api.remoteSeek({ position: 98765 });
  assert.deepEqual(child.writes[0].params, { id: "am1:duplicate", position: 65432 });
  assert.deepEqual(child.writes[1].params, { position: 98765 });
  assert.equal(api.remoteVolume, undefined);
  child.end();
});

test("large mixed queues play the chosen track without passing unavailable neighbors", async () => {
  const child = fakeProcess((r, p) => p.send({ id: r.id, result: null }));
  const api = await plugin(() => child);
  const ids = Array(20000).fill("unavailable");
  ids[15000] = "am1:selected";
  await api.remotePlay({ ids, start: 15000, position: 0 });
  assert.deepEqual(child.writes[0].params, { id: "am1:selected", position: 0 });
  assert.throws(() => api.remotePlay({ ids, start: 20000, position: 0 }), error => error.code === "unavailable");
  assert.throws(() => api.remotePlay({ ids, start: 0, position: -1 }), error => error.code === "unavailable");
  child.end();
});

test("native MyGo album, artist and search APIs preserve identifiers and pagination", async () => {
  const child = fakeProcess((request, process) => process.send({ id: request.id, result: { ok: true } }));
  const api = await plugin(() => child);
  await api.home();
  await api.album({ id: "native-album-id" });
  await api.artist({ id: "native-artist-id" });
  await api.savedAlbums({ offset: 100 });
  await api.search({ query: "library query", kind: "albums", offset: 200 });
  assert.deepEqual(child.writes.map(({ method, params }) => ({ method, params })), [
    { method: "browse", params: { page: "albums:0" } },
    { method: "album", params: { id: "native-album-id" } },
    { method: "artist", params: { id: "native-artist-id" } },
    { method: "savedAlbums", params: { offset: 100 } },
    { method: "search", params: { query: "library query", kind: "albums", offset: 200 } }
  ]);
  child.end();
});
