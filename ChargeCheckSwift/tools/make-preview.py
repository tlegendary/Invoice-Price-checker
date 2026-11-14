#!/usr/bin/env python3
"""Joins the clips the cloud job "store" records into an App Store app preview: 886 x 1920 (iPhone 6.9"/6.5"),
30 fps H.264, silent stereo AAC, about 24 seconds (Apple allows 15-30). Only real footage of the app is used: the
blank launch screens are cut, the "Reading invoice" wait is sped up 3x, each screen is held so it can be read, and
the screens fade into each other.

    python3 make-preview.py CLIP_FOLDER OUTPUT.mp4

The start times below come from the clips' brightness (when the launch screen gives way to the app); check them
with a contact sheet if the clips change.
"""
import subprocess
import sys

HOLD = 4.5
FADE = 0.4
# (clip, from second, to second or None = end, speed-up, hold the last frame until this long)
SEGMENTS = [
    ("2-home", 3.0, None, 1, HOLD),
    ("1-scan", 3.0, 11.0, 3, None),   # reading and double-checking, three times faster
    ("1-scan", 11.0, None, 1, HOLD),  # the result
    ("3-suppliers", 2.5, None, 1, HOLD),
    ("4-credit", 3.0, None, 1, HOLD),
    ("5-rises", 3.5, None, 1, HOLD),
]


def main(folder, output):
    inputs, filters, lengths = [], [], []
    for index, (clip, start, end, speed, hold) in enumerate(SEGMENTS):
        inputs += ["-i", f"{folder}/clip-{clip}.mov"]
        chain = f"[{index}:v]trim=start={start}" + (f":end={end}" if end else "") + ",setpts=PTS-STARTPTS"
        if speed != 1:
            chain += f",setpts=PTS/{speed}"
        chain += ",fps=30,scale=886:1925:flags=lanczos,crop=886:1920:0:0,format=yuv420p"
        if hold:
            chain += f",tpad=stop_mode=clone:stop_duration={hold},trim=duration={hold},setpts=PTS-STARTPTS"
            lengths.append(hold)
        else:
            lengths.append((end - start) / speed)
        filters.append(chain + f",fps=30,settb=1/30[s{index}]")
    # the reading part runs straight into its result; every other change of screen fades
    filters.append("[s1][s2]concat=n=2:v=1:a=0,fps=30,settb=1/30[scan]")
    parts = ["s0", "scan", "s3", "s4", "s5"]
    durations = [lengths[0], lengths[1] + lengths[2], lengths[3], lengths[4], lengths[5]]
    current, total = parts[0], durations[0]
    for n, (part, length) in enumerate(zip(parts[1:], durations[1:]), start=1):
        out = f"x{n}"
        filters.append(f"[{current}][{part}]xfade=transition=fade:duration={FADE}:offset={total - FADE:.3f}[{out}]")
        current, total = out, total + length - FADE
    filters.append(f"[{current}]null[v]")
    command = ["ffmpeg", "-y", "-v", "error", *inputs,
               "-f", "lavfi", "-t", f"{total:.3f}", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
               "-filter_complex", ";".join(filters), "-map", "[v]", "-map", f"{len(SEGMENTS)}:a",
               "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "18", "-maxrate", "10M", "-bufsize", "20M",
               "-r", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", output]
    subprocess.run(command, check=True)
    print(f"{output}: about {total:.1f} s")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
