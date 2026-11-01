"""Crapouille limo TV - live channel feeder.

Puts a live stream (a Twitch channel, or anything streamlink or ffmpeg can open) on one channel of the limo TV (part
"Interior Lights & Wiring (Crapouille)" of the fullsize limousine). The game has no network access, so this script
does the fetching: streamlink pulls the stream, ffmpeg turns it into a small WebM (VP8 picture, Opus sound: what the
game's browser plays), and the script cuts that into one-second pieces in the game's user folder
(temp/craptech_limotv/ch<N>/), which the TV reads and plays as they come: the picture on the screen, the sound from
the set (played by the game's UI, in step with the picture). Streams arrive in bursts (Twitch sends a few seconds at
a time), so the pieces are held back and written one per second, in step with the picture: the TV runs about 6 s
behind the stream (on top of Twitch's own delay). While this runs, the channel shows the stream (over its own
videos, if it has any); stop it with Ctrl+C and the channel goes back to its videos, or to "No video input".

    python craptech_limotv_live.py <twitch channel name | stream URL | video file> [--channel 2] [--quality ...]
                                   [--no-sound]

    python craptech_limotv_live.py monstercat              the Twitch channel twitch.tv/monstercat on channel 2
    python craptech_limotv_live.py some_streamer --channel 5
    python craptech_limotv_live.py C:/videos/clip.mp4      a video file, looping as if live (to test)

Needs Python 3.8+, streamlink and an ffmpeg (on the PATH, or the imageio-ffmpeg package):

    python -m pip install streamlink imageio-ffmpeg

When the stream goes offline, the script waits and tries again every 20 s until stopped.
"""
import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid

EBML = 0x1A45DFA3
SEGMENT = 0x18538067
INFO = 0x1549A966
TRACKS = 0x1654AE6B
TRACK_ENTRY = 0xAE
TRACK_NUMBER = 0xD7
TRACK_TYPE = 0x83
CLUSTER = 0x1F43B675
TIMECODE = 0xE7
SIMPLE_BLOCK = 0xA3
BLOCK_GROUP = 0xA0
BLOCK = 0xA1
KINDS = {1: 'video', 2: 'audio'}   # TrackType
KEEP = 15            # pieces (s) kept on disk behind the newest
RETRY = 20           # s between tries while the stream is offline
HOLD = 3.0           # s a piece is held back at least, so that the next burst comes before the pieces run out


def default_userfolder():
    return os.path.join(os.environ.get('LOCALAPPDATA', ''), 'BeamNG', 'BeamNG.drive', 'current')


def find_ffmpeg(given):
    if given:
        return given
    path = shutil.which('ffmpeg')
    if path:
        return path
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        sys.exit('ffmpeg not found: python -m pip install imageio-ffmpeg (or put ffmpeg on the PATH, or use --ffmpeg)')


def retry(fn, *args):
    """Windows refuses to replace or delete a file the game is reading at that instant: try again a moment later."""
    for _ in range(20):
        try:
            return fn(*args)
        except PermissionError:
            time.sleep(0.02)
    return fn(*args)


# --- WebM (EBML) reading: the header, then one Cluster per piece (ffmpeg's live WebM starts one on each keyframe,
# one a second here), the picture's and the sound's blocks interleaved in it

def read_exact(f, n):
    buf = b''
    while len(buf) < n:
        part = f.read(n - len(buf))
        if not part:
            raise EOFError
        buf += part
    return buf


def read_vint(f, is_id):
    first = read_exact(f, 1)
    n = 1
    while n <= 8 and not first[0] & (0x80 >> (n - 1)):
        n += 1
    if n > (4 if is_id else 8):
        raise ValueError('not a WebM stream')
    raw = first + read_exact(f, n - 1)
    value = int.from_bytes(raw, 'big')
    if is_id:
        return value, raw
    value &= (1 << (7 * n)) - 1
    return (None if value == (1 << (7 * n)) - 1 else value), raw


def read_element(f):
    eid, raw_id = read_vint(f, True)
    size, raw_size = read_vint(f, False)
    return eid, size, raw_id + raw_size


def parse_vint(b, i, is_id):
    n = 1
    while n <= 8 and not b[i] & (0x80 >> (n - 1)):
        n += 1
    value = int.from_bytes(b[i:i + n], 'big')
    return (value if is_id else value & ((1 << (7 * n)) - 1)), i + n


def cluster_time(cluster, start):
    """The cluster's timecode (ms; its first child, from `start`, the end of the cluster's own id and size)."""
    eid, i = parse_vint(cluster, start, True)
    size, i = parse_vint(cluster, i, False)
    return int.from_bytes(cluster[i:i + size], 'big') if eid == TIMECODE else None


def children(data, start, end):
    """The elements in data[start:end]: (id, where it starts, where its content starts, where it ends)."""
    i = start
    while i < end:
        eid, j = parse_vint(data, i, True)
        size, k = parse_vint(data, j, False)
        yield eid, i, k, k + size
        i = k + size


def content(el):
    """Where an element's content starts (after its id and size)."""
    _, j = parse_vint(el, 0, True)
    return parse_vint(el, j, False)[1]


def element(eid, payload):
    """An element, its size written on 8 bytes (any size fits)."""
    return eid.to_bytes((eid.bit_length() + 7) // 8, 'big') + b'\x01' + len(payload).to_bytes(7, 'big') + payload


def split_header(ebml, segment, items):
    """Per kind ('video', 'audio'): (track number, its init segment: the header with that track alone, what a
    MediaSource buffer of that kind takes; SeekHead, Void and Tags left out, their offsets no longer hold)."""
    info = b''.join(el for eid, el in items if eid == INFO)
    out = {}
    for tracks in (el for eid, el in items if eid == TRACKS):
        for eid, i, s, e in children(tracks, content(tracks), len(tracks)):
            if eid != TRACK_ENTRY:
                continue
            number = kind = None
            for cid, _, cs, ce in children(tracks, s, e):
                if cid == TRACK_NUMBER:
                    number = int.from_bytes(tracks[cs:ce], 'big')
                elif cid == TRACK_TYPE:
                    kind = KINDS.get(int.from_bytes(tracks[cs:ce], 'big'))
            if kind and number and kind not in out:
                out[kind] = (number, ebml + segment + info + element(TRACKS, tracks[i:e]))
    return out


def block_track(data, eid, s, e):
    """The track number of a SimpleBlock or BlockGroup (its content: data[s:e])."""
    if eid == BLOCK_GROUP:
        for cid, _, cs, _ in children(data, s, e):
            if cid == BLOCK:
                return parse_vint(data, cs, False)[0]
        return None
    return parse_vint(data, s, False)[0]


def split_cluster(cluster, numbers):
    """The cluster cut per kind ({kind: track number}): {kind: a cluster of its timecode and that track's blocks}."""
    kind_of = {number: kind for kind, number in numbers.items()}
    head, blocks = b'', {kind: [] for kind in numbers}
    for eid, i, s, e in children(cluster, content(cluster), len(cluster)):
        if eid in (SIMPLE_BLOCK, BLOCK_GROUP):
            kind = kind_of.get(block_track(cluster, eid, s, e))
            if kind:
                blocks[kind].append(cluster[i:e])
        elif eid == TIMECODE:
            head = cluster[i:e]
    return {kind: element(CLUSTER, head + b''.join(b)) for kind, b in blocks.items()}


# --- the files the TV reads: live.json (what is there), per track an init segment (init_<gen>.webm, the picture;
# init_<gen>_audio.webm, the sound) and a piece a second (<gen>_<n>.chunk, <gen>_<n>_audio.chunk)

class Output:
    def __init__(self, folder, title):
        self.folder = folder
        self.title = title
        os.makedirs(folder, exist_ok=True)
        self.clear()

    def path(self, name):
        return os.path.join(self.folder, name)

    def clear(self):
        for name in os.listdir(self.folder):
            if name == 'live.json' or name.endswith('.chunk') or name.startswith('init_'):
                try:
                    retry(os.remove, self.path(name))
                except OSError:
                    pass

    def write(self, name, data):
        tmp = self.path(name + '.tmp')
        with open(tmp, 'wb') as f:
            f.write(data)
        retry(os.replace, tmp, self.path(name))

    def name(self, kind, n=None):
        """A file of the stream: a track's init segment, or its piece n."""
        suffix = '' if kind == 'video' else '_' + kind
        return 'init_%s%s.webm' % (self.gen, suffix) if n is None else '%s_%d%s.chunk' % (self.gen, n, suffix)

    def start(self, ebml, segment, items):
        """A new stream (gen): each track's init segment, pieces numbered from 1. False if it has no picture."""
        self.clear()
        self.gen = uuid.uuid4().hex[:8]
        self.tracks = split_header(ebml, segment, items)
        if 'video' not in self.tracks:
            return False
        for kind, (_, init) in self.tracks.items():
            self.write(self.name(kind), init)
        self.last = 0
        return True

    def add(self, cluster):
        self.last += 1
        parts = split_cluster(cluster, {kind: number for kind, (number, _) in self.tracks.items()})
        for kind, data in parts.items():
            self.write(self.name(kind, self.last), data)
        old = self.last - KEEP
        if old >= 1:
            for kind in parts:
                try:
                    retry(os.remove, self.path(self.name(kind, old)))
                except OSError:
                    pass
        info = {'gen': self.gen, 'init': self.name('video'), 'first': max(1, self.last - KEEP + 1), 'last': self.last,
                'codec': 'vp8', 'audio': self.name('audio') if 'audio' in self.tracks else None, 'acodec': 'opus',
                'time': time.time(), 'title': self.title}
        self.write('live.json', json.dumps(info).encode())


# --- one run: source -> ffmpeg -> pieces, until the stream ends or fails

def source_args(source, quality):
    """(the command that writes the stream to stdout or None, ffmpeg's input arguments)"""
    if os.path.isfile(source):
        return None, ['-re', '-stream_loop', '-1', '-i', source]
    url = source if ('/' in source or '.' in source) else 'twitch.tv/' + source
    return [sys.executable, '-m', 'streamlink', '--stdout', '--loglevel', 'error', url, quality], ['-i', 'pipe:0']


def read_stream(f, pieces):
    """Reads ffmpeg's WebM: puts ('header', EBML element, Segment id and size, [(id, element) of the Segment's header
    part]) when the first cluster comes, then ('cluster', ms, element) per cluster, then None at the end."""
    try:
        eid, size, raw = read_element(f)
        if eid != EBML or size is None:
            raise ValueError('not a WebM stream')
        ebml = raw + read_exact(f, size)
        eid, size, raw = read_element(f)
        if eid != SEGMENT:
            raise ValueError('no WebM segment')
        segment, items = raw, []
        started = False
        while True:
            eid, size, raw = read_element(f)
            if size is None:
                raise ValueError('WebM element of unknown size')
            data = raw + read_exact(f, size)
            if eid == CLUSTER:
                if not started:
                    pieces.put(('header', ebml, segment, items))
                    started = True
                pieces.put(('cluster', cluster_time(data, len(raw)), data))
            elif not started:
                items.append((eid, data))
    except EOFError:
        pass
    except ValueError as e:
        print('Bad video from ffmpeg: %s' % e, flush=True)
    finally:
        pieces.put(None)


def run_once(args, ffmpeg, out):
    src_cmd, ff_input = source_args(args.source, args.quality)
    # the sound (if the stream has any): Opus, gaps filled with silence so that it stays in step with the picture
    sound = ['-an'] if args.no_sound else ['-map', '0:a:0?', '-af', 'aresample=async=1', '-c:a', 'libopus',
                                           '-b:a', '96k', '-ac', '2', '-ar', '48000']
    # live WebM: a new cluster on each keyframe (once the current one holds over 4 KiB), so one a second
    ff_cmd = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-fflags', '+discardcorrupt'] + ff_input + [
        '-map', '0:v:0'] + sound + ['-sn', '-dn',
        '-vf', 'scale=%d:-2,fps=30' % args.width,
        '-c:v', 'libvpx', '-deadline', 'realtime', '-cpu-used', '8', '-b:v', args.bitrate,
        '-g', '30', '-keyint_min', '30',
        '-f', 'webm', '-live', '1', '-cluster_size_limit', '10000000', '-cluster_time_limit', '10000', 'pipe:1']
    procs = []
    try:
        if src_cmd:
            src = subprocess.Popen(src_cmd, stdout=subprocess.PIPE)
            procs.append(src)
            ff = subprocess.Popen(ff_cmd, stdin=src.stdout, stdout=subprocess.PIPE)
            src.stdout.close()   # ffmpeg owns the pipe now
        else:
            ff = subprocess.Popen(ff_cmd, stdout=subprocess.PIPE)
        procs.append(ff)

        # written in step with the picture: piece at stream time t (s) goes out at t0 + t, t0 set by the first
        # piece plus HOLD, and moved on whenever a piece comes too late for its time
        pieces = queue.Queue()
        threading.Thread(target=read_stream, args=(ff.stdout, pieces), daemon=True).start()
        t0 = None
        while True:
            try:
                item = pieces.get(timeout=0.5)   # a wait Ctrl+C can break on Windows
            except queue.Empty:
                continue
            if item is None:
                break
            if item[0] == 'header':
                if not out.start(*item[1:]):
                    print('No picture in the stream', flush=True)
                    break
                t0 = None
                continue
            _, ms, data = item
            t = (ms or 0) / 1000.0
            now = time.time()
            if t0 is None:
                t0 = now + HOLD - t
                print('On the air: channel %d in %.0f s (Ctrl+C to stop)' % (args.channel, HOLD), flush=True)
            elif t0 + t < now:
                t0 = now - t
            time.sleep(max(0.0, t0 + t - now))
            out.add(data)
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
        for p in procs:
            p.wait()


def main():
    ap = argparse.ArgumentParser(description='Feeds a live stream to a channel of the Crapouille limo TV.')
    ap.add_argument('source', help='a Twitch channel name, a stream URL (anything streamlink knows) or a video file')
    ap.add_argument('--channel', type=int, default=2, help='TV channel, 1..9 (default 2)')
    ap.add_argument('--quality', default='480p,480p30,360p,360p30,worst',
                    help='streamlink quality, best first (default 480p,480p30,360p,360p30,worst)')
    ap.add_argument('--width', type=int, default=640, help='picture width (default 640, the screen\'s)')
    ap.add_argument('--bitrate', default='1200k', help='video bitrate (default 1200k)')
    ap.add_argument('--no-sound', action='store_true', help='the picture only')
    ap.add_argument('--userfolder', default=default_userfolder(),
                    help='the BeamNG user folder (default %%LOCALAPPDATA%%/BeamNG/BeamNG.drive/current)')
    ap.add_argument('--ffmpeg', help='the ffmpeg to use (default: on the PATH, else imageio-ffmpeg\'s)')
    args = ap.parse_args()
    if not 1 <= args.channel <= 9:
        ap.error('--channel: 1..9')
    if not os.path.isdir(args.userfolder):
        ap.error('BeamNG user folder not found: %s (use --userfolder)' % args.userfolder)
    if not os.path.isfile(args.source):
        try:
            import streamlink  # noqa: F401
        except ImportError:
            sys.exit('streamlink is missing: python -m pip install streamlink')
    ffmpeg = find_ffmpeg(args.ffmpeg)

    folder = os.path.join(args.userfolder, 'temp', 'craptech_limotv', 'ch%d' % args.channel)
    out = Output(folder, args.source)
    print('Limo TV channel %d <- %s' % (args.channel, args.source), flush=True)
    try:
        while True:
            t0 = time.time()
            run_once(args, ffmpeg, out)
            out.clear()
            if time.time() - t0 < 5:
                print('No stream (offline?); trying again in %d s' % RETRY, flush=True)
            else:
                print('The stream stopped; trying again in %d s' % RETRY, flush=True)
            time.sleep(RETRY)
    except KeyboardInterrupt:
        pass
    finally:
        out.clear()
        print('Off the air.', flush=True)


if __name__ == '__main__':
    main()
