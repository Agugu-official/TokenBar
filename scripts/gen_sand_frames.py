#!/usr/bin/env python3
"""Generate the "sand" menu-bar animation frames (48x48, looping).

A small shoal after the landing page's sand animation
(landing/src/components/Hero.astro): a smooth dune whose crest drifts side
to side, with fine grains falling onto it. Every moving part has a period
that divides FRAMES, so the sequence loops without a seam. The frames are
drawn for one playback rate (FPS); TrayAnimator plays every level at that
rate and shows usage by choosing the level, not by speeding the loop up.

Monochrome like the cat and parrot (white on a dark menu bar, black on a
light one). Two looks were rejected by the maintainer at menu-bar size: a
sand colour, and horizontal depth bands; both read as something else. The
dune is one tone with a fine, irregular grain texture instead.

Levels: the amount of falling sand follows tokens/min. Each level is its own
frame set, played at one fixed rate; a busier minute means more sand, not a
faster loop. Lifted grains scale with the fall, so the volume still returns
to where it started.

Usage: gen_sand_frames.py <out-dark> <out-light> <falling> <crest-scale> <base-h> <swing-px>
"""
import math, os, random, sys
from PIL import Image

SIZE = 48           # frame edge in px (drawn at 16 pt, 3x)
FPS = 24            # playback rate the frames are drawn for
LOOP_SECONDS = 6    # one loop, whatever the rate
FRAMES = FPS * LOOP_SECONDS
# Motion is defined per second and divided by FPS, so a higher rate draws
# the same movement in finer steps instead of playing it faster.
# Per level (overridden from the command line): the dune's base height, how
# much the current swings the crest, and how far accumulation and erosion move
# the height. A quiet level is a small, still dune; a busy one is larger,
# more restless, and gains and loses more.
BASE_H = 16.0       # crest height in px at the level's lowest volume
CREST_SCALE = 1.0   # multiplier on CREST_WAVES amplitudes
SWING_PX = 7.0      # height range from accumulation vs erosion
SIGMA = 11.0        # dune half-width in px
# Crest position: a sum of harmonics with different periods and phases,
# so it wanders irregularly instead of swinging like a pendulum. Each period
# divides FRAMES, so the loop still closes. (cycles per loop, amplitude px, phase)
# Rounds 11 and 12: amplitudes x1.8 then x1.6, because at menu-bar size the
# first swing was too small to see.
CREST_WAVES = [(1, 6.4, 0.0), (2, 2.6, 1.9), (3, 1.8, 4.1)]
FALLING = 22        # grains in the air (overridden per level)
GRAIN = 2           # falling grain edge in px
FALL_SPEED = 40 / FPS  # px per frame (40 px/s); FALL_SPEED * FRAMES is a multiple of SIZE, so the loop closes
TEXTURE = (170, 255)  # per-pixel alpha range inside the dune
INK = {"dark": (255, 255, 255), "light": (0, 0, 0)}
# The current: grains lifted off the dune's downstream face and carried
# sideways, fading as they go, like the page's `lift()` / `drift`. The flow
# follows the crest's swing, so it runs one way for half the loop and back.
DRIFTERS = 54       # lifted grains per loop, spread over the frames
DRIFT_LIFE = FPS    # frames a lifted grain stays visible (1 s)
DRIFT_VX = 19.2 / FPS  # px per frame sideways (19.2 px/s)
DRIFT_RISE = 4.2 / FPS  # px per frame upward (4.2 px/s)
DRIFT_ALPHA = 200   # starting alpha, fading linearly to 0

def crest(f):
    t = 2 * math.pi * f / FRAMES
    return (SIZE - 1) / 2 + CREST_SCALE * sum(a * math.sin(k * t + p) for k, a, p in CREST_WAVES)

def flow(f):
    """+1 while the crest moves right, -1 while it moves left."""
    return 1 if crest(f + 1) >= crest(f) else -1

# The current also pulses faster than the crest swings (PULSE_CYCLES per
# loop), so the dune gains and loses sand several times a loop while the crest
# still wanders slowly.
PULSE_CYCLES = 6
PULSE_DEPTH = 0.85

def erosion(f):
    """How much the current carries off in frame f: proportional to how far
    the crest moves, so a restless dune loses sand and a calm one keeps it,
    modulated by a faster pulse."""
    pulse = 1 + PULSE_DEPTH * math.sin(2 * math.pi * PULSE_CYCLES * f / FRAMES + 0.7)
    return abs(crest(f + 1) - crest(f)) * pulse

def _heights():
    # Sand falls at a steady rate and the current removes `erosion(f)`.
    # The fall rate equals the mean erosion, so the volume returns to where it
    # started and the loop closes. The volume is then scaled to the crest
    # height range.
    fall = sum(erosion(f) for f in range(FRAMES)) / FRAMES
    v, vols = 0.0, []
    for f in range(FRAMES):
        vols.append(v)
        v += fall - erosion(f)
    lo, hi = min(vols), max(vols)
    return [BASE_H + (x - lo) / ((hi - lo) or 1) * SWING_PX for x in vols]

HEIGHTS = None

def surface(x, f):
    global HEIGHTS
    if HEIGHTS is None:
        HEIGHTS = _heights()
    return HEIGHTS[f % FRAMES] * math.exp(-((x - crest(f)) / SIGMA) ** 2)

def splat_square(buf, x, y, a, size):
    """A size x size grain at a fractional position, built from 1 px splats."""
    for dx in range(size):
        for dy in range(size):
            splat(buf, x + dx, y + dy, a)

def splat(buf, x, y, a):
    """Draw a 1 px grain at a fractional position by spreading its alpha over
    the four pixels it overlaps. Rounding to whole pixels made sub-pixel speeds
    advance in uneven steps (0, 1, 2, 2, 3...), which read as jitter."""
    x0, y0 = math.floor(x), math.floor(y)
    fx, fy = x - x0, y - y0
    for dx, dy, w in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                      (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        xi, yi = x0 + dx, y0 + dy
        if 0 <= xi < SIZE and 0 <= yi < SIZE:
            buf[yi][xi] = max(buf[yi][xi], a * w)

def main(dark_dir, light_dir):
    rnd = random.Random(11)
    # Grain texture as a gain per (column, depth). It is sampled at the
    # column's position relative to the crest, interpolated between columns,
    # so it travels smoothly with the dune. Sampling it in screen space made
    # every edge pixel change brightness as the dune moved.
    texture = [[rnd.uniform(TEXTURE[0] / 255, 1.0) for _ in range(SIZE)] for _ in range(SIZE * 2)]
    grains = []
    for _ in range(FALLING):
        x = (SIZE - 1) / 2 + rnd.gauss(0, SIGMA * 0.55)
        grains.append((min(SIZE - 1.0, max(0.0, x)), rnd.uniform(0, SIZE), rnd.randint(110, 190)))
    # Scale lifted grains with the fall so a heavy level erodes as much as it
    # gains.
    drifter_count = max(1, round(DRIFTERS * FALLING / 22))
    # Lifted grains are spawned where the current is strong: frames are
    # sampled in proportion to their erosion.
    weights = [erosion(f) for f in range(FRAMES)]
    starts = sorted(rnd.choices(range(FRAMES), weights=weights, k=drifter_count))
    drifters = []
    for start in starts:
        # Lift point: on the downstream side of the crest at spawn time.
        offset = abs(rnd.gauss(SIGMA * 0.45, SIGMA * 0.3))
        drifters.append((start, offset, rnd.uniform(0.8, 1.2)))
    centre0 = crest(0)
    for name, out in (("dark", dark_dir), ("light", light_dir)):
        ink = INK[name]
        os.makedirs(out, exist_ok=True)
        for f in range(FRAMES):
            buf = [[0.0] * SIZE for _ in range(SIZE)]
            shift = crest(f) - centre0
            for x in range(SIZE):
                h = surface(x + 0.5, f)
                u = (x - shift) % SIZE
                u0 = int(u) % SIZE
                u1 = (u0 + 1) % SIZE
                fu = u - int(u)
                for d in range(int(h) + 1):
                    y = SIZE - 1 - d
                    if y < 0:
                        break
                    cover = min(1.0, max(0.0, h - d))   # smooth crest edge
                    tex = texture[d][u0] * (1 - fu) + texture[d][u1] * fu
                    buf[y][x] = max(buf[y][x], 255 * cover * tex)
            for (x, phase, a) in grains:
                y = (phase + f * FALL_SPEED) % SIZE
                if y + GRAIN <= SIZE - surface(x + GRAIN / 2, f):
                    splat_square(buf, x, y, a, GRAIN)
            for (start, offset, speed) in drifters:
                age = (f - start) % FRAMES
                if age >= DRIFT_LIFE:
                    continue
                d = flow(start)
                x0 = crest(start) + d * offset
                y0 = SIZE - surface(x0, start) - 1
                splat(buf, x0 + d * DRIFT_VX * speed * age, y0 - DRIFT_RISE * age,
                      DRIFT_ALPHA * (1 - age / DRIFT_LIFE))
            img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
            px = img.load()
            for y in range(SIZE):
                for x in range(SIZE):
                    a = int(round(buf[y][x]))
                    if a > 0:
                        px[x, y] = ink + (min(255, a),)
            # Three digits: the app orders frames by file name, and
            # "frame-100" sorts before "frame-11" with two.
            img.save(os.path.join(out, f"frame-{f:03d}.png"))

if __name__ == "__main__":
    if len(sys.argv) not in (3, 7):
        sys.exit(__doc__.strip().splitlines()[-1])
    if len(sys.argv) == 7:
        FALLING = int(sys.argv[3])
        CREST_SCALE = float(sys.argv[4])
        BASE_H = float(sys.argv[5])
        SWING_PX = float(sys.argv[6])
    main(sys.argv[1], sys.argv[2])
