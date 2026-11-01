Crapouille limo TV - channel folders
====================================

Each folder ch1 .. ch9 is one channel of the TV in the limo bar (part "Interior Lights &
Wiring (Crapouille)"). Put video files in a channel's folder: they play one after another,
in name order, looping, with their sound. A channel with no video shows "No video input".

Format: WebM only (.webm, VP8 / VP9 / AV1 video, Opus or Vorbis sound). The game's built-in
browser cannot play MP4, MOV, AVI or MKV files: convert them first, for example with ffmpeg:

    ffmpeg -i input.mp4 -vf "scale=640:-2,fps=30" -c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -g 30 -c:a libopus -b:a 96k output.webm

(add -an before output.webm for a silent one). 640 pixels wide is plenty for the screen;
small files keep the mod light (everyone who downloads the mod, e.g. on a BeamMP server,
downloads the videos too). -g 30 puts a key frame every second, so the TV can jump quickly
into the middle of a video (the channels run "live": switching back to one finds it further
on).

The screen is 4:3: a 16:9 video shows whole, with black bars above and below.

The TV loads the video it shows whole into memory (twice: picture and sound), so split very
long ones (more than half an hour or so).

Keep the original MP4s elsewhere: the TV ignores them, but they would be packed and
downloaded with the mod.

The TV reads the folders when the car loads and each time it is switched on: after adding
videos, press POWER twice (or Ctrl+R).

Sound
-----
The game's browser can't play sound on a screen texture, so the game's UI plays it, in step
with the picture, as if from the set: full volume close to it, fading with distance, from
its side, muffled from outside the car, times the game's master volume. VL up / VL down on
the set (or Controls) set its volume, shown along the bottom of the screen. The UI may only
play sound once you've clicked in it (anything, e.g. the main menu) since the game started.

Live stream (Twitch...)
-----------------------
The game has no network access, so a Python script outside it does the fetching. Once:

    python -m pip install streamlink imageio-ffmpeg

Then, while you want the stream on (a console window stays open; Ctrl+C stops it):

    python ..\craptech_limotv_live.py <twitch channel name> --channel 2

It writes the stream into BeamNG's user folder (temp/craptech_limotv/ch2), not here. While
it runs, that channel shows the stream, about 6 s behind Twitch, over the channel's own
videos; stopped, the channel goes back to its videos or "No video input". A stream URL
(anything streamlink knows) or a video file (looping, to test) works too. The stream comes
with its sound (--no-sound for the picture only).
