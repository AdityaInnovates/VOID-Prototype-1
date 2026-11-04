// VOID Music Bridge: connects this browser to VOID on your Mac.
//
// VOID runs a tiny WebSocket server on 127.0.0.1 only. This worker connects to it,
// proves it's yours with the pairing code from VOID's menu, then carries out VOID's
// commands on your YouTube Music tab and reports what's playing.

import * as page from './page.js';

const VOID_URL = 'ws://127.0.0.1:47321';
const MUSIC = 'https://music.youtube.com';

let socket = null;
let paired = false;
let pingTimer = null;
let pollTimer = null;
let lastSent = '';
let lastSentAt = 0;
let workerTabId = null;
let workerQueue = Promise.resolve();
/** VOID couldn't find the installed YouTube Music app to open. */
let appMissing = false;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------- connection

async function setStatus(status) {
  await chrome.storage.local.set({ status });
}

async function connect() {
  if (socket && (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN)) return;
  const { token } = await chrome.storage.local.get('token');
  if (!token) {
    await setStatus('Paste the pairing code from VOID’s menu.');
    return;
  }
  let ws;
  try {
    ws = new WebSocket(VOID_URL);
  } catch (e) {
    return;
  }
  socket = ws;
  ws.onopen = () => {
    send({ type: 'hello', token: token.trim().toUpperCase(), version: chrome.runtime.getManifest().version });
  };
  ws.onmessage = (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch (e) { return; }
    onMessage(message);
  };
  ws.onclose = () => {
    if (socket === ws) socket = null;
    paired = false;
    clearInterval(pingTimer);
    clearInterval(pollTimer);
    setStatus('Waiting for VOID (is it running?)');
  };
  ws.onerror = () => {};
}

function send(message) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

async function onMessage(message) {
  if (message.type === 'welcome') {
    paired = true;
    await setStatus('Connected to VOID');
    // Regular traffic keeps this worker alive (Chrome 116+).
    clearInterval(pingTimer);
    pingTimer = setInterval(() => send({ type: 'ping' }), 20000);
    clearInterval(pollTimer);
    lastSent = '';
    pollTimer = setInterval(pollState, 1500);
    return;
  }
  if (message.type === 'rejected') {
    await setStatus('Wrong pairing code. Copy it again from VOID’s menu.');
    return;
  }
  if (message.type === 'appMissing') { appMissing = true; return; }
  if (message.type === 'pong' || !message.id) return;

  const handler = commands[message.type];
  if (!handler) {
    send({ re: message.id, ok: false, error: `Unknown command ${message.type}` });
    return;
  }
  try {
    const data = await handler(message);
    send({ re: message.id, ok: true, data: data || {} });
  } catch (error) {
    send({ re: message.id, ok: false, error: String(error?.message || error) });
  }
}

chrome.runtime.onInstalled.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
chrome.alarms.create('void-reconnect', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'void-reconnect') connect();
});
chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message?.type === 'reconnect') {
    if (socket) socket.close();
    socket = null;
    setTimeout(connect, 200);
    reply({ ok: true });
  }
});
connect();

// ---------------------------------------------------------------- tabs

/**
 * Finds your YouTube Music. The installed app's window comes first: Chrome allows
 * autoplay for installed apps, so music can start without a click.
 */
async function findMusicTab() {
  const tabs = (await chrome.tabs.query({ url: `${MUSIC}/*` })).filter((t) => t.id !== workerTabId);
  if (!tabs.length) return null;
  const windows = await Promise.all(tabs.map((t) => chrome.windows.get(t.windowId).catch(() => null)));
  // An installed app's window is reported as 'app' (or sometimes 'popup'), never 'normal'.
  const inApp = tabs.find((_, i) => windows[i] && windows[i].type !== 'normal');
  return inApp || tabs.find((t) => t.audible) || tabs[0];
}

/** Your YouTube Music; asks VOID to open the installed app if it isn't running. */
async function musicTab(create = true) {
  const found = await findMusicTab();
  if (found || !create) return found;

  appMissing = false;
  send({ type: 'launchApp' });
  const end = Date.now() + 15000;
  while (Date.now() < end && !appMissing) {
    await sleep(500);
    const tab = await findMusicTab();
    if (tab) {
      await waitForLoad(tab.id);
      return tab;
    }
  }
  // No installed app: a normal tab works too, though Chrome may ask for one click.
  const tab = await chrome.tabs.create({ url: `${MUSIC}/`, active: false });
  await waitForLoad(tab.id);
  return tab;
}

function waitForLoad(tabId, timeout = 20000) {
  return new Promise((resolve) => {
    const timer = setTimeout(done, timeout);
    function listener(id, info) {
      if (id === tabId && info.status === 'complete') done();
    }
    function done() {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve();
    }
    chrome.tabs.onUpdated.addListener(listener);
  });
}

/** YouTube Music asks "Leave site?" when its tab is told to go elsewhere. Switch that prompt off first. */
async function disarmLeavePrompt(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      world: 'MAIN',
      func: () => {
        try {
          window.addEventListener('beforeunload', (e) => { e.stopImmediatePropagation(); }, true);
          window.onbeforeunload = null;
          Object.defineProperty(window, 'onbeforeunload', { get: () => null, set: () => {}, configurable: true });
        } catch (e) { /* page not ready, nothing to disarm */ }
      },
    });
  } catch (e) { /* tab isn't a YouTube Music page yet */ }
}

async function navigate(tabId, url) {
  await disarmLeavePrompt(tabId);
  const loaded = waitForLoad(tabId);
  await chrome.tabs.update(tabId, { url });
  await loaded;
}

async function run(tabId, func, args = []) {
  const [result] = await chrome.scripting.executeScript({ target: { tabId }, world: 'MAIN', func, args });
  return result?.result;
}

async function waitFor(tabId, func, args = [], timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const result = await run(tabId, func, args).catch(() => null);
    if (result) return result;
    await sleep(400);
  }
  return null;
}

/**
 * Runs `work` in a hidden, muted helper tab that's closed afterwards, so reading your
 * library or searching never interrupts what's playing. One at a time.
 */
function withWorker(work) {
  const job = workerQueue.then(async () => {
    const tab = await chrome.tabs.create({ url: 'about:blank', active: false });
    workerTabId = tab.id;
    try {
      await chrome.tabs.update(tab.id, { muted: true }).catch(() => {});
      return await work(tab.id);
    } finally {
      workerTabId = null;
      chrome.tabs.remove(tab.id).catch(() => {});
    }
  });
  workerQueue = job.catch(() => {});
  return job;
}

// ---------------------------------------------------------------- commands

const commands = {
  /** Reads all playlists; reads tracks only for playlists VOID hasn't seen in this shape. */
  async syncLibrary(message) {
    const known = message.known || {};
    return withWorker(async (tabId) => {
      await navigate(tabId, `${MUSIC}/library/playlists`);
      const ready = await waitFor(tabId, page.hasItems, ['ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer'], 20000);
      if (!ready) throw new Error('Your library didn’t load. Are you signed in to YouTube Music in Chrome?');
      const playlists = (await run(tabId, page.scrapeLibrary)) || [];
      for (const playlist of playlists) {
        if (known[playlist.id] === playlist.subtitle) continue;
        await navigate(tabId, `${MUSIC}/playlist?list=${encodeURIComponent(playlist.id)}`);
        await waitFor(tabId, page.hasItems, ['ytmusic-responsive-list-item-renderer'], 15000);
        const limit = playlist.id === 'LM' ? 300 : 60;
        const expected = Number((playlist.subtitle.match(/(\d+)\s+(?:tracks?|songs?)/i) || [])[1]) || 0;
        const want = expected ? Math.min(expected, limit) : 0;
        playlist.tracks = (await run(tabId, page.scrapeTracks, [limit])) || [];
        // Short by more than a few unavailable songs? Read it once more.
        if (want && playlist.tracks.length < want - 3) {
          await sleep(1500);
          const again = (await run(tabId, page.scrapeTracks, [limit])) || [];
          if (again.length > playlist.tracks.length) playlist.tracks = again;
        }
        playlist.expected = expected;
      }
      return { playlists };
    });
  },

  /** The songs on your "Listen again" page. */
  async syncListenAgain() {
    return withWorker(async (tabId) => {
      await navigate(tabId, `${MUSIC}/listen_again`);
      await waitFor(tabId, page.hasItems, ['ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer'], 20000);
      return { items: (await run(tabId, page.scrapeListenAgain)) || [] };
    });
  },

  async search(message) {
    const started = Date.now();
    return withWorker(async (tabId) => {
      await navigate(tabId, `${MUSIC}/search?q=${encodeURIComponent(message.query || '')}`);
      await waitFor(tabId, page.hasItems, ['ytmusic-responsive-list-item-renderer, ytmusic-card-shelf-renderer'], 10000);
      // The top card appears first and the result rows load after it. Read the list once it has
      // stopped growing, but never hold the answer back for more than a few seconds.
      let items = [];
      let steady = 0;
      const end = Math.min(Date.now() + 5000, started + 24000);
      while (Date.now() < end && steady < 2) {
        await sleep(500);
        const now = (await run(tabId, page.scrapeSearch).catch(() => null)) || [];
        if (now.length > 3 && now.length === items.length) steady++;
        else steady = 0;
        items = now;
      }
      console.log('VOID search', message.query, items.length, 'results in', Date.now() - started, 'ms');
      return { items };
    });
  },

  async play(message) {
    const tab = await musicTab(true);
    await navigate(tab.id, message.url);
    const playing = await waitFor(tab.id, page.ensurePlaying, [], 12000);
    if (!playing) {
      throw new Error('Chrome blocked autoplay. Click play once on the YouTube Music tab, and I can take it from there.');
    }
    lastSent = '';
    return {};
  },

  async control(message) {
    const tab = await musicTab(false);
    if (!tab) throw new Error('YouTube Music isn’t open.');
    const done = await run(tab.id, page.control, [message.action]);
    if (!done) throw new Error(`Couldn’t ${message.action} on the YouTube Music page.`);
    lastSent = '';
    return {};
  },

  async volume(message) {
    const tab = await musicTab(false);
    if (!tab) throw new Error('YouTube Music isn’t open.');
    await run(tab.id, page.setVolume, [Math.round(message.level)]);
    return {};
  },

  async getState() {
    const tab = await musicTab(false);
    return (tab && (await run(tab.id, page.getState))) || {};
  },
};

// ---------------------------------------------------------------- now playing

async function pollState() {
  if (!paired) return;
  const tab = await musicTab(false).catch(() => null);
  if (!tab) return;
  const state = await run(tab.id, page.getState).catch(() => null);
  if (!state) return;
  const key = `${state.videoId}|${state.playing}|${state.liked}|${state.volume}`;
  // Send on any change, and every 5 s anyway so VOID knows how long you listened.
  if (key !== lastSent || Date.now() - lastSentAt > 5000) {
    lastSent = key;
    lastSentAt = Date.now();
    send({ type: 'state', ...state });
  }
}
