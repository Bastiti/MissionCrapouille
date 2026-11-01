/*
  Crapouille limo TV - the set's sound.

  The TV's picture is a page drawn into the screen texture (craptech_limotv_screen.html), and the game's browser
  plays no sound in a page nobody clicked: no click ever reaches a texture. The game's UI page has been clicked, so
  the sound plays here, in the UI: the GE extension craptech_limoTVAudio (lua/ge/extensions/craptech/limoTVAudio.lua)
  loads this file into it and calls, about ten times a second per TV that has sound:

      craptechLimoTVAudio.update({vid, gain, pan, cutoff, sync: {stop: true}})
      craptechLimoTVAudio.update({vid, gain, pan, cutoff, sync: {feed: {folder, gen, audio, first, last}, t, at, playing}})
      craptechLimoTVAudio.update({vid, gain, pan, cutoff, sync: {file, t, at, playing}})

  feed: the live stream the TV shows (live.json: the sound's init segment `audio`, pieces <gen>_<n>_audio.chunk,
  n from first to last, in the game's file system under folder); file: the channel's video file it shows instead (a
  WebM with its sound in it, played here too, held whole in memory: seeking in a big file from its local:// address
  never ends, the game's file server ignoring byte ranges; one that turns out to have no sound is left alone);
  t: where the TV's picture was in the stream or file (s) at `at` (Date.now(), ms: the same clock in both pages);
  playing: whether the picture moves. The sound follows the picture: it jumps to it when more than a quarter second
  off, else plays a little faster or slower until in step.
  gain, pan, cutoff: how the set reaches the camera (volume, left / right, muffled through the body), eased in.
  Without news for 2 s (the TV gone), the sound stops.
*/
window.craptechLimoTVAudio = (function () {
  var JUMP = 0.25;       // s off: jump to the picture
  var STEADY = 0.03;     // s off: in step
  var TIMEOUT = 2000;    // ms without news: the TV is gone
  var BACK = 4;          // pieces taken behind the newest at the start (the picture runs 2 to 3 s behind it)
  var EASE = 0.08;       // s, time constant of volume, side and muffling changes
  var SILENT_AFTER = 2;  // s of a file played without any sound decoded: it has none
  var ctx = null;
  var tvs = {};
  var silent = {};       // file path -> true: no sound in it

  function url(p) { return 'local://local' + p.split('/').map(encodeURIComponent).join('/'); }

  function audioCtx() {
    if (!ctx) ctx = new AudioContext();
    if (ctx.state === 'suspended') ctx.resume().catch(function () {});
    return ctx;
  }

  // a TV's player: an audio element through a low-pass filter (the body), a panner and a gain
  function create(vid) {
    var c = audioCtx();
    var el = new Audio();
    var T = { vid: vid, el: el, src: c.createMediaElementSource(el), filter: c.createBiquadFilter(),
              panner: c.createStereoPanner(), gain: c.createGain(), feed: null, sync: null, news: 0,
              key: null, file: null, ms: null, sb: null, objUrl: null, gen: null, folder: '', init: '', next: 0,
              low: 0, busy: false, initDone: false, retry: 0, loading: null, error: '' };
    T.filter.type = 'lowpass';
    T.filter.frequency.value = 20000;
    T.gain.gain.value = 0;
    T.src.connect(T.filter);
    T.filter.connect(T.panner);
    T.panner.connect(T.gain);
    T.gain.connect(c.destination);
    el.addEventListener('error', function () {
      if (!T.file) return;
      T.error = el.error ? el.error.code + ' ' + el.error.message : '?';
      failed(T, T.key);
    });
    return T;
  }

  function stopStream(T) {
    if (!T.key) return;
    var ms = T.ms;
    T.key = T.file = T.gen = T.ms = T.sb = T.loading = null;
    try { if (ms && ms.readyState === 'open') ms.endOfStream(); } catch (e) { /* closing anyway */ }
    T.el.pause();
    T.el.removeAttribute('src');
    T.el.load();
    if (T.objUrl) URL.revokeObjectURL(T.objUrl);
    T.objUrl = null;
  }

  function remove(T) {
    stopStream(T);
    T.gain.disconnect();
    delete tvs[T.vid];
  }

  function failed(T, key) {
    if (T.key !== key) return;
    stopStream(T);
    T.retry = Date.now() + 2000;
  }

  function startLive(T, f) {
    stopStream(T);
    var ms = new MediaSource(), key = 'live:' + f.folder + f.gen;
    T.key = key;
    T.ms = ms;
    T.gen = f.gen;
    T.folder = f.folder;
    T.init = f.audio;
    T.objUrl = URL.createObjectURL(ms);
    T.next = T.low = Math.max(f.first, f.last - BACK);
    T.busy = false;
    T.initDone = false;
    T.el.playbackRate = 1;
    T.el.src = T.objUrl;
    ms.addEventListener('sourceopen', function () {
      if (T.ms !== ms) return;
      try {
        T.sb = ms.addSourceBuffer('audio/webm; codecs="opus"');
      } catch (e) {
        failed(T, key);
        return;
      }
      T.sb.addEventListener('updateend', function () {
        T.busy = false;
        if (T.ms !== ms) return;
        follow(T);
        pump(T);
      });
      T.sb.addEventListener('error', function () { failed(T, key); });
      pump(T);
    });
  }

  function startFile(T, path) {
    stopStream(T);
    var key = T.key = 'file:' + path, mine = T.loading = {};
    T.file = path;
    fetch(url(path)).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.blob();
    }).then(function (b) {
      if (T.loading !== mine) return;
      T.objUrl = URL.createObjectURL(b);
      T.el.playbackRate = 1;
      T.el.src = T.objUrl;
    }).catch(function (e) {
      if (T.loading !== mine) return;
      T.error = String(e);
      failed(T, key);
    });
  }

  // where the picture is now (s in the stream or file), or null
  function target(T) {
    var s = T.sync;
    if (!s || typeof s.t !== 'number') return null;
    return s.t + (s.playing ? Math.max(0, Date.now() - s.at) / 1000 : 0);
  }

  // fetches and appends one piece at a time: the init segment, then on from a few seconds back, or an earlier one
  // when the picture is before the sound held
  function pump(T) {
    var f = T.feed, ms = T.ms;
    if (!T.sb || T.busy || T.sb.updating || !f || f.gen !== T.gen) return;
    var n = 0, name = T.init;
    if (T.initDone) {
      var want = target(T), b = T.el.buffered;
      if (want !== null && b.length && want < b.start(0) - 0.05 && T.low > f.first) {
        n = --T.low;
      } else {
        if (T.next < f.first) T.next = T.low = Math.max(f.first, f.last - BACK);   // fell behind: back to the edge
        if (T.next > f.last) return;                                               // all in: wait for the next
        n = T.next;
      }
      name = f.gen + '_' + n + '_audio.chunk';
    }
    T.busy = true;
    fetch(url(T.folder + name), { cache: 'no-store' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.arrayBuffer();
    }).then(function (buf) {
      if (T.ms !== ms || !T.sb) return;
      if (!T.initDone) T.initDone = true;
      else if (n === T.next) T.next++;
      T.sb.appendBuffer(buf);   // its updateend fetches the next
    }).catch(function () {
      if (T.ms !== ms) return;
      T.busy = false;
      if (T.initDone && n === T.next) T.next++;   // already deleted: skip it
    });
  }

  // keeps the sound on the picture
  function follow(T) {
    var el = T.el, s = T.sync, want = target(T);
    if (want === null || !(T.file || T.sb)) return;
    var b = el.buffered, i, held = false;
    if (T.file) {
      held = el.readyState >= 1 && want < el.duration - 0.1;   // a file: anywhere in it
    } else {
      for (i = 0; i < b.length; i++) {
        if (want >= b.start(i) && want < b.end(i) - 0.1) held = true;
      }
    }
    if (!s.playing || !held) {
      if (!el.paused) el.pause();
    } else if (!el.seeking) {
      var off = el.currentTime - want;
      if (el.paused || Math.abs(off) > JUMP) {
        el.playbackRate = 1;
        el.currentTime = want;
        if (el.paused) el.play().catch(function () {});
      } else if (Math.abs(off) > STEADY) {
        el.playbackRate = Math.max(0.95, Math.min(1.05, 1 - off * 0.5));
      } else {
        el.playbackRate = 1;
      }
    }
    if (T.sb && !T.busy && !T.sb.updating && b.length && want - b.start(0) > 30) {
      T.busy = true;
      T.sb.remove(0, want - 10);
    }
  }

  // a file that played a while without any sound decoded has none
  function soundless(T) {
    var el = T.el, played = 0, i;
    if (!T.file || typeof el.webkitAudioDecodedByteCount !== 'number' || el.webkitAudioDecodedByteCount > 0) return false;
    for (i = 0; i < el.played.length; i++) played += el.played.end(i) - el.played.start(i);
    return played > SILENT_AFTER;
  }

  function mix(T, d) {
    var now = audioCtx().currentTime;
    if (typeof d.gain === 'number') T.gain.gain.setTargetAtTime(Math.max(0, d.gain), now, EASE);
    if (typeof d.pan === 'number') T.panner.pan.setTargetAtTime(Math.max(-1, Math.min(1, d.pan)), now, EASE);
    if (typeof d.cutoff === 'number') T.filter.frequency.setTargetAtTime(d.cutoff, now, EASE);
  }

  setInterval(function () {
    var now = Date.now();
    Object.keys(tvs).forEach(function (k) {
      var T = tvs[k];
      if (now - T.news > TIMEOUT) {
        remove(T);
        return;
      }
      if (soundless(T)) {
        silent[T.file] = true;
        stopStream(T);
        return;
      }
      follow(T);
      pump(T);
    });
  }, 100);

  return {
    update: function (d) {
      if (!d || d.vid === undefined) return;
      var T = tvs[d.vid], s = d.sync || {};
      if (s.stop) {
        if (T) remove(T);
        return;
      }
      if (!T) T = tvs[d.vid] = create(d.vid);
      T.news = Date.now();
      mix(T, d);
      T.feed = s.feed || null;
      if (typeof s.t === 'number') T.sync = { t: s.t, at: s.at, playing: !!s.playing };
      var f = T.feed;
      var key = s.file ? (silent[s.file] ? null : 'file:' + s.file) : f && f.audio ? 'live:' + f.folder + f.gen : null;
      if (!key) {
        stopStream(T);
        return;
      }
      if (T.key !== key && Date.now() >= T.retry) {
        if (s.file) startFile(T, s.file);
        else startLive(T, f);
      }
      follow(T);
      pump(T);
    },
    // for a look from outside: per TV, what plays, and the sound's peak before the gain (a meter, added on the
    // first look)
    state: function () {
      return Object.keys(tvs).map(function (k) {
        var T = tvs[k], el = T.el, b = el.buffered, peak = 0, i;
        if (!T.meter) {
          T.meter = audioCtx().createAnalyser();
          T.meter.fftSize = 2048;
          T.panner.connect(T.meter);
        }
        var buf = new Float32Array(T.meter.fftSize);
        T.meter.getFloatTimeDomainData(buf);
        for (i = 0; i < buf.length; i++) peak = Math.max(peak, Math.abs(buf[i]));
        return { vid: T.vid, key: T.key, t: el.currentTime, want: target(T), paused: el.paused, rate: el.playbackRate,
                 buffered: b.length ? [b.start(0), b.end(b.length - 1)] : null, next: T.next, low: T.low,
                 gain: T.gain.gain.value, pan: T.panner.pan.value, cutoff: T.filter.frequency.value, peak: peak,
                 decoded: [el.webkitAudioDecodedByteCount, el.webkitVideoDecodedByteCount],
                 silent: Object.keys(silent), error: T.error, ctx: ctx && ctx.state };
      });
    }
  };
})();
