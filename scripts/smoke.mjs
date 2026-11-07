import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";

const binary = fileURLToPath(new URL("../bin/MyGoAppleMusic.app/Contents/MacOS/MyGoAppleMusic", import.meta.url));
const live = process.argv.includes("--live");
function createClient() {
  const child = spawn(binary, ["--bridge", "--language", "zh-CN"], { stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map();
  let sequence = 0;
  const lines = createInterface({ input: child.stdout });
  function failAll(error) {
    for (const item of pending.values()) { clearTimeout(item.timer); item.reject(new Error(`${item.method}: ${error.message}`, { cause: error })); }
    pending.clear();
  }
  lines.on("line", line => {
    try {
      const value = JSON.parse(line);
      const item = pending.get(value.id);
      if (!item) throw new Error("Unexpected response ID");
      clearTimeout(item.timer); pending.delete(value.id);
      if (value.error) item.reject(Object.assign(new Error(`${item.method}: ${value.error.message}`), { code: value.error.code, method: item.method }));
      else item.resolve(value.result);
    } catch (error) { failAll(error); }
  });
  child.on("error", failAll);
  child.stdin.on("error", failAll);
  child.on("exit", code => failAll(new Error(`Helper exited (${code})`)));
  function call(method, params = {}, timeout = 25000) {
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); child.kill(); }, timeout);
      pending.set(id, { resolve, reject, timer, method });
      child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    });
  }
  async function close() {
    child.stdin.end();
    if (child.exitCode !== null) return;
    await new Promise(resolve => {
      const timer = setTimeout(() => child.kill(), 2000);
      child.once("exit", () => { clearTimeout(timer); resolve(); });
    });
  }
  return { call, close };
}
let client = createClient();
const call = (...args) => client.call(...args);

try {
  const info = await call("diagnostics");
  assert.equal(info.minimumOS, "14.0");
  await assert.rejects(call("unknown"), error => error.code === "unsupported");
  await assert.rejects(call("play", { id: "", position: 0 }), error => error.code === "unavailable");
  await assert.rejects(call("seek", { position: -1 }), error => error.code === "unavailable");
  console.log(`Protocol verified; bundle=${info.bundleId}, configured=${info.configured}.`);
  if (live) {
    assert.equal(info.configured, "true", "A developer-signed, configured build is required for live verification.");
    await call("signIn", {}, 240000);
    console.log("MusicKit authorization completed.");
    const saved = await call("savedAlbums", { offset: 0 });
    assert.ok(Array.isArray(saved.albums) && saved.albums.length > 0, "The library needs at least one saved album.");
    assert.ok(saved.albums.every(album => album.id && album.name), "Album cards require real native IDs and titles.");
    assert.ok(saved.albums.every(album => album.artists.some(artist => artist.id)), "Saved albums are missing native artist links.");
    const cover = saved.albums.find(album => album.imageUrl)?.imageUrl;
    assert.ok(cover, "No album artwork was exported from the library.");
    assert.equal(new URL(cover).protocol, "file:", "Native artwork must be exported to a MyGo-readable local file.");
    const image = await readFile(new URL(cover));
    assert.ok(image.length > 3 && image[0] === 0xff && image[1] === 0xd8, "Album artwork is not a readable JPEG.");
    console.log(`Saved album listing completed: ${saved.albums.length} albums, ${saved.albums.filter(album => album.imageUrl).length} covers.`);
    if (saved.more) {
      const next = await call("savedAlbums", { offset: saved.albums.length });
      assert.ok(next.albums.length > 0, "Album continuation returned no albums.");
      const firstIDs = new Set(saved.albums.map(album => album.id));
      assert.ok(next.albums.every(album => !firstIDs.has(album.id)), "Album continuation repeated the first page.");
      console.log(`Album continuation completed: ${next.albums.length} albums.`);
    }
    let selectedAlbum;
    for (const candidate of saved.albums.slice(0, 20)) {
      const detail = await call("album", { id: candidate.id });
      assert.ok(detail.album.id === candidate.id, "Album detail did not preserve its native identity.");
      assert.ok(detail.tracks.every(track => track.album.id === candidate.id), "Album tracks lost the enclosing album link.");
      if (detail.tracks.some(track => !track.unavailable)) { selectedAlbum = detail; break; }
    }
    assert.ok(selectedAlbum, "The first twenty saved albums have no playable library songs.");
    const albumSearch = await call("search", { query: selectedAlbum.album.name, kind: "albums", offset: 0 });
    assert.ok(albumSearch.albums?.some(album => album.id === selectedAlbum.album.id), "Searching a saved album did not return that album.");
    const artists = await call("browse", { page: "artists:0" });
    const artistCards = artists.sections.flatMap(section => section.artists ?? []);
    assert.ok(artistCards.length > 0 && artistCards.every(artist => artist.id), "Artist cards require native identities.");
    const selectedArtist = selectedAlbum.album.artists.find(artist => artist.id) ?? artistCards[0];
    const artistDetail = await call("artist", { id: selectedArtist.id });
    assert.ok(artistDetail.artist.id === selectedArtist.id, "Artist detail changed the selected artist identity.");
    assert.ok(artistDetail.albums.length + artistDetail.tracks.length > 0, "Saved artist detail contains no library music.");
    const artistSearch = await call("search", { query: selectedArtist.name, kind: "artists", offset: 0 });
    assert.ok(artistSearch.artists?.some(artist => artist.id === selectedArtist.id), "Searching a saved artist did not return that artist.");
    console.log(`Album detail and library search completed; artist detail has ${artistDetail.albums.length} albums and ${artistDetail.tracks.length} songs.`);
    const albumSong = selectedAlbum.tracks.find(track => !track.unavailable);
    await client.close();
    client = createClient();
    await call("play", { id: albumSong.id, position: 0 });
    await sleep(2000);
    const restarted = await call("state");
    assert.ok(restarted?.trackId === albumSong.id && restarted.playing && restarted.position > 0, "Album song did not play after helper restart.");
    await call("pause");
    console.log("Album song playback after helper restart completed.");
    const library = await call("browse", { page: "library:0" });
    const libraryTracks = library.sections.flatMap(section => section.tracks ?? []);
    assert.ok(libraryTracks.length <= 100, "Library page exceeded its requested size.");
    const linkedSongs = libraryTracks.filter(track => track.artists.some(artist => artist.id));
    assert.ok(linkedSongs.length > 0, "No library songs have native artist links.");
    console.log(`Library first page completed: ${libraryTracks.length} songs, ${linkedSongs.length} with native artist links, ${libraryTracks.length - linkedSongs.length} with name-only credits.`);
    for (const albumID of new Set(libraryTracks.map(track => track.album.id).filter(Boolean))) {
      const detail = await call("album", { id: albumID });
      const detailIDs = new Set(detail.tracks.map(track => track.id));
      assert.ok(libraryTracks.filter(track => track.album.id === albumID).every(track => detailIDs.has(track.id)), "A song album link is dangling or changes the song identity.");
    }
    const linkedTrack = libraryTracks.find(track => track.album.id && track.artists.some(artist => artist.id));
    assert.ok(linkedTrack, "No library track has album and artist navigation links.");
    const linkedAlbum = await call("album", { id: linkedTrack.album.id });
    assert.ok(linkedAlbum.tracks.some(track => track.id === linkedTrack.id), "The same song has different IDs in library and album views.");
    const linkedArtistID = linkedTrack.artists.find(artist => artist.id).id;
    const linkedArtist = await call("artist", { id: linkedArtistID });
    assert.ok(linkedArtist.tracks.some(track => track.id === linkedTrack.id), "The same song has different IDs in library and artist views.");
    console.log("Song identity is consistent across library, album and artist views.");
    const nextPage = library.sections.find(section => section.morePage)?.morePage;
    if (nextPage) {
      const next = await call("browse", { page: nextPage });
      const nextTracks = next.sections.flatMap(section => section.tracks ?? []);
      assert.ok(nextTracks.length > 0 && nextTracks.length <= 100, "Library continuation returned an invalid page size.");
      const firstIDs = new Set(libraryTracks.map(track => track.id));
      assert.ok(nextTracks.every(track => !firstIDs.has(track.id)), "Library continuation repeated a song from the first page.");
      console.log(`Library next page completed: ${nextTracks.length} songs.`);
    }
    const lists = await call("playlists");
    console.log(`Library playlist listing completed: ${lists.length} playlists.`);
    assert.ok(lists.length, "Create a playlist with playable songs in Apple Music first.");
    let tracks = [];
    for (const list of lists.slice(0, 10)) {
      const playlist = await call("playlist", { id: list.id });
      tracks = playlist.tracks.filter(track => !track.unavailable && track.duration > 120000);
      console.log(`Playlist details completed: ${playlist.tracks.length} entries, ${tracks.length} eligible audio tracks.`);
      if (tracks.length >= 2) break;
    }
    assert.ok(tracks.length >= 2, "The first ten playlists need at least one playlist with two playable songs longer than 120 seconds.");
    const ids = tracks.slice(0, 2).map(track => track.id);
    await call("play", { id: ids[0], position: 0 });
    console.log("First playback request completed.");
    await sleep(3000);
    let state = await call("state");
    assert.ok(state?.trackId === ids[0], "First playback state did not preserve the selected track identity.");
    assert.equal(state.playing, true); assert.ok(state.position > 0);
    await call("seek", { position: 100000 });
    await sleep(1500);
    state = await call("state");
    assert.ok(state.position >= 99000, "Playback did not reach the requested position beyond 90 seconds.");
    assert.equal(state.duration, tracks[0].duration);
    const position = state.position;
    await sleep(1500);
    assert.ok((await call("state")).position > position, "Playback position did not advance after seeking.");
    await call("pause"); await sleep(500);
    assert.equal((await call("state")).playing, false);
    await call("resume"); await sleep(1000);
    assert.equal((await call("state")).playing, true);
    await call("play", { id: ids[1], position: 0 });
    await sleep(2000);
    state = await call("state");
    assert.ok(state?.trackId === ids[1], "Second playback state did not preserve the selected track identity.");
    assert.equal(state.playing, true);
    assert.ok(state.duration > 4000, "Second track duration is too short for the end-of-track check.");
    const duration = state.duration;
    await call("seek", { position: duration - 4000 });
    const deadline = Date.now() + 15000;
    let previousPosition = 0;
    let ended = false;
    while (Date.now() < deadline) {
      state = await call("state", {}, Math.max(1, deadline - Date.now()));
      if (state === null) { ended = true; break; }
      assert.ok(state.trackId === ids[1], "End-of-track state changed the selected track identity.");
      if (!state.playing && (state.position >= duration - 2500 || (state.position === 0 && previousPosition >= duration - 2500))) {
        ended = true;
        break;
      }
      previousPosition = state.position;
      await sleep(Math.min(500, Math.max(0, deadline - Date.now())));
    }
    assert.ok(ended, "Playback did not emit a MyGo-compatible end-of-track signal within 15 seconds.");
    console.log("Live MusicKit library browsing, playback, seek beyond 90 seconds, pause, resume, second-track identity, and end-of-track signal verified.");
  } else {
    const account = await call("account");
    assert.ok(account === null || account.id === "apple-music");
    if (info.configured === "false") await assert.rejects(call("signIn"), error => error.code === "setup");
    console.log("No-prompt helper smoke passed. Full playback was not tested.");
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (live) { try { await call("pause", {}, 3000); } catch {} }
  await client.close();
}
