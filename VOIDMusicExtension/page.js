// Functions that run INSIDE the YouTube Music page (main world), via chrome.scripting.
// Each one must be self-contained: Chrome copies the function's source into the page,
// so it can't use anything defined outside it.
//
// Every YouTube Music selector lives in this file. When Google changes the page and
// something stops working, this is the only file to fix.

export function hasItems(selector) {
  return document.querySelectorAll(selector).length > 0;
}

/** Reads every playlist on music.youtube.com/library/playlists (scrolls to load all). */
export async function scrapeLibrary() {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const itemSelector = 'ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer';
  let last = -1;
  for (let i = 0; i < 40; i++) {
    const count = document.querySelectorAll(itemSelector).length;
    if (count === last) break;
    last = count;
    window.scrollTo(0, document.documentElement.scrollHeight);
    const items = document.querySelectorAll(itemSelector);
    items[items.length - 1]?.scrollIntoView();
    await sleep(900);
  }
  const out = [];
  const seen = new Set();
  for (const a of document.querySelectorAll('a[href*="list="], a[href*="browse/VL"]')) {
    const href = a.getAttribute('href') || '';
    const id = (href.match(/[?&]list=([^&]+)/) || [])[1] || (href.match(/browse\/VL([^?&/]+)/) || [])[1];
    // SE = "Episodes for later", RDPN = podcast feeds: not music.
    if (!id || seen.has(id) || id === 'SE' || id.startsWith('RDPN')) continue;
    const item = a.closest(itemSelector);
    if (!item) continue;
    const title = (item.querySelector('.title')?.textContent || a.getAttribute('title') || a.textContent || '').trim();
    const subtitle = (item.querySelector('.subtitle, .secondary-flex-columns')?.textContent || '')
      .replace(/\s+/g, ' ').trim();
    if (!title) continue;
    seen.add(id);
    out.push({ id, title, subtitle });
  }
  return out;
}

/** Reads up to `limit` tracks from an open playlist page (scrolls to load more). */
export async function scrapeTracks(limit) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const rows = () => {
    const shelf = document.querySelector('ytmusic-playlist-shelf-renderer');
    return (shelf || document).querySelectorAll('ytmusic-responsive-list-item-renderer');
  };
  // Songs load in chunks as you scroll. Stop only after several quiet rounds in a row.
  let last = -1;
  let quiet = 0;
  for (let i = 0; i < 80 && rows().length < limit && quiet < 4; i++) {
    const count = rows().length;
    quiet = count === last ? quiet + 1 : 0;
    last = count;
    const all = rows();
    all[all.length - 1]?.scrollIntoView();
    window.scrollTo(0, document.documentElement.scrollHeight);
    await sleep(quiet > 0 ? 1400 : 900);
  }
  const out = [];
  const seen = new Set();
  for (const row of rows()) {
    const link = row.querySelector('a[href*="watch?v="]');
    if (!link) continue;
    const videoId = new URL(link.href, location.href).searchParams.get('v');
    if (!videoId || seen.has(videoId)) continue;
    seen.add(videoId);
    const title = (row.querySelector('.title')?.textContent || link.textContent || '').trim();
    let artist = (row.querySelector('a[href*="channel/"], a[href*="browse/UC"]')?.textContent || '').trim();
    if (!artist) {
      artist = ((row.querySelector('.secondary-flex-columns')?.textContent || '').split('•')[0] || '').trim();
    }
    out.push({ videoId, title, artist });
    if (out.length >= limit) break;
  }
  return out;
}

/** Reads the results of an open search page: top result first, then each shelf. */
export function scrapeSearch() {
  const out = [];
  const seen = new Set();
  const push = (el, kind) => {
    const link = el.querySelector('a[href*="watch?v="]');
    if (!link) return;
    const videoId = new URL(link.href, location.href).searchParams.get('v');
    if (!videoId || seen.has(videoId)) return;
    seen.add(videoId);
    // The top-result card also holds a "More from YouTube" video with its own title, so take the
    // title from the link that really belongs to this song, never just the first .title in the card.
    let title = '';
    for (const a of el.querySelectorAll('a[href*="watch?v=' + videoId + '"]')) {
      const t = (a.textContent || '').replace(/\s+/g, ' ').trim();
      if (t) { title = t; break; }
    }
    if (!title) {
      for (const t of el.querySelectorAll('.title')) {
        if (t.closest('.more-from-youtube, [class*="secondary"], [class*="more"]')) continue;
        const text = (t.textContent || '').replace(/\s+/g, ' ').trim();
        if (text) { title = text; break; }
      }
    }
    if (!title) title = (link.textContent || '').trim();
    const subtitle = (el.querySelector('.subtitle, .secondary-flex-columns')?.textContent || '')
      .replace(/\s+/g, ' ').trim();
    const artist = (el.querySelector('a[href*="channel/"], a[href*="browse/UC"]')?.textContent || '').trim();
    out.push({ videoId, title, artist, subtitle, kind });
  };
  const top = document.querySelector('ytmusic-card-shelf-renderer');
  if (top) push(top, 'Top result');
  for (const shelf of document.querySelectorAll('ytmusic-shelf-renderer')) {
    const kind = (shelf.querySelector('h2')?.textContent || '').replace(/\s+/g, ' ').trim();
    for (const row of shelf.querySelectorAll('ytmusic-responsive-list-item-renderer')) push(row, kind);
  }
  // Rows that sit outside a titled shelf (videos, for one) still count; push() skips repeats.
  for (const row of document.querySelectorAll('ytmusic-responsive-list-item-renderer')) push(row, '');
  return out.slice(0, 25);
}

/** Starts playback if it isn't running yet. Returns true once audio is actually playing. */
export function ensurePlaying() {
  const player = document.getElementById('movie_player');
  const video = document.querySelector('video');
  if (!player && !video) return false;
  if (player?.getPlayerState?.() === 1) return true;
  if (video && !video.paused && video.currentTime > 0) return true;
  try { player?.playVideo?.(); } catch (e) { /* not ready yet */ }
  if (video && video.paused) video.play().catch(() => {});
  return false;
}

export function control(action) {
  const player = document.getElementById('movie_player');
  const video = document.querySelector('video');
  const click = (selector) => {
    const button = document.querySelector(selector);
    if (!button) return false;
    button.click();
    return true;
  };
  switch (action) {
    case 'play':
      if (player?.playVideo) { player.playVideo(); return true; }
      if (video) { video.play().catch(() => {}); return true; }
      return false;
    case 'pause':
      if (player?.pauseVideo) { player.pauseVideo(); return true; }
      if (video) { video.pause(); return true; }
      return false;
    case 'restart':
      if (player?.seekTo) player.seekTo(0, true);
      else if (video) video.currentTime = 0;
      if (player?.playVideo) player.playVideo();
      else if (video) video.play().catch(() => {});
      return !!(player || video);
    case 'next':
      if (click('ytmusic-player-bar .next-button')) return true;
      if (player?.nextVideo) { player.nextVideo(); return true; }
      return false;
    case 'previous':
      if (click('ytmusic-player-bar .previous-button')) return true;
      if (player?.previousVideo) { player.previousVideo(); return true; }
      return false;
    case 'like': {
      const renderer = document.querySelector('ytmusic-player-bar ytmusic-like-button-renderer');
      if (!renderer) return false;
      if (renderer.getAttribute('like-status') === 'LIKE') return true;
      const button = [...renderer.querySelectorAll('button')]
        .find((b) => /^like/i.test(b.getAttribute('aria-label') || ''));
      if (!button) return false;
      button.click();
      return true;
    }
  }
  return false;
}

export function setVolume(level) {
  const player = document.getElementById('movie_player');
  if (player?.setVolume) {
    if (level > 0 && player.isMuted?.()) player.unMute?.();
    player.setVolume(level);
    return true;
  }
  const video = document.querySelector('video');
  if (video) { video.volume = Math.max(0, Math.min(1, level / 100)); return true; }
  return false;
}

export function getState() {
  const player = document.getElementById('movie_player');
  const video = document.querySelector('video');
  if (!player && !video) return null;
  const data = player?.getVideoData?.() || {};
  const bar = document.querySelector('ytmusic-player-bar');
  const title = data.title || bar?.querySelector('.title')?.textContent?.trim() || '';
  const byline = (bar?.querySelector('.byline')?.textContent || '').replace(/\s+/g, ' ').trim();
  const artist = (byline.split('•')[0] || data.author || '').trim();
  const playerState = player?.getPlayerState?.();
  const num = (x) => (typeof x === 'number' && isFinite(x) ? x : 0);
  return {
    videoId: data.video_id || '',
    title,
    artist,
    playing: playerState === 1 || (!!video && !video.paused && !video.ended),
    volume: Math.round(num(player?.getVolume?.() ?? (video ? video.volume * 100 : 0))),
    time: num(player?.getCurrentTime?.() ?? video?.currentTime),
    duration: num(player?.getDuration?.() ?? video?.duration),
    liked: bar?.querySelector('ytmusic-like-button-renderer')?.getAttribute('like-status') === 'LIKE',
  };
}

/** Reads the songs on music.youtube.com/listen_again (what you keep replaying). */
export async function scrapeListenAgain() {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const itemSelector = 'ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer';
  let last = -1;
  let quiet = 0;
  for (let i = 0; i < 40 && quiet < 3; i++) {
    const count = document.querySelectorAll(itemSelector).length;
    quiet = count === last ? quiet + 1 : 0;
    last = count;
    const items = document.querySelectorAll(itemSelector);
    items[items.length - 1]?.scrollIntoView();
    window.scrollTo(0, document.documentElement.scrollHeight);
    await sleep(quiet > 0 ? 1200 : 800);
  }
  const out = [];
  const seen = new Set();
  for (const item of document.querySelectorAll(itemSelector)) {
    const link = item.querySelector('a[href*="watch?v="]');
    if (!link) continue;                     // albums and playlists have no song link
    const videoId = new URL(link.href, location.href).searchParams.get('v');
    if (!videoId || seen.has(videoId)) continue;
    seen.add(videoId);
    const title = (item.querySelector('.title')?.textContent || link.getAttribute('title') || link.textContent || '').trim();
    const subtitle = (item.querySelector('.subtitle, .secondary-flex-columns')?.textContent || '')
      .replace(/\s+/g, ' ').trim();
    const parts = subtitle.split('•').map((p) => p.trim()).filter(Boolean);
    if (parts.length && /^(song|video|single)$/i.test(parts[0])) parts.shift();
    const artist = (item.querySelector('a[href*="channel/"], a[href*="browse/UC"]')?.textContent || parts[0] || '').trim();
    if (title) out.push({ videoId, title, artist });
  }
  return out;
}
