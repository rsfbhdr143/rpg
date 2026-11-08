"""Звуковые эффекты и фоновые петли: синтез на numpy, тональные звуки через FluidSynth.

Каждая функция возвращает массив (моно для звуков, стерео для фоновых петель).
Громкость выравнивается в build.py, здесь важны только тембр и форма.
"""

import os
import tempfile

import numpy as np

import dsp
from dsp import (SR, bell, bp, brown, crackle, drive, env_ar, env_exp, env_points, formant,
                 glide, hp, karplus, lp, noise, osc, place, place_wrap, resonators, reverb, sweep,
                 tt)
from musiclib import Song, render_midi, voicing


def R(seed):
    return np.random.default_rng(seed)


def zeros(dur):
    return np.zeros(int(dur * SR))


def norm(x):
    return x / (np.max(np.abs(x)) + 1e-9)


def mono_verb(x, rng, time=0.6, mix=0.15, damp=6000):
    return reverb(x, rng, time=time, mix=mix, damp=damp, stereo=False)


def fit(x, dur):
    """Обрезать или дополнить тишиной до dur секунд."""
    n = int(dur * SR)
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x))])


def midi_sfx(build, end_beat, bpm=120, tail=2.5):
    """Короткий тональный звук через FluidSynth. build(song) заполняет дорожки."""
    s = Song("sfx", bpm, 4, seed=5)
    build(s)
    with tempfile.TemporaryDirectory() as tmp:
        mid = os.path.join(tmp, "s.mid")
        wav = os.path.join(tmp, "s.wav")
        s.write_midi(mid, end_beat, tail)
        audio = render_midi(mid, wav, gain=0.6)
    return audio.mean(axis=1).astype(np.float64)


# --- Оружие и тела ------------------------------------------------------------

def whoosh(seed, dur=0.32, f0=350, f1=1900, f2=500, q=1.3):
    rng = R(seed)
    n = int(dur * SR)
    peak = int(n * rng.uniform(0.5, 0.65))
    freqs = np.concatenate([np.geomspace(f0, f1, peak), np.geomspace(f1, f2, n - peak)])
    x = sweep(noise(dur, rng), "bp", freqs, q=q)
    env = np.concatenate([np.linspace(0, 1, peak) ** 2, np.linspace(1, 0, n - peak) ** 1.5])
    return lp(x * env, 6000)


def slash(seed):
    rng = R(seed)
    x = whoosh(seed, 0.24, 500, 2600, 900, q=1.6)
    shing = hp(noise(0.3, rng), 4500) * env_exp(0.3, 0.07)
    ring = sum(np.sin(2 * np.pi * f * rng.uniform(0.97, 1.03) * tt(0.3)) for f in (3150, 4720, 6310))
    ring = ring * env_exp(0.3, 0.12) * 0.12
    out = zeros(0.5)
    place(out, x, 0)
    place(out, shing * 0.5 + ring, 0.13)
    return out


def melee_hit(seed):
    rng = R(seed)
    d = 0.5
    thump = osc(glide(rng.uniform(110, 140), 50, 0.14), shape="sine") * env_exp(0.14, 0.06)
    crack = bp(noise(d, rng), 700, 3500) * env_exp(d, 0.014)
    body = lp(noise(d, rng), 900) * env_exp(d, 0.05)
    metal = sum(np.sin(2 * np.pi * f * rng.uniform(0.9, 1.1) * tt(d)) for f in (1180, 2650, 3970))
    metal = metal * env_exp(d, 0.07) * 0.03
    out = zeros(d)
    place(out, thump * 1.0, 0)
    out += crack * 0.9 + body * 0.8 + metal
    return mono_verb(drive(out * 1.4, 2.0), rng, 0.4, 0.1)


def melee_crit(seed=40):
    rng = R(seed)
    d = 1.1
    out = fit(melee_hit(seed + 1) * 1.1, d)
    boom = osc(glide(75, 38, 0.4), shape="sine") * env_exp(0.4, 0.17)
    place(out, boom * 0.9, 0)
    clang = sum(a * np.sin(2 * np.pi * f * tt(d)) * env_exp(d, tau)
                for f, a, tau in ((820, 0.5, 0.35), (1940, 0.4, 0.25), (3110, 0.3, 0.2), (4570, 0.2, 0.15)))
    out += clang * 0.35
    out += hp(noise(d, rng), 5000) * env_exp(d, 0.18) * 0.3
    return mono_verb(drive(out, 1.6), rng, 0.9, 0.2)


def melee_miss(seed):
    return whoosh(seed, 0.3 + 0.05 * (seed % 2), 300, 1500 + 200 * (seed % 3), 450, q=1.0) * 0.8


def bow_shot(seed=50):
    rng = R(seed)
    twang = karplus(98, 0.4, rng, decay=0.993, bright=0.65)
    twang = lp(twang, 3000) * env_exp(0.4, 0.12)
    thump = osc(glide(160, 80, 0.06), shape="sine") * env_exp(0.06, 0.02)
    air = whoosh(seed + 1, 0.28, 1800, 5200, 2600, q=1.5) * 0.6
    out = zeros(0.6)
    place(out, twang, 0)
    place(out, thump * 0.6, 0)
    place(out, air, 0.02)
    return mono_verb(out, rng, 0.5, 0.1)


def arrow_hit(seed=51):
    rng = R(seed)
    click = np.zeros(int(0.3 * SR))
    click[:30] = rng.normal(0, 1, 30)
    wood = resonators(click, [240, 520, 1150, 2300], q=10, gains=[1.0, 0.7, 0.4, 0.2])
    burst = lp(noise(0.3, rng), 2500) * env_exp(0.3, 0.012)
    vib = np.sin(2 * np.pi * 180 * tt(0.3)) * (0.5 + 0.5 * np.sin(2 * np.pi * 32 * tt(0.3)))
    vib = vib * env_exp(0.3, 0.07) * 0.25
    return mono_verb(norm(wood) * 0.9 + burst * 0.8 + vib, rng, 0.35, 0.1)


def voice(f0, dur, vowel_a, vowel_b, rng, rough=0.0, scale=1.0, breath=0.15, vib=(5.0, 0.01)):
    """Голосоподобный звук: пила с вибрато через форманты гласной."""
    if np.isscalar(f0):
        f0 = np.full(int(dur * SR), float(f0))
    t = np.arange(len(f0)) / SR
    f = f0 * (1 + vib[1] * np.sin(2 * np.pi * vib[0] * t))
    src = osc(f, shape="saw")
    if rough:
        src *= 1 + rough * lp(rng.normal(0, 1, len(src)), 120) * 3
    src += bp(rng.normal(0, 1, len(src)), 600, 3500) * breath
    return formant(src, vowel_a, vowel_b, scale=scale)


def hurt(seed):
    rng = R(seed)
    d = 0.4
    impact = lp(noise(d, rng), 600) * env_exp(d, 0.035) + osc(glide(95, 55, d), shape="sine") * env_exp(d, 0.07)
    f0 = rng.uniform(150, 185)
    grunt = voice(glide(f0, f0 * 0.72, 0.24), 0.24, "a", "o", rng, rough=0.4, breath=0.25)
    grunt = grunt * env_ar(0.24, 0.012, 0.12)
    out = zeros(d)
    out += impact * 0.9
    place(out, norm(grunt) * 0.55, 0.015)
    return mono_verb(drive(out, 1.4), rng, 0.4, 0.1)


def death(seed=60):
    rng = R(seed)
    d = 1.6
    groan = voice(glide(150, 78, 0.8, curve=0.7), 0.8, "a", "u", rng, rough=0.5, breath=0.3)
    groan = norm(groan) * env_ar(0.8, 0.03, 0.4)
    fall = lp(noise(0.5, rng), 500) * env_exp(0.5, 0.06) + osc(glide(80, 45, 0.5), shape="sine") * env_exp(0.5, 0.1)
    rattle = crackle(0.3, rng, density=120, lo=2500, hi=8000) * env_exp(0.3, 0.08)
    out = zeros(d)
    place(out, groan * 0.6, 0)
    place(out, norm(fall), 0.62)
    place(out, norm(rattle) * 0.3, 0.64)
    return mono_verb(out, rng, 0.9, 0.18)


def enemy_death(seed=61):
    rng = R(seed)
    d = 1.4
    growl = voice(glide(95, 50, 0.7), 0.7, "o", "u", rng, rough=1.0, breath=0.4, vib=(9.0, 0.03))
    growl = norm(growl) * env_ar(0.7, 0.02, 0.4)
    n = int(0.9 * SR)
    crumble = crackle(0.9, rng, density=220, lo=300, hi=4000) * np.linspace(1, 0, n) ** 2
    thud = lp(noise(0.4, rng), 400) * env_exp(0.4, 0.07) + osc(glide(70, 40, 0.4), shape="sine") * env_exp(0.4, 0.1)
    out = zeros(d)
    place(out, drive(growl * 1.5, 2.0) * 0.6, 0)
    place(out, norm(crumble) * 0.5, 0.35)
    place(out, norm(thud) * 0.8, 0.5)
    return mono_verb(out, rng, 0.8, 0.18)


def bone_crunch(seed=62):
    rng = R(seed)
    d = 0.5
    n = int(0.28 * SR)
    snaps = crackle(0.28, rng, density=320, lo=1200, hi=7000, decay=0.002) * np.linspace(1, 0.1, n)
    crack = hp(noise(0.05, rng), 1500) * env_exp(0.05, 0.006)
    knock = resonators(np.r_[rng.normal(0, 1, 40), np.zeros(int(0.2 * SR))], [300, 720, 1500], q=8)
    out = zeros(d)
    place(out, norm(crack), 0)
    place(out, norm(snaps) * 0.8, 0.01)
    place(out, norm(knock) * 0.5, 0)
    return mono_verb(drive(out, 1.5), rng, 0.3, 0.08)


# --- Стихии -------------------------------------------------------------------

def bubbles(dur, rng, count, lo=400, hi=1500, length=(0.02, 0.05), rise=1.6):
    out = zeros(dur)
    for _ in range(count):
        ln = rng.uniform(*length)
        f = rng.uniform(lo, hi)
        b = np.sin(2 * np.pi * np.cumsum(glide(f, f * rise, ln)) / SR) * env_ar(ln, 0.003, ln * 0.8, 1.0)
        place(out, b * rng.uniform(0.3, 1.0), rng.uniform(0, dur - ln))
    return out


def fire_cast(seed=70):
    rng = R(seed)
    d = 1.0
    roar = sweep(noise(d, rng), "lp", (350, 4500), q=0.8) * env_points(d, [(0, 0), (0.25, 1), (0.55, 0.8), (1.0, 0)])
    fwoom = osc(glide(80, 170, d), shape="sine") * env_points(d, [(0, 0), (0.2, 1), (1.0, 0)])
    crk = crackle(d, rng, density=70) * env_points(d, [(0, 0), (0.3, 1), (1.0, 0.2)])
    return mono_verb(norm(roar) * 0.9 + fwoom * 0.5 + norm(crk) * 0.35, rng, 0.6, 0.12)


def fire_impact(seed=71):
    rng = R(seed)
    d = 1.4
    burst = lp(noise(d, rng), 3000) * env_exp(d, 0.3, attack=0.006)
    boom = osc(glide(65, 35, d), shape="sine") * env_exp(d, 0.22)
    crk = crackle(d, rng, density=140) * np.linspace(1, 0, int(d * SR)) ** 1.5
    return mono_verb(drive(norm(burst) + boom * 0.8 + norm(crk) * 0.4, 1.5), rng, 0.8, 0.15)


def explosion(seed=72):
    rng = R(seed)
    d = 2.4
    body = lp(noise(d, rng) * 0.6 + brown(d, rng), 1600) * env_exp(d, 0.55, attack=0.004)
    boom = osc(glide(58, 28, d), shape="sine") * env_exp(d, 0.45)
    snap = hp(noise(0.03, rng), 2000) * env_exp(0.03, 0.005)
    debris = crackle(1.8, rng, density=160, lo=800, hi=6000) * np.linspace(1, 0, int(1.8 * SR)) ** 2
    out = norm(body) + boom * 1.1
    place(out, norm(snap) * 0.8, 0)
    place(out, norm(debris) * 0.4, 0.08)
    return reverb(drive(out, 2.5), rng, time=1.6, mix=0.25, stereo=False)


def water_cast(seed=73):
    rng = R(seed)
    d = 1.0
    n = int(d * SR)
    freqs = np.concatenate([np.geomspace(300, 1200, n // 2), np.geomspace(1200, 500, n - n // 2)])
    swirl = sweep(noise(d, rng), "bp", freqs, q=3.0) * env_points(d, [(0, 0), (0.3, 1), (0.7, 0.8), (1.0, 0)])
    bub = bubbles(d, rng, 30, 400, 1500)
    return mono_verb(norm(swirl) * 0.8 + norm(bub) * 0.6, rng, 0.6, 0.15)


def water_impact(seed=74):
    rng = R(seed)
    d = 1.1
    splash = bp(noise(d, rng), 400, 5000) * env_exp(d, 0.17, attack=0.004)
    plop = osc(glide(190, 90, 0.12), shape="sine") * env_exp(0.12, 0.05)
    bub = bubbles(0.7, rng, 16, 500, 1800)
    drops = bubbles(0.8, rng, 10, 2000, 4000, length=(0.008, 0.02), rise=1.3)
    out = norm(splash)
    place(out, plop * 0.8, 0)
    place(out, norm(bub) * 0.4, 0.15)
    place(out, norm(drops) * 0.25, 0.2)
    return mono_verb(out, rng, 0.6, 0.15)


def potion(seed=75):
    rng = R(seed)
    d = 1.5
    out = zeros(d)
    pop = osc(glide(700, 300, 0.05), shape="sine") * env_exp(0.05, 0.012) + bp(noise(0.05, rng), 1000, 5000) * env_exp(0.05, 0.004)
    place(out, pop, 0)
    for i, at in enumerate((0.3, 0.58, 0.86)):
        g = voice(glide(190 - 15 * i, 120, 0.18), 0.18, "o", "u", rng, breath=0.1) * env_ar(0.18, 0.02, 0.1)
        g += bubbles(0.18, rng, 3, 150, 300, length=(0.04, 0.08), rise=1.8)
        place(out, norm(g) * 0.7, at)
    sparkle = sum(np.sin(2 * np.pi * f * tt(0.5)) * env_exp(0.5, 0.15) for f in (1760, 2217, 2637))
    place(out, sparkle * 0.12, 1.05)
    return mono_verb(out, rng, 0.5, 0.12)


def ice_cast(seed=76):
    rng = R(seed)
    d = 1.1
    out = zeros(d)
    for _ in range(14):
        f = rng.uniform(2500, 7000)
        ping = np.sin(2 * np.pi * f * tt(0.4)) * env_exp(0.4, rng.uniform(0.08, 0.25))
        place(out, ping * rng.uniform(0.2, 0.6), rng.uniform(0, 0.6))
    air = hp(noise(d, rng), 3000) * env_points(d, [(0, 0), (0.35, 1), (1.1, 0)])
    chord = sum(np.sin(2 * np.pi * f * tt(d)) for f in (1175, 1760, 2637)) * env_points(d, [(0, 0), (0.4, 1), (1.1, 0)])
    chord *= 1 + 0.3 * np.sin(2 * np.pi * 7 * tt(d))
    out = norm(out) * 0.6 + norm(air) * 0.4 + chord * 0.1
    return mono_verb(out, rng, 1.0, 0.25, damp=9000)


def ice_impact(seed=77):
    rng = R(seed)
    d = 0.9
    out = zeros(d)
    crack = hp(noise(0.04, rng), 1500) * env_exp(0.04, 0.008)
    place(out, crack, 0)
    for k in range(70):
        at = rng.exponential(0.1)
        if at > d - 0.05:
            continue
        f = rng.uniform(3000, 9500)
        ln = rng.uniform(0.005, 0.04)
        shard = np.sin(2 * np.pi * f * tt(ln)) * env_exp(ln, ln / 3)
        place(out, shard * rng.uniform(0.2, 0.7), at)
    thud = lp(noise(0.2, rng), 500) * env_exp(0.2, 0.03)
    place(out, thud * 0.5, 0)
    return mono_verb(out, rng, 0.7, 0.18, damp=9000)


def freeze(seed=78):
    rng = R(seed)
    d = 1.2
    n = int(0.9 * SR)
    crk = crackle(0.9, rng, density=180, lo=2000, hi=9000) * np.linspace(0.1, 1, n) ** 1.5
    tone = osc(glide(1200, 2400, 0.9), shape="sine") * env_points(0.9, [(0, 0), (0.8, 1), (0.9, 0)])
    out = zeros(d)
    place(out, norm(crk) * 0.7 + tone * 0.12, 0)
    place(out, ice_impact(seed + 1) * 0.7, 0.85)
    return out


def steam(seed=79):
    rng = R(seed)
    d = 1.3
    hiss = hp(noise(d, rng), 2500) * env_points(d, [(0, 0), (0.05, 1), (0.5, 0.6), (1.3, 0)])
    flutter = bp(noise(d, rng), 4000, 9000) * (0.5 + 0.5 * np.sin(2 * np.pi * 18 * tt(d))) * env_exp(d, 0.4)
    return mono_verb(norm(hiss) * 0.8 + norm(flutter) * 0.3, rng, 0.5, 0.1)


def lightning_cast(seed=80):
    rng = R(seed)
    d = 0.8
    n = int(d * SR)
    walk = np.cumsum(rng.normal(0, 1, n))
    walk = lp(walk, 20)
    walk = walk / (np.max(np.abs(walk)) + 1e-9)
    buzz = osc(55 * (1 + 0.08 * walk), shape="saw") + 0.6 * osc(110 * (1 + 0.05 * walk), shape="square")
    buzz = bp(drive(buzz, 4.0), 200, 6000)
    am = np.clip(lp(np.abs(rng.normal(0, 1, n)), 40) * 4, 0, 1)
    zaps = crackle(d, rng, density=60, lo=3000, hi=12000, decay=0.003)
    env = env_points(d, [(0, 0), (0.05, 1), (0.6, 0.8), (0.8, 0)])
    return norm(buzz) * am * env * 0.8 + norm(zaps) * env * 0.4


def lightning_impact(seed=81):
    rng = R(seed)
    d = 1.8
    out = zeros(d)
    snap = noise(0.004, rng)
    place(out, snap, 0)
    burst = crackle(0.08, rng, density=1500, lo=1500, hi=12000, decay=0.001)
    place(out, norm(burst) * 0.8, 0.002)
    body = lp(noise(0.5, rng), 2200) * env_exp(0.5, 0.12)
    place(out, norm(body) * 0.7, 0.01)
    rumble = lp(brown(1.6, rng), 160, 3) * env_exp(1.6, 0.5, attack=0.05)
    place(out, norm(rumble) * 0.9, 0.04)
    return reverb(drive(out, 2.0), rng, time=1.4, mix=0.22, stereo=False)


def poison_cast(seed=82):
    rng = R(seed)
    d = 1.1
    bub = bubbles(d, rng, 24, 100, 350, length=(0.04, 0.09), rise=1.7)
    hiss = bp(noise(d, rng), 1000, 3000) * (0.6 + 0.4 * np.sin(2 * np.pi * 9 * tt(d)))
    sick = (np.sin(2 * np.pi * 330 * tt(d)) + np.sin(2 * np.pi * 349 * tt(d))) * 0.5
    env = env_points(d, [(0, 0), (0.3, 1), (0.8, 0.7), (1.1, 0)])
    return mono_verb((norm(bub) * 0.7 + norm(hiss) * 0.35 + sick * 0.12) * env, rng, 0.6, 0.15)


def poison_impact(seed=83):
    rng = R(seed)
    d = 0.9
    splat = lp(noise(d, rng), 1500) * env_exp(d, 0.05, attack=0.003)
    plop = osc(glide(160, 80, 0.1), shape="sine") * env_exp(0.1, 0.04)
    hiss = hp(noise(d, rng), 3000) * env_exp(d, 0.3)
    out = norm(splat) + norm(hiss) * 0.35
    place(out, plop * 0.7, 0)
    place(out, norm(bubbles(0.6, rng, 8, 120, 300, length=(0.04, 0.08))) * 0.4, 0.15)
    return mono_verb(out, rng, 0.5, 0.12)


def oil_cast(seed=84):
    rng = R(seed)
    d = 1.0
    out = zeros(d)
    for at in (0.0, 0.25, 0.5):
        sq = bp(noise(0.25, rng), 200, 900) * env_exp(0.25, 0.08, attack=0.01)
        place(out, norm(sq) * 0.7, at)
    out += norm(bubbles(d, rng, 12, 80, 220, length=(0.06, 0.12), rise=1.9)) * 0.7
    return mono_verb(lp(out, 2500), rng, 0.4, 0.1)


def heal(seed=85):
    rng = R(seed)
    d = 1.8
    out = zeros(d)
    for i, f in enumerate((587.3, 740.0, 880.0, 1174.7, 1480.0)):
        tone = sum(np.sin(2 * np.pi * f * c * tt(1.2)) for c in (1.0, 1.0017)) * 0.5
        tone += 0.25 * np.sin(2 * np.pi * 2 * f * tt(1.2))
        place(out, tone * env_exp(1.2, 0.5, attack=0.01), i * 0.08)
    air = hp(noise(d, rng), 6000) * env_points(d, [(0, 0), (0.4, 1), (1.8, 0)])
    return reverb(norm(out) + norm(air) * 0.15, rng, time=1.6, mix=0.35, stereo=False)


def bless(seed=86):
    def build(s):
        choir = s.track("choir", "choir", vol=110, reverb=110)
        glock = s.track("glock", "glockenspiel", vol=80, reverb=110)
        choir.chord(0, 2.5, voicing("D", "D4", 4), 90, 1.0)
        choir.swell(0, 1.0, 30, 127)
        glock.seq(0.5, "D6:.25 F#6:.25 A6:.25 D7:1", v=70, legato=1.0)
    return midi_sfx(build, 3.0, bpm=120)


def curse(seed=87):
    rng = R(seed)
    d = 1.6
    f = glide(146.8, 120, d)
    pad = voice(f, d, "u", "o", rng, rough=0.3, breath=0.2) + voice(f * 1.0595, d, "u", "o", rng, rough=0.3)
    pad = norm(pad) * env_points(d, [(0, 0), (0.6, 1), (1.2, 0.6), (1.6, 0)])
    rev = hp(noise(0.7, rng), 800) * np.linspace(0, 1, int(0.7 * SR)) ** 3
    out = zeros(d)
    place(out, pad * 0.8, 0)
    place(out, norm(rev) * 0.3, 0)
    thud = osc(glide(70, 40, 0.5), shape="sine") * env_exp(0.5, 0.12)
    place(out, thud * 0.8, 0.7)
    return reverb(out, rng, time=1.4, mix=0.3, stereo=False)


# --- Мир ----------------------------------------------------------------------

def footstep(seed):
    rng = R(seed)
    d = 0.22
    heel = lp(noise(d, rng), rng.uniform(350, 500)) * env_exp(d, 0.018, attack=0.002)
    heel += osc(rng.uniform(65, 85), d, "sine") * env_exp(d, 0.025) * 0.6
    grit = bp(noise(d, rng), 1000, 4000) * env_exp(d, 0.012)
    gravel = crackle(0.07, rng, density=200, lo=1500, hi=6000, decay=0.0015)
    out = norm(heel)
    place(out, norm(grit) * 0.25, rng.uniform(0.03, 0.05))
    place(out, norm(gravel) * 0.2, 0.01)
    return out


def bell_toll(seed=90):
    rng = R(seed)
    d = 11.0
    b = bell(146.8, d, decay=4.8)
    strike = bp(noise(0.05, rng), 900, 3500) * env_exp(0.05, 0.008)
    out = norm(lp(b, 6000))
    place(out, norm(strike) * 0.3, 0)
    return reverb(out, rng, time=2.5, mix=0.3, stereo=False)


def shovel(seed):
    rng = R(seed)
    d = 0.7
    out = zeros(d)
    if seed % 2:
        scrape = bp(noise(0.12, rng), 2000, 6000) * env_exp(0.12, 0.03)
        scrape += resonators(np.r_[rng.normal(0, 1, 60), np.zeros(int(0.15 * SR))], [2300, 3700], q=25)[: len(scrape)] * 0.4
        crunch = crackle(0.2, rng, density=500, lo=300, hi=3000, decay=0.002) + lp(noise(0.2, rng), 1500) * 0.5
        crunch *= env_exp(0.2, 0.06, attack=0.01)
        place(out, norm(scrape) * 0.6, 0)
        place(out, norm(crunch), 0.03)
    else:
        throw = whoosh(seed, 0.2, 200, 900, 300, q=0.9)
        patter = crackle(0.35, rng, density=260, lo=300, hi=2500, decay=0.003) * env_exp(0.35, 0.12, attack=0.02)
        place(out, norm(throw) * 0.5, 0)
        place(out, norm(patter), 0.18)
    return mono_verb(out, rng, 0.4, 0.1)


def crow(seed, caws=2):
    rng = R(seed)
    d = 0.45 * caws + 0.6
    out = zeros(d)
    base = rng.uniform(480, 600)
    for i in range(caws):
        ln = rng.uniform(0.22, 0.3)
        f = glide(base * rng.uniform(1.05, 1.15), base * 0.82, ln)
        v = voice(f, ln, "a", "ae", rng, rough=1.2, scale=1.45, breath=0.5, vib=(30, 0.02))
        v = drive(norm(v) * 2.5, 3.0) * env_ar(ln, 0.015, 0.07)
        place(out, bp(v, 500, 5000), i * rng.uniform(0.38, 0.48))
    return out


def crow_caw(seed):
    rng = R(seed)
    x = crow(seed, 2 if seed % 2 else 3)
    return reverb(x, rng, time=1.4, mix=0.3, stereo=False)


def earth_rumble(seed=93):
    rng = R(seed)
    d = 3.4
    r = lp(brown(d, rng), 120, 4) * dsp.slow_mod(d, rng, rate=3, depth=0.6)
    sub = np.sin(2 * np.pi * 34 * tt(d))
    rocks = crackle(d, rng, density=30, lo=200, hi=1500, decay=0.006)
    env = env_points(d, [(0, 0), (0.6, 1), (2.4, 0.9), (3.4, 0)])
    return (norm(r) + sub * 0.5 + norm(rocks) * 0.25) * env


def wood_crack(rng, dur):
    n = int(dur * SR)
    x = np.zeros(n)
    t = 0.0
    while t < dur * 0.7:
        i = int(t * SR)
        burst = rng.normal(0, 1, 160) * np.exp(-np.arange(160) / 30)
        m = max(0, min(160, n - i))
        x[i:i + m] += burst[:m] * rng.uniform(0.3, 1.0) * np.exp(-t * 3)
        t += rng.exponential(0.018)
    body = resonators(x, [180, 420, 910, 1650, 2900], q=9, gains=[1.0, 0.8, 0.6, 0.4, 0.3])
    return drive(body * 3, 1.5) * env_exp(dur, 0.35)


def creak(rng, dur, lo=35, hi=70):
    n = int(dur * SR)
    walk = lp(np.cumsum(rng.normal(0, 1, n)), 6)
    walk = (walk - walk.min()) / (np.ptp(walk) + 1e-9)
    src = osc(lo + (hi - lo) * walk, shape="saw")
    body = resonators(src, [420, 900, 1700, 2600], q=18, gains=[1.0, 0.8, 0.5, 0.3])
    return norm(body) * env_ar(dur, 0.08, 0.15, 1.0)


def coffin_crack(seed=94):
    rng = R(seed)
    d = 1.8
    out = zeros(d)
    place(out, norm(creak(rng, 0.6, 30, 55)) * 0.5, 0)
    place(out, norm(wood_crack(rng, 1.2)), 0.45)
    return reverb(out, rng, time=0.9, mix=0.15, stereo=False)


def undead_moan(seed):
    rng = R(seed)
    d = 2.0
    base = rng.uniform(92, 108)
    f = env_points(d, [(0, base), (0.6, base * 1.25), (1.4, base * 1.05), (2.0, base * 0.8)])
    va, vb = ("o", "u") if seed % 2 else ("a", "o")
    v = voice(f, d, va, vb, rng, rough=0.6, breath=0.35, vib=(4.5, 0.03))
    v += voice(f * 1.007, d, va, vb, rng, rough=0.6, breath=0.2, vib=(4.1, 0.03))
    v = drive(norm(v) * 1.5, 1.6) * env_ar(d, 0.25, 0.6, 1.5)
    return reverb(lp(v, 3500), rng, time=1.6, mix=0.3, stereo=False)


def howl(rng, d=3.4):
    f = env_points(d, [(0, 290), (0.55, 560), (1.3, 590), (1.5, 610), (2.6, 520), (d, 400)])
    t = np.arange(len(f)) / SR
    f = f * (1 + 0.012 * np.sin(2 * np.pi * 5.2 * t))
    ph = 2 * np.pi * np.cumsum(f) / SR
    tone = np.sin(ph) + 0.25 * np.sin(2 * ph) + 0.08 * np.sin(3 * ph)
    tone += bp(rng.normal(0, 1, len(tone)), 400, 1800) * 0.06
    return lp(tone, 2500) * env_points(d, [(0, 0), (0.3, 0.8), (1.2, 1.0), (2.8, 0.7), (d, 0)])


def wolf_howl(seed=96):
    rng = R(seed)
    return reverb(lp(howl(rng), 3000), rng, time=2.4, mix=0.4, stereo=False)


def goblin_talk(rng, syllables):
    out = []
    for i in range(syllables):
        ln = rng.uniform(0.07, 0.14)
        f0 = rng.uniform(260, 420)
        f = glide(f0, f0 * rng.uniform(0.8, 1.25), ln)
        va, vb = rng.choice(["a", "e", "i", "o", "ae"], 2)
        syl = voice(f, ln, va, vb, rng, rough=0.6, scale=1.25, breath=0.2, vib=(12, 0.02))
        syl = norm(syl) * env_ar(ln, 0.01, 0.03, 1.0)
        if rng.random() < 0.6:
            cons = bp(noise(0.015, rng), 2000, 6000) * env_exp(0.015, 0.004) * 0.5
            syl = np.concatenate([cons, syl])
        out.append(syl)
        out.append(np.zeros(int(rng.uniform(0.0, 0.07) * SR)))
    return drive(np.concatenate(out) * 1.4, 1.5)


def goblin_chatter(seed):
    rng = R(seed)
    if seed % 2:
        x = goblin_talk(rng, rng.integers(7, 11))
    else:  # смешок «хе-хе-хе»
        parts = []
        for i in range(5):
            f = glide(430 - 25 * i, 380 - 25 * i, 0.09)
            syl = voice(f, 0.09, "e", "e", rng, rough=0.5, scale=1.25, breath=0.6)
            parts += [norm(syl) * env_ar(0.09, 0.008, 0.04, 1.0), np.zeros(int(0.06 * SR))]
        x = drive(np.concatenate(parts) * 1.3, 1.5)
    return mono_verb(x, rng, 0.5, 0.12)


def swamp_bubble(seed=98):
    rng = R(seed)
    d = 0.9
    out = zeros(d)
    for at in sorted(rng.uniform(0, 0.45, 3)):
        ln = rng.uniform(0.06, 0.1)
        b = np.sin(2 * np.pi * np.cumsum(glide(rng.uniform(80, 110), 190, ln)) / SR) * env_ar(ln, 0.005, ln * 0.7, 1.0)
        b += lp(noise(ln, rng), 600) * env_exp(ln, 0.02) * 0.4
        place(out, b, at)
    pop = osc(glide(400, 250, 0.03), shape="sine") * env_exp(0.03, 0.008)
    place(out, pop * 0.5, 0.55)
    return mono_verb(out, rng, 0.5, 0.15)


def enemy_alert(seed=99):
    def build(s):
        brass = s.track("brass", "brass", vol=120, reverb=80)
        low = s.track("low", "strings", vol=110, reverb=80)
        timp = s.track("timp", "timpani", vol=120, reverb=80)
        trem = s.track("trem", "tremolo_strings", vol=90, reverb=90)
        for at, v in ((0, 100), (0.5, 120)):
            brass.chord(at, 0.45 if at == 0 else 1.5, [38, 50, 51, 57], v, 0.9)
            low.chord(at, 0.45 if at == 0 else 1.5, [26, 38, 39], v, 0.9)
            timp.note(at, 0.5, 38, v + 5, 0.9)
        trem.chord(0.5, 1.5, [74, 75], 70, 1.0)
    return midi_sfx(build, 2.0, bpm=110)


def pickup(seed=100):
    def build(s):
        glock = s.track("glock", "glockenspiel", vol=110, reverb=80)
        cel = s.track("cel", "celesta", vol=90, reverb=80)
        glock.seq(0, "E6:.25 B6:1", v=90, legato=1.0)
        cel.seq(0, "E5:.25 B5:1", v=70, legato=1.0)
    return midi_sfx(build, 1.0, bpm=140, tail=1.5)


def coin(seed=101):
    rng = R(seed)
    d = 0.6
    out = zeros(d)
    for at in (0.0, 0.07, 0.12, 0.2):
        f = rng.uniform(2200, 3300)
        tau = rng.uniform(0.05, 0.14)
        cl = sum(a * np.sin(2 * np.pi * f * r * tt(0.4)) for r, a in ((1, 1), (2.76, 0.6), (5.4, 0.35), (8.9, 0.2)))
        place(out, cl * env_exp(0.4, tau) * rng.uniform(0.4, 1.0), at)
    return mono_verb(out, rng, 0.4, 0.12)


def door(seed=102):
    rng = R(seed)
    d = 1.5
    out = zeros(d)
    latch = resonators(np.r_[rng.normal(0, 1, 30), np.zeros(int(0.1 * SR))], [1800, 3500], q=15)
    place(out, norm(latch) * 0.5, 0)
    place(out, creak(rng, 0.8) * 0.7, 0.1)
    knock = resonators(np.r_[rng.normal(0, 1, 120), np.zeros(int(0.3 * SR))], [110, 240, 520], q=6)
    knock = norm(knock) + osc(70, len(knock) / SR, "sine") * env_exp(len(knock) / SR, 0.06) * 0.6
    place(out, norm(knock) * 0.9, 0.95)
    return mono_verb(out, rng, 0.6, 0.15)


def chest_open(seed=103):
    rng = R(seed)
    d = 1.4
    out = zeros(d)
    for at in (0.0, 0.08):
        c = resonators(np.r_[rng.normal(0, 1, 25), np.zeros(int(0.08 * SR))], [1600, 3200], q=14)
        place(out, norm(c) * 0.5, at)
    place(out, creak(rng, 0.45, 50, 90) * 0.6, 0.15)
    sparkle = sum(np.sin(2 * np.pi * f * tt(0.8)) * env_exp(0.8, 0.3) for f in (1568, 1976, 2349, 3136))
    place(out, sparkle * 0.1, 0.55)
    return mono_verb(out, rng, 0.6, 0.15)


def transition(seed=104):
    rng = R(seed)
    d = 1.4
    w = whoosh(seed, 1.0, 200, 2500, 300, q=0.9)
    shimmer = sum(np.sin(2 * np.pi * f * tt(d)) for f in (587.3, 880.0, 1318.5))
    shimmer *= env_points(d, [(0, 0), (0.6, 1), (1.4, 0)]) * 0.12
    out = zeros(d)
    place(out, norm(w) * 0.8, 0)
    out += shimmer
    return reverb(out, rng, time=1.2, mix=0.3, stereo=False)


def turn_start(seed=105):
    rng = R(seed)
    d = 1.6
    b = norm(bell(587.3, d, decay=0.9)) * 0.5
    knock = resonators(np.r_[rng.normal(0, 1, 40), np.zeros(int(0.15 * SR))], [600, 1300], q=10)
    out = b
    place(out, norm(knock) * 0.3, 0)
    return mono_verb(out, rng, 0.8, 0.2)


# --- Интерфейс ----------------------------------------------------------------

def ui_click(seed=110):
    rng = R(seed)
    imp = np.r_[rng.normal(0, 1, 20), np.zeros(int(0.08 * SR))]
    body = resonators(imp, [900, 2400, 4100], q=8, gains=[1.0, 0.6, 0.3])
    low = np.sin(2 * np.pi * 300 * tt(0.1)) * env_exp(0.1, 0.01)
    return fit(norm(body) * env_exp(len(body) / SR, 0.012) + low[: len(body)] * 0.3, 0.09)


def ui_hover(seed=111):
    rng = R(seed)
    imp = np.r_[rng.normal(0, 1, 10), np.zeros(int(0.05 * SR))]
    return fit(norm(resonators(imp, [2800, 5200], q=10)) * env_exp(len(imp) / SR, 0.006), 0.05)


def blips(notes, shape="square", length=0.06, gap=0.0):
    out = []
    for f in notes:
        x = osc(f, length, shape) * env_ar(length, 0.003, length * 0.5, 1.0)
        out += [lp(x, 2500), np.zeros(int(gap * SR))]
    return np.concatenate(out)


def ui_confirm(seed=112):
    return mono_verb(blips([880.0, 1174.7], length=0.07), R(seed), 0.3, 0.12)


def ui_back(seed=113):
    return mono_verb(blips([1174.7, 880.0], length=0.07), R(seed), 0.3, 0.12)


def ui_open(seed=114):
    rng = R(seed)
    w = bp(noise(0.18, rng), 800, 4000) * env_points(0.18, [(0, 0), (0.12, 1), (0.18, 0)])
    out = zeros(0.25)
    place(out, norm(w) * 0.7, 0)
    place(out, ui_click(seed) * 0.5, 0.15)
    return out


def ui_error(seed=115):
    return blips([140.0, 140.0], shape="square", length=0.08, gap=0.04)


def page(seed):
    rng = R(seed)
    d = 0.4
    n = int(d * SR)
    am = np.clip(lp(np.abs(rng.normal(0, 1, n)), 30) * 5, 0, 1)
    rustle = bp(noise(d, rng), 1500, 7000) * am * env_points(d, [(0, 0), (0.05, 1), (0.3, 0.5), (0.4, 0)])
    out = norm(rustle)
    if seed % 2 == 0:
        flap = lp(noise(0.12, rng), 800) * env_exp(0.12, 0.03)
        place(out, norm(flap) * 0.5, 0.22)
    return out


def dialogue_blip(seed):
    rng = R(seed)
    imp = np.r_[rng.normal(0, 1, 12), np.zeros(int(0.045 * SR))]
    tick = norm(resonators(imp, [1600, 3300], q=9)) * env_exp(len(imp) / SR, 0.006)
    tone = lp(osc(600 + 80 * seed, 0.02, "square"), 2000) * env_exp(0.02, 0.006) * 0.25
    out = fit(tick, 0.05)
    place(out, tone, 0)
    return out


# --- Фоновые петли (стерео) ---------------------------------------------------

def wind_bed(dur, rng, level=1.0, lo=150, hi=1100, gust_rate=0.25):
    chans = []
    for _ in range(2):
        src = brown(dur, rng) * 0.7 + lp(noise(dur, rng), 2500) * 0.3
        mod = dsp.slow_mod(dur, rng, rate=gust_rate, depth=0.8)
        cutoff = lo + (hi - lo) * mod
        w = sweep(src, "bp", cutoff, q=0.7, block=512)
        chans.append(norm(w) * (0.3 + 0.7 * mod))
    return np.stack(chans, axis=1) * level


def scatter(bed, rng, make, count, gain, spread=0.8, verb=(1.5, 0.35)):
    """Разбросать события по петле: make(i) -> моно звук. Хвосты за концом переходят в начало."""
    L = len(bed) / SR
    slots = np.sort(rng.uniform(0, L, count))
    for i, at in enumerate(slots):
        x = make(i)
        st = reverb(x, rng, time=verb[0], mix=verb[1]) if verb else dsp.pan(x, 0)
        side = rng.uniform(-spread, spread)
        st = st * np.array([np.cos((side + 1) * np.pi / 4), np.sin((side + 1) * np.pi / 4)]) * np.sqrt(2)
        place_wrap(bed, st * gain, at)
    return bed


def frog(rng, low=True):
    pulses = rng.integers(6, 14)
    rate = rng.uniform(22, 30) if low else rng.uniform(35, 48)
    d = pulses / rate + 0.1
    x = zeros(d)
    for k in range(pulses):
        imp = rng.normal(0, 1, 90) * np.exp(-np.arange(90) / 20)
        place(x, imp * (0.6 + 0.4 * np.sin(np.pi * k / pulses)), k / rate)
    res = [320, 950] if low else [700, 2100]
    return norm(resonators(x, res, q=7, gains=[1.0, 0.5]))


def owl(rng):
    d = 1.4
    x = zeros(d)
    for at, ln in ((0, 0.35), (0.6, 0.18), (0.82, 0.4)):
        f = glide(390, 360, ln)
        h = np.sin(2 * np.pi * np.cumsum(f) / SR) * env_ar(ln, 0.06, 0.15, 1.0)
        place(x, h, at)
    return lp(x, 900)


def amb_cemetery(seed=120):
    rng = R(seed)
    L = 64.0
    bed = wind_bed(L + 4, rng, 1.0, 140, 1000)
    bed = dsp.make_loop(bed, 4.0)
    scatter(bed, rng, lambda i: crow(seed + i, 2 + i % 2), 4, 0.35, verb=(2.0, 0.5))
    scatter(bed, rng, lambda i: creak(rng, 0.8, 30, 60) * 0.5, 2, 0.25, verb=(1.5, 0.4))
    leaves = hp(noise(L, rng), 3000) * dsp.slow_mod(L, rng, rate=0.4, depth=0.9)
    bed += np.stack([leaves, np.roll(leaves, SR // 3)], axis=1) * 0.04
    return bed


def amb_village(seed=121):
    rng = R(seed)
    L = 64.0
    bed = dsp.make_loop(wind_bed(L + 4, rng, 0.7, 120, 700, gust_rate=0.15), 4.0)
    scatter(bed, rng, lambda i: crow(seed + 10 + i, 2) * 0.6, 2, 0.25, verb=(2.4, 0.6))
    scatter(bed, rng, lambda i: creak(rng, 1.0, 40, 70), 3, 0.18, verb=(1.2, 0.4))
    knock = lambda i: resonators(np.r_[rng.normal(0, 1, 100), np.zeros(int(0.3 * SR))], [140, 320, 700], q=6)
    scatter(bed, rng, lambda i: norm(knock(i)), 3, 0.12, verb=(2.0, 0.6))
    scatter(bed, rng, lambda i: lp(howl(rng, 3.0), 1500) * 0.5, 1, 0.12, verb=(3.0, 0.7))
    return bed


def amb_forest(seed=122):
    rng = R(seed)
    L = 64.0
    bed = dsp.make_loop(wind_bed(L + 4, rng, 0.35, 100, 500, gust_rate=0.1), 4.0)
    fog = lp(brown(L, rng), 300) * dsp.slow_mod(L, rng, rate=0.1, depth=0.5)
    bed += np.stack([fog, np.roll(fog, SR)], axis=1) * 0.25
    scatter(bed, rng, lambda i: frog(rng, True), 26, 0.3, verb=(1.0, 0.3))
    scatter(bed, rng, lambda i: frog(rng, False), 18, 0.18, verb=(1.2, 0.4))
    scatter(bed, rng, lambda i: swamp_bubble(seed + i) * 0.8, 9, 0.25, verb=None)
    drip = lambda i: np.sin(2 * np.pi * np.cumsum(glide(rng.uniform(1500, 2800), 3200, 0.03)) / SR) * env_exp(0.03, 0.008)
    scatter(bed, rng, drip, 14, 0.12, verb=(1.6, 0.5))
    scatter(bed, rng, lambda i: lp(howl(rng), 1800), 1, 0.15, verb=(3.5, 0.75))
    scatter(bed, rng, lambda i: owl(rng), 2, 0.2, verb=(2.5, 0.6))
    return bed


def amb_camp(seed=123):
    rng = R(seed)
    L = 64.0
    bed = dsp.make_loop(wind_bed(L + 4, rng, 0.3, 120, 600, gust_rate=0.1), 4.0)
    roar = lp(brown(L + 2, rng), 380) * dsp.slow_mod(L + 2, rng, rate=1.5, depth=0.5)
    fire = crackle(L + 2, rng, density=28, lo=1200, hi=8000, decay=0.003)
    pops = crackle(L + 2, rng, density=1.2, lo=400, hi=4000, decay=0.01)
    f = dsp.make_loop(norm(roar) * 0.35 + norm(fire) * 0.5 + norm(pops) * 0.6, 2.0)
    bed += np.stack([f, np.roll(f, 300)], axis=1)[: len(bed)] * 0.9
    scatter(bed, rng, lambda i: goblin_talk(rng, rng.integers(5, 9)), 5, 0.18, verb=(1.8, 0.55))

    def drums(i):
        x = zeros(2.2)
        for k in range(4):
            hit = osc(glide(110, 70, 0.3), shape="sine") * env_exp(0.3, 0.08) + lp(noise(0.3, rng), 300) * env_exp(0.3, 0.03)
            place(x, hit * (1.0 if k % 2 == 0 else 0.6), k * 0.42)
        return x
    scatter(bed, rng, drums, 3, 0.12, verb=(2.5, 0.7))
    return bed


# --- Таблица ------------------------------------------------------------------

def _variants(name, fn, count, kind="sfx", base=0):
    return {f"{name}_{i + 1}": (kind, (lambda i=i: fn(base + i))) for i in range(count)}


ALL = {}
ALL.update(_variants("melee_hit", melee_hit, 3, base=10))
ALL["melee_crit"] = ("sfx", melee_crit)
ALL.update(_variants("melee_miss", melee_miss, 2, base=20))
ALL.update(_variants("slash", slash, 2, base=25))
ALL.update(_variants("whoosh", lambda s: whoosh(s, 0.3 + 0.04 * (s % 3)), 3, base=30))
ALL["bow_shot"] = ("sfx", bow_shot)
ALL["arrow_hit"] = ("sfx", arrow_hit)
ALL.update(_variants("hurt", hurt, 2, base=55))
ALL["death"] = ("sfx", death)
ALL["enemy_death"] = ("sfx", enemy_death)
ALL["bone_crunch"] = ("sfx", bone_crunch)
for _name, _fn in (("fire_cast", fire_cast), ("fire_impact", fire_impact), ("water_cast", water_cast),
                   ("water_impact", water_impact), ("ice_cast", ice_cast), ("ice_impact", ice_impact),
                   ("lightning_cast", lightning_cast), ("lightning_impact", lightning_impact),
                   ("poison_cast", poison_cast), ("poison_impact", poison_impact), ("oil_cast", oil_cast),
                   ("heal", heal), ("bless", bless), ("curse", curse), ("explosion", explosion),
                   ("freeze", freeze), ("steam", steam), ("potion", potion)):
    ALL[_name] = ("sfx", _fn)
ALL.update(_variants("footstep", footstep, 4, base=140))
ALL["bell"] = ("sfx", bell_toll)
ALL.update(_variants("shovel", shovel, 2, base=150))
ALL.update(_variants("crow_caw", crow_caw, 2, base=160))
ALL["earth_rumble"] = ("sfx", earth_rumble)
ALL["coffin_crack"] = ("sfx", coffin_crack)
ALL.update(_variants("undead_moan", undead_moan, 2, base=170))
ALL["wolf_howl"] = ("sfx", wolf_howl)
ALL.update(_variants("goblin_chatter", goblin_chatter, 2, base=180))
ALL["swamp_bubble"] = ("sfx", swamp_bubble)
ALL["enemy_alert"] = ("sfx", enemy_alert)
for _name, _fn in (("pickup", pickup), ("coin", coin), ("door", door), ("chest_open", chest_open),
                   ("transition", transition), ("turn_start", turn_start)):
    ALL[_name] = ("sfx", _fn)
for _name, _fn in (("ui_click", ui_click), ("ui_hover", ui_hover), ("ui_confirm", ui_confirm),
                   ("ui_back", ui_back), ("ui_open", ui_open), ("ui_error", ui_error)):
    ALL[_name] = ("ui", _fn)
ALL.update(_variants("page", page, 2, kind="ui", base=190))
ALL.update(_variants("dialogue_blip", dialogue_blip, 3, kind="ui", base=0))
for _name, _fn in (("amb_cemetery", amb_cemetery), ("amb_village", amb_village),
                   ("amb_forest", amb_forest), ("amb_camp", amb_camp)):
    ALL[_name] = ("ambient", _fn)
