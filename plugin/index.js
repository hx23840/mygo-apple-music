const executable = "bin/MyGoAppleMusic.app/Contents/MacOS/MyGoAppleMusic";
let connection = null;
let sequence = 0;

function failure(code, message) {
  const error = new Error(host.t(message));
  error.code = code;
  return error;
}

function close(state, error) {
  if (state.closed) return;
  state.closed = true;
  if (connection === state) connection = null;
  for (const pending of state.pending.values()) {
    clearTimeout(pending.timer);
    pending.reject(error);
  }
  state.pending.clear();
  try { state.process.kill(); } catch (_) {}
}

async function readResponses(state) {
  try {
    while (!state.closed) {
      const line = await state.process.readLine();
      if (line === null) throw failure("setup", "Apple Music helper stopped. Please try again.");
      if (line.length > 8 * 1024 * 1024) throw new Error("Oversized response");
      const response = JSON.parse(line);
      if (!response || !Number.isSafeInteger(response.id) ||
          (Object.prototype.hasOwnProperty.call(response, "result") === Object.prototype.hasOwnProperty.call(response, "error"))) {
        throw new Error("Invalid response envelope");
      }
      const pending = state.pending.get(response.id);
      if (!pending) throw new Error("Unknown response ID");
      if (response.error && (typeof response.error.code !== "string" || typeof response.error.message !== "string")) {
        throw new Error("Invalid error envelope");
      }
      state.pending.delete(response.id);
      clearTimeout(pending.timer);
      if (response.error) pending.reject(failure(response.error.code, response.error.message));
      else pending.resolve(response.result);
    }
  } catch (error) {
    close(state, error.code ? error : failure("setup", "Apple Music helper returned an invalid response."));
  }
}

function connect() {
  if (connection) return connection;
  if (host.platform !== "darwin") throw failure("unsupported", "Apple Music requires macOS 14 or later.");
  let process;
  try {
    process = host.spawn(executable, ["--bridge", "--language", host.language()]);
  } catch (_) {
    throw failure("setup", "Unable to start Apple Music. Install the complete plugin for this Mac and allow its helper in Settings > Plugins. macOS 14 or later is required.");
  }
  const state = { process, pending: new Map(), closed: false };
  connection = state;
  readResponses(state);
  return state;
}

function call(method, params = {}) {
  const state = connect();
  if (state.pending.size >= 32) return Promise.reject(failure("unavailable", "Too many Apple Music requests. Please try again."));
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => close(state, failure("unavailable", "Apple Music request timed out. Please try again.")), 25000);
    state.pending.set(id, { resolve, reject, timer });
    try { state.process.write(JSON.stringify({ id, method, params }) + "\n"); }
    catch (_) { close(state, failure("setup", "Apple Music helper stopped. Please try again.")); }
  });
}

const libraryKey = "localLibrary.v1";
const trackCache = new Map();
const resolving = new Map();
const hydrating = new Map();
const likeRevisions = new Map();
let localState = null;

function validID(id) { return typeof id === "string" && id.length > 0 && id.length <= 8192; }
function validTrack(track) {
  return track && validID(track.id) && track.id.startsWith("am1:") && typeof track.name === "string" && Array.isArray(track.artists) &&
    track.artists.every(artist => artist && typeof artist.name === "string") &&
    track.album && typeof track.album.name === "string" && Number.isSafeInteger(track.duration) && track.duration >= 0;
}
function copy(value) { return JSON.parse(JSON.stringify(value)); }
function invalid(message) { throw failure("unavailable", message); }
function validIDs(ids) {
  if (!Array.isArray(ids) || ids.length > 10000 || !ids.every(validID)) invalid("Invalid song selection.");
  return [...new Set(ids)];
}
function validName(name) {
  if (typeof name !== "string" || !name.trim() || name.trim().length > 200) invalid("Enter a playlist name of up to 200 characters.");
  return name.trim();
}
function pageOffset(offset = 0) {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > 1000000) invalid("Invalid collection offset.");
  return offset;
}
function state() {
  if (localState) return localState;
  const value = host.storage.get(libraryKey);
  if (value === undefined || value === null) {
    localState = { version: 1, nextPlaylist: 1, likes: [], playlists: [], imported: [], tracks: {} };
    return localState;
  }
  const good = value.version === 1 && Number.isSafeInteger(value.nextPlaylist) && value.nextPlaylist > 0 &&
    Array.isArray(value.likes) && value.likes.length <= 10000 && value.likes.every(validID) &&
    Array.isArray(value.imported) && value.imported.every(validID) &&
    Array.isArray(value.playlists) && value.playlists.length <= 5000 && value.playlists.every(p =>
      p && validID(p.id) && p.id.startsWith("mygo-local:") && typeof p.name === "string" &&
      (p.origin === undefined || validID(p.origin)) &&
      ((p.trackIds === null && validID(p.origin)) || (Array.isArray(p.trackIds) && p.trackIds.length <= 10000 && p.trackIds.every(validID)))) &&
    value.tracks && typeof value.tracks === "object" && !Array.isArray(value.tracks) &&
    Object.entries(value.tracks).every(([id, track]) => id === track.id && validTrack(track));
  if (!good) throw failure("setup", "The local MyGo music collection is invalid or from a newer plugin. Its data has been preserved.");
  const playlistIDs = value.playlists.map(p => p.id);
  if (new Set(playlistIDs).size !== playlistIDs.length || playlistIDs.some(id => !/^mygo-local:[1-9][0-9]*$/.test(id) || Number(id.slice(11)) >= value.nextPlaylist)) {
    throw failure("setup", "The local MyGo music collection is invalid or from a newer plugin. Its data has been preserved.");
  }
  const required = [...value.likes, ...value.playlists.flatMap(p => p.trackIds ?? [])];
  if (required.some(id => !Object.prototype.hasOwnProperty.call(value.tracks, id))) {
    throw failure("setup", "The local MyGo music collection is incomplete. Its data has been preserved.");
  }
  localState = copy(value);
  return localState;
}
function mutate(change) {
  const next = copy(state());
  const result = change(next);
  const used = new Set([...next.likes, ...next.playlists.flatMap(p => p.trackIds ?? [])]);
  next.tracks = Object.fromEntries(Object.entries(next.tracks).filter(([id]) => used.has(id)));
  host.storage.set(libraryKey, next);
  localState = next;
  return result;
}
function rememberTrack(track) {
  if (!validTrack(track)) return;
  trackCache.delete(track.id);
  trackCache.set(track.id, copy(track));
  if (trackCache.size > 5000) trackCache.delete(trackCache.keys().next().value);
}
function remember(value) {
  if (!value || typeof value !== "object") return value;
  for (const track of value.tracks ?? []) rememberTrack(track);
  for (const section of value.sections ?? []) remember(section);
  for (const list of value.playlists ?? []) remember(list);
  return value;
}
async function native(method, params) { return remember(await call(method, params)); }
async function resolveTrack(id) {
  if (!validID(id)) invalid("Invalid song selection.");
  const saved = state().tracks;
  const cached = trackCache.get(id) ?? (Object.prototype.hasOwnProperty.call(saved, id) ? saved[id] : undefined);
  if (cached) return copy(cached);
  if (resolving.has(id)) return resolving.get(id);
  const promise = (async () => {
    const tracks = await call("tracks", { ids: [id] });
    const track = Array.isArray(tracks) && tracks.find(item => item.id === id);
    if (!validTrack(track)) invalid("This song is unavailable. Refresh its source and try again.");
    rememberTrack(track);
    return copy(track);
  })();
  resolving.set(id, promise);
  try { return await promise; } finally { resolving.delete(id); }
}
function localPlaylist(id, current = state()) {
  const list = current.playlists.find(item => item.id === id);
  if (!list) invalid("This local playlist no longer exists.");
  return list;
}
function playlistDTO(list, current = state(), detail = false) {
  const tracks = (list.trackIds ?? []).map(id => copy(current.tracks[id]));
  const result = { id: list.id, name: list.name, mine: true, fixed: false,
    trackCount: list.trackIds === null ? list.trackCount ?? 0 : tracks.length,
    imageUrl: tracks[0]?.album?.imageUrl ?? list.imageUrl,
    description: host.t(list.origin ? "Local copy in MyGo. Changes stay on this Mac." : "Stored locally in MyGo.") };
  if (detail) result.tracks = tracks;
  return result;
}
async function materialize(id) {
  const list = localPlaylist(id);
  if (list.trackIds !== null) return;
  if (hydrating.has(id)) return hydrating.get(id);
  const promise = (async () => {
    const source = await native("playlist", { id: list.origin });
    if (!source || !Array.isArray(source.tracks) || source.tracks.length > 10000 || !source.tracks.every(validTrack)) {
      invalid("Apple Music returned an incomplete playlist. Please retry.");
    }
    mutate(next => {
      const current = localPlaylist(id, next);
      if (current.trackIds !== null) return;
      current.trackIds = source.tracks.map(track => track.id);
      for (const track of source.tracks) next.tracks[track.id] = copy(track);
    });
  })();
  hydrating.set(id, promise);
  try { return await promise; } finally { hydrating.delete(id); }
}
function importHeaders(headers) {
  if (!Array.isArray(headers) || !headers.every(p => p && validID(p.id) && typeof p.name === "string")) {
    invalid("Apple Music returned an incomplete playlist. Please retry.");
  }
  if (headers.every(p => state().imported.includes(p.id))) return;
  mutate(next => {
    for (const header of headers) {
      if (next.imported.includes(header.id)) continue;
      if (next.playlists.length >= 5000) invalid("MyGo supports up to 5000 local playlists.");
      next.playlists.push({ id: "mygo-local:" + next.nextPlaylist++, name: header.name, origin: header.id,
        trackIds: null, trackCount: header.trackCount ?? 0, imageUrl: header.imageUrl });
      next.imported.push(header.id);
    }
  });
}
export function home() { return native("browse", { page: "albums:0" }); }
export async function browse(params) {
  if (typeof params?.page === "string" && /^playlists:[0-9]+$/.test(params.page)) {
    const offset = pageOffset(Number(params.page.slice(10)));
    const all = await playlists();
    return { title: host.t("Playlists"), sections: [{ title: host.t("Playlists"), playlists: all.slice(offset, offset + 100),
      morePage: offset + 100 < all.length ? "playlists:" + (offset + 100) : undefined }] };
  }
  return native("browse", params);
}
export function album(params) { return native("album", params); }
export function artist(params) { return native("artist", params); }
export function savedAlbums(params) { return native("savedAlbums", params); }
export async function search(params) {
  if (params?.kind === "playlists") {
    const offset = pageOffset(params.offset);
    if (typeof params.query !== "string" || !params.query.trim() || params.query.length > 512) invalid("Enter a search query of up to 512 characters.");
    const query = params.query.trim().toLowerCase();
    const matches = (await playlists()).filter(p => p.name.toLowerCase().includes(query));
    return { playlists: matches.slice(offset, offset + 100), more: offset + 100 < matches.length };
  }
  return native("search", params);
}
export async function playlists() {
  let headers;
  try { headers = await call("playlists"); }
  catch (error) {
    if (!state().playlists.length && !state().imported.length) throw error;
    console.warn("Apple Music playlist refresh failed; showing local MyGo collections.");
    return state().playlists.map(p => playlistDTO(p));
  }
  importHeaders(headers);
  return state().playlists.map(p => playlistDTO(p));
}
export async function playlist({ id }) {
  if (!validID(id)) invalid("This local playlist no longer exists.");
  if (!id.startsWith("mygo-local:")) return native("playlist", { id });
  await materialize(id);
  return playlistDTO(localPlaylist(id), state(), true);
}
export function createPlaylist({ name }) {
  name = validName(name);
  const id = mutate(next => {
    if (next.playlists.length >= 5000) invalid("MyGo supports up to 5000 local playlists.");
    const id = "mygo-local:" + next.nextPlaylist++;
    next.playlists.push({ id, name, trackIds: [] });
    return id;
  });
  return playlistDTO(localPlaylist(id), state(), true);
}
export function renamePlaylist({ id, name }) {
  name = validName(name);
  mutate(next => { localPlaylist(id, next).name = name; });
}
export function deletePlaylist({ id }) {
  mutate(next => { localPlaylist(id, next); next.playlists = next.playlists.filter(p => p.id !== id); });
}
export async function addToPlaylist({ id, trackIds }) {
  trackIds = validIDs(trackIds);
  await materialize(id);
  const tracks = [];
  for (const trackID of trackIds) tracks.push(await resolveTrack(trackID));
  mutate(next => {
    const list = localPlaylist(id, next);
    const ids = [...list.trackIds, ...trackIds.filter(trackID => !list.trackIds.includes(trackID))];
    if (ids.length > 10000) invalid("A local playlist supports up to 10000 songs.");
    list.trackIds = ids;
    for (const track of tracks) next.tracks[track.id] = track;
  });
}
export async function removeFromPlaylist({ id, trackIds }) {
  const removed = new Set(validIDs(trackIds));
  await materialize(id);
  mutate(next => { const list = localPlaylist(id, next); list.trackIds = list.trackIds.filter(trackID => !removed.has(trackID)); });
}
export async function movePlaylistTrack({ id, from, to }) {
  await materialize(id);
  mutate(next => {
    const list = localPlaylist(id, next);
    if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from < 0 || to < 0 || from >= list.trackIds.length || to >= list.trackIds.length) invalid("Invalid playlist position.");
    list.trackIds.splice(to, 0, list.trackIds.splice(from, 1)[0]);
  });
}
export async function like({ id, on }) {
  if (!validID(id) || typeof on !== "boolean") invalid("Invalid favorite selection.");
  const revision = {};
  likeRevisions.set(id, revision);
  try {
    const track = on ? await resolveTrack(id) : null;
    if (likeRevisions.get(id) !== revision) return;
    mutate(next => {
      if (on && next.likes.includes(id)) return;
      next.likes = next.likes.filter(item => item !== id);
      if (on) {
        if (next.likes.length >= 10000) invalid("MyGo supports up to 10000 liked songs.");
        next.likes.unshift(id);
        next.tracks[id] = track;
      }
    });
  } finally {
    if (likeRevisions.get(id) === revision) likeRevisions.delete(id);
  }
}
export function isLiked({ ids }) {
  ids = validIDs(ids);
  const liked = new Set(state().likes);
  return Object.fromEntries(ids.map(id => [id, liked.has(id)]));
}
export function liked({ offset = 0 } = {}) {
  offset = pageOffset(offset);
  const current = state();
  return { tracks: current.likes.slice(offset, offset + 100).map(id => copy(current.tracks[id])), more: offset + 100 < current.likes.length };
}
export function remotePlay({ ids, start, position }) {
  if (!Array.isArray(ids) || !Number.isSafeInteger(start) || start < 0 || start >= ids.length ||
      typeof ids[start] !== "string" || !ids[start] || !Number.isSafeInteger(position) || position < 0) {
    throw failure("unavailable", "Choose a playable Apple Music song and a valid playback position.");
  }
  return call("play", { id: ids[start], position });
}
export function remotePause() { return call("pause"); }
export function remoteResume() { return call("resume"); }
export function remoteSeek(params) { return call("seek", params); }
export function remoteState() { return call("state"); }

function createLyricsProvider(resolveTrack) {
  const storageKey = "lyrics.lrclib.v1";
  const pending = new Map();
  let queue = Promise.resolve();
  let nextRequestAt = 0;
  let cache;
  const normalize = value => typeof value === "string" ? value.trim().toLowerCase().replace(/\s+/g, " ") : "";
  const validLRC = value => typeof value === "string" && value.length <= 256000 && /\[\d+:\d+(?:[.:]\d+)?\][^\r\n]*\S/.test(value);

  function readCache() {
    if (cache) return cache;
    let saved;
    try { saved = host.storage.get(storageKey); } catch (_) {}
    cache = { version: 1, retryAt: 0, entries: [] };
    if (saved?.version !== 1 || !Array.isArray(saved.entries)) return cache;
    if (Number.isFinite(saved.retryAt)) cache.retryAt = saved.retryAt;
    cache.entries = saved.entries.filter(entry => entry && typeof entry.key === "string" && entry.key.length <= 5000 &&
      Number.isFinite(entry.expires) && entry.expires > Date.now() &&
      (entry.lrc === null || validLRC(entry.lrc))).slice(-100);
    return cache;
  }

  function saveCache() {
    const state = readCache();
    let size = 0;
    state.entries = state.entries.filter(entry => entry.expires > Date.now()).slice(-100).reverse().filter(entry => {
      size += entry.key.length + (entry.lrc?.length ?? 0);
      return size <= 1000000;
    }).reverse();
    try { host.storage.set(storageKey, state); } catch (_) {}
  }

  function remember(key, lrc, ttl) {
    const state = readCache();
    state.entries = state.entries.filter(entry => entry.key !== key);
    state.entries.push({ key, lrc, expires: Date.now() + ttl });
    saveCache();
    return lrc ? { lrc } : {};
  }

  function holdRequests(response) {
    const value = response.headers.get("Retry-After");
    const seconds = value === null || value.trim() === "" ? NaN : Number(value);
    const until = Number.isFinite(seconds) ? Date.now() + Math.max(0, seconds) * 1000 : Date.parse(value ?? "");
    const delay = Number.isFinite(until) ? Math.max(0, until - Date.now()) : 60000;
    readCache().retryAt = Date.now() + delay + Math.floor(Math.random() * delay * 0.1);
    saveCache();
  }

  async function request(track, signature, key, deadline) {
    const cached = readCache().entries.find(entry => entry.key === key && entry.expires > Date.now());
    if (cached) return cached.lrc ? { lrc: cached.lrc } : {};
    if (Date.now() < readCache().retryAt || Date.now() >= deadline) return {};
    const wait = nextRequestAt - Date.now();
    if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait));
    if (Date.now() >= deadline || Date.now() < readCache().retryAt) return {};
    const params = [
      ["track_name", track.name], ["artist_name", track.artists[0].name],
      ["duration", String(signature.duration)]
    ];
    if (track.album?.name) params.push(["album_name", track.album.name]);
    const url = "https://lrclib.net/api/get?" + params.map(([name, value]) => `${name}=${encodeURIComponent(value)}`).join("&");
    const controller = typeof AbortController === "function" ? new AbortController() : null;
    let timer;
    try {
      const operation = (async () => {
        const response = await fetch(url, {
          headers: { "User-Agent": "MyGoAppleMusic/0.3.2 (MyGo plugin; https://github.com/hx23840/mygo-apple-music)", "Accept": "application/json" },
          ...(controller ? { signal: controller.signal } : {})
        });
        if (response.status === 429 || response.status === 503) { holdRequests(response); return {}; }
        if (response.status === 404) return remember(key, null, 6 * 3600000);
        if (!response.ok || !/application\/json/i.test(response.headers.get("Content-Type") ?? "")) return {};
        const length = Number(response.headers.get("Content-Length"));
        if (Number.isFinite(length) && length > 1024 * 1024) return {};
        const text = await response.text();
        if (text.length > 512000) return {};
        const result = JSON.parse(text);
        if (!result || normalize(result.trackName) !== signature.title || normalize(result.artistName) !== signature.artist ||
          !Number.isFinite(result.duration) || Math.abs(result.duration - signature.duration) > 2 ||
          (signature.album && normalize(result.albumName) !== signature.album)) return {};
        if (result.instrumental === true) return remember(key, null, 30 * 86400000);
        if (!validLRC(result.syncedLyrics)) return remember(key, null, 6 * 3600000);
        return remember(key, result.syncedLyrics, 30 * 86400000);
      })();
      return await Promise.race([operation, new Promise((_, reject) => {
        timer = setTimeout(() => { controller?.abort(); reject(new Error("Lyrics request timed out")); }, Math.min(10000, Math.max(1, deadline - Date.now())));
      })]);
    } catch (_) { return {}; }
    finally { clearTimeout(timer); nextRequestAt = Date.now() + 200; }
  }

  return async function lyrics({ id }) {
    try {
      const track = await resolveTrack(id);
      const signature = {
        title: normalize(track?.name), artist: normalize(track?.artists?.[0]?.name),
        album: normalize(track?.album?.name), duration: track?.duration / 1000
      };
      if (!signature.title || !signature.artist || !Number.isFinite(signature.duration) || signature.duration < 1 || signature.duration > 3600 ||
        signature.title.length > 1000 || signature.artist.length > 1000 || signature.album.length > 1000) return {};
      const key = JSON.stringify(signature);
      if (pending.has(key)) return await pending.get(key);
      if (pending.size >= 8) return {};
      const deadline = Date.now() + 10000;
      const operation = queue.then(() => request(track, signature, key, deadline));
      queue = operation.catch(() => {});
      pending.set(key, operation);
      try { return await operation; } finally { pending.delete(key); }
    } catch (_) { return {}; }
  };
}

const lyricProvider = createLyricsProvider(resolveTrack);
export function lyrics(params) { return lyricProvider(params); }
