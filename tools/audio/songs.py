"""Партитуры. Каждая функция возвращает (Song, длина в долях, петля ли).

Сквозная «Тема Ладо» — народный вальс 3/4 в ре дорийском. Она звучит в меню, на похоронах
(хор), у босса (искажённая, «пляска смерти» с ксилофоном-костями) и на прощании (целиком).
"""

import numpy as np

import dsp
from musiclib import Song, chord_root, pitch, voicing

# --- Тема Ладо ----------------------------------------------------------------
# 16 тактов 3/4: фраза 1 и 2 в ре дорийском, фраза 3 уходит в фа мажор, фраза 4 возвращает домой.
L1 = "D4 F4 G4 | A4:2 C5:1 | B4:1 A4 G4 | A4:3"
H1 = "Dm Dm G Dm"
L2 = "D5:1.5 C5:.5 A4:1 | G4 F4 E4 | F4 G4 F4 | E4:3"
H2 = "Dm C Bb A"
L3 = "A4:1 C5 D5 | E5:2 D5:1 | C5:1 Bb4 G4 | A4:3"
H3 = "F C C7 F"
L4 = "D5:1 C5 A4 | G4:1.5 F4:.5 E4:1 | F4:1 D4 E4 | D4:3"
H4 = "Dm C Gm:2 A:1 Dm"
LADO = [L1, L2, L3, L4]
LADO_H = [H1, H2, H3, H4]
# Подголосок к теме, сверен с аккордами (для виолончели, валторн, второй скрипки).
LADO_COUNTER = [
    "A3:3 | F3:2 A3:1 | G3:2 B3:1 | F3:3",
    "F4:3 | E4:1 C4:2 | D4:3 | C#4:3",
    "F4:2 A4:1 | G4:3 | E4:3 | F4:3",
    "F4:3 | E4:1.5 C4:1.5 | Bb3:2 C#4:1 | A3:3",
]


def prog(text, bar):
    """'Dm C:2 G:1' -> [('Dm', bar), ('C', 2), ('G', 1)]."""
    out = []
    for tok in text.split():
        if ":" in tok:
            c, d = tok.split(":")
            out.append((c, float(d)))
        else:
            out.append((tok, float(bar)))
    return out


def chords_over(chords):
    """[(аккорд, длина)] -> [(начало, аккорд, длина)]."""
    t = 0.0
    out = []
    for c, d in chords:
        out.append((t, c, d))
        t += d
    return out


def pad(track, t0, chords, low, count=3, v=60, legato=1.0):
    for t, c, d in chords_over(chords):
        track.chord(t0 + t, d, voicing(c, low, count), v, legato)


def bass(track, t0, chords, low, v=70, rhythm=None, legato=0.95):
    """Бас по основным тонам. rhythm — доли внутри аккорда, по умолчанию одна нота на аккорд."""
    for t, c, d in chords_over(chords):
        r = chord_root(c, low)
        if rhythm is None:
            track.note(t0 + t, d, r, v, legato)
        else:
            for off, dur, interval in rhythm:
                if off < d:
                    track.note(t0 + t + off, min(dur, d - off), r + interval, v, legato)


def arp(track, t0, chords, low, pattern, step=0.5, v=60, legato=1.6, bass_low=None):
    """Перебор: pattern — индексы нот аккорда (0 = бас, если задан bass_low)."""
    for t, c, d in chords_over(chords):
        tones = voicing(c, low, max(i for i in pattern if i is not None) + 1)
        if bass_low:
            tones = [chord_root(c, bass_low)] + tones
        k = 0
        x = 0.0
        while x < d - 1e-6:
            idx = pattern[k % len(pattern)]
            if idx is not None:
                acc = 10 if k == 0 else 0
                track.note(t0 + t + x, step, tones[idx], v + acc, legato)
            k += 1
            x += step


def lado_all(bar=3):
    melody = " | ".join(LADO)
    chords = []
    for h in LADO_H:
        chords += prog(h, bar)
    return melody, chords


def ref_rms(audio):
    """Средняя громкость отрендеренной музыки: синтезированные слои ставятся относительно неё."""
    return float(np.sqrt(np.mean(np.asarray(audio, dtype=np.float64) ** 2)) + 1e-9)


def norm_peak(x):
    return x / (np.max(np.abs(x)) + 1e-9)


def bell_layer(times, freq=146.8, level=3.0, decay=4.0, seed=7):
    """Колокол поверх MIDI: синтез из dsp.bell, времена в долях.
    level — пик колокола относительно средней громкости музыки (3 = примерно как пики оркестра)."""
    def post(audio, song, body):
        rng = np.random.default_rng(seed)
        ref = ref_rms(audio[:body])
        for i, (beat, g) in enumerate(times):
            b = dsp.bell(freq * (1 + 0.002 * i), decay * 2.5, decay=decay, rng=rng)
            b = norm_peak(dsp.lp(b, 5000)) * g * level * ref
            st = dsp.pan(b, -0.2 + 0.1 * (i % 3))
            dsp.place(audio, st, song.sec(beat))
        return audio
    return post


# --- Меню: «Тема Ладо» ---------------------------------------------------------

def theme_lado():
    s = Song("theme_lado", 84, 3, seed=11)
    fiddle = s.track("fiddle", "fiddle", vol=92, pan=70, reverb=70)
    flute = s.track("flute", "flute", vol=88, pan=58, reverb=80)
    lute = s.track("lute", "nylon_guitar", vol=96, pan=48, reverb=60, human=0.008)
    harp = s.track("harp", "harp", vol=70, pan=84, reverb=80)
    cello = s.track("cello", "cello", vol=78, pan=60, reverb=70)
    strings = s.track("strings", "slow_strings", vol=64, pan=64, reverb=90)
    drum = s.drums(vol=60, reverb=60)
    pat = [0, 2, 3, 4, 3, 2]
    intro = prog("Dm Bb Gm A", 3)
    arp(lute, 0, intro, "D3", pat, bass_low="D2", v=62)
    cello.swell(0, 9, 40, 110)
    bass(cello, 0, intro, "D2", v=60)
    t = 12.0
    melody, chords = lado_all()
    # Проведение 1: скрипка-фидл и лютня
    fiddle.seq(t, melody, v=86, legato=0.96)
    arp(lute, t, chords, "D3", pat, bass_low="D2", v=60)
    bass(cello, t, chords, "D2", v=58)
    pad(strings, t, chords, "F3", 3, v=38)
    t += 48
    # Проведение 2: флейта октавой выше, фидл второй голос, арфа
    flute.seq(t, melody, v=84, octave=1, legato=0.97)
    fiddle.seq(t, " | ".join(LADO_COUNTER), v=64, octave=1, legato=0.97)
    arp(lute, t, chords, "D3", pat, bass_low="D2", v=56)
    arp(harp, t, chords, "D4", [0, 1, 2, 3, 2, 1], v=50, legato=2.0)
    bass(cello, t, chords, "D2", v=64)
    pad(strings, t, chords, "F3", 3, v=52)
    strings.swell(t, t + 24, 80, 120)
    strings.swell(t + 36, t + 48, 120, 90)
    for bar in range(16):
        drum.hit(t + bar * 3, "low_tom", 46 if bar % 2 else 58)
        drum.hit(t + bar * 3 + 2, "low_tom", 34)
    t += 48
    outro = prog("Dm Dm", 3)
    arp(lute, t, outro, "D3", pat, bass_low="D2", v=56)
    fiddle.note(t, 6, "D4", 60, 0.98)
    bass(cello, t, outro, "D2", v=50)
    t += 6
    return s, t, True


# --- Похороны на Старом погосте --------------------------------------------------

def funeral():
    s = Song("funeral", 60, 3, seed=12)
    cello = s.track("cello", "cello", vol=116, pan=54, reverb=80)
    oohs = s.track("oohs", "voice_oohs", vol=92, pan=70, reverb=100)
    choir = s.track("choir", "choir", vol=70, pan=64, reverb=110)
    strings = s.track("strings", "slow_strings", vol=74, pan=64, reverb=100)
    bassline = s.track("contrabass", "contrabass", vol=80, pan=60, reverb=80)
    organ = s.track("organ", "reed_organ", vol=50, pan=64, reverb=110)
    # Вступление: гул струнных и органа, колокол
    intro = prog("Dm Dm Bb A", 3)
    pad(strings, 0, intro, "D3", 3, v=56)
    strings.swell(0, 12, 30, 105)
    pad(organ, 0, prog("Dm:6 Bb:3 A:3", 3), "A2", 3, v=50)
    bass(bassline, 0, intro, "D2", v=60)
    t = 12.0
    # Фразы 1-2: виолончель, хор держит аккорды
    ch12 = prog(H1, 3) + prog(H2, 3)
    cello.seq(t, L1 + " | " + L2, v=100, octave=-1, legato=0.98)
    pad(choir, t, ch12, "F3", 3, v=52)
    pad(strings, t, ch12, "D3", 3, v=44)
    bass(bassline, t, ch12, "D2", v=58)
    t += 24
    # Фразы 3-4: хор без слов ведёт тему, виолончель — нижний голос
    ch34 = prog(H3, 3) + prog(H4, 3)
    oohs.seq(t, L3 + " | " + L4, v=82, legato=0.99)
    cello.seq(t, LADO_COUNTER[2] + " | " + LADO_COUNTER[3], v=64, octave=-1, legato=0.98)
    pad(choir, t, ch34, "C4", 3, v=48)
    pad(strings, t, ch34, "D3", 3, v=48)
    bass(bassline, t, ch34, "D2", v=58)
    t += 24
    # Заключение: снова гул и колокол
    outro = prog("Dm Bb Gm A", 3)
    pad(strings, t, outro, "D3", 3, v=48)
    strings.swell(t, t + 12, 110, 60)
    pad(organ, t, outro, "A2", 3, v=46)
    bass(bassline, t, outro, "D2", v=56)
    t += 12
    s.post.append(bell_layer([(0, 1.0), (6, 0.7), (12, 0.55), (36, 0.5), (60, 0.8), (66, 0.6)],
                             freq=146.8, level=3.0, decay=5.0))
    return s, t, True


# --- Бой с нежитью на погосте --------------------------------------------------------

def combat_undead():
    s = Song("combat_undead", 116, 4, seed=13)
    low = s.track("low_strings", "strings", vol=104, pan=50, reverb=50, human=0.004)
    cb = s.track("contrabass", "contrabass", vol=100, pan=60, reverb=50, human=0.004)
    organ = s.track("organ", "church_organ", vol=66, pan=64, reverb=100)
    trem = s.track("tremolo", "tremolo_strings", vol=66, pan=80, reverb=90)
    trombone = s.track("trombones", "trombone", vol=100, pan=56, reverb=80)
    choir = s.track("choir", "choir", vol=80, pan=72, reverb=110)
    bells = s.track("bells", "tubular_bells", vol=70, pan=30, reverb=100)
    timp = s.track("timpani", "timpani", vol=106, pan=64, reverb=70, human=0.003)
    drum = s.drums(vol=96, reverb=60)
    # Остинато по восьмым с фригийской малой секундой
    osti = [0, 0, 1, 0, 0, 0, 3, 1]

    def ostinato(t0, chords, v=78):
        for t, c, d in chords_over(chords):
            r = chord_root(c, "A2")
            for k in range(int(d * 2)):
                p = r + osti[k % 8]
                low.note(t0 + t + k * 0.5, 0.5, p, v + (12 if k % 4 == 0 else 0), 0.6)
                cb.note(t0 + t + k * 0.5, 0.5, p - 12, v - 4, 0.55)

    def pulse(t0, bars, roll_last=True):
        for b in range(bars):
            x = t0 + b * 4
            timp.note(x, 1, "D2", 96, 0.9)
            timp.note(x + 2.5, 0.5, "A1", 78, 0.9)
            drum.hit(x, "kick2", 90)
            drum.hit(x + 1.5, "kick2", 60)
            drum.hit(x + 3, "low_tom", 70)
            if roll_last and b == bars - 1:
                for k in range(8):
                    timp.note(x + 2 + k * 0.25, 0.25, "A1", 60 + k * 7, 0.9)

    a = prog("Dm Dm Eb Dm Cm Eb A7 A7", 4)
    # A: только ритм и остинато, орган вступает с третьего такта
    ostinato(0, a)
    pulse(0, 8)
    organ.swell(0, 8, 50, 110)
    pad(organ, 0, a, "D3", 4, v=64)
    trem.seq(16, "A5:4 | Bb5:4 | A5:4 | Bb5:4", v=50, legato=1.0)
    t = 32.0
    # B: тромбоны ведут мрачную тему, хор кластером
    b = prog("Dm Dm Eb Eb Cm Gm Bb A", 4)
    ostinato(t, b)
    pulse(t, 8)
    trombone.seq(t, "D3:2 F3:1 Eb3:1 | D3:3 r:1 | Eb3:2 G3:1 F3:1 | Eb3:3 r:1 | "
                 "C3:2 Eb3:1 D3:1 | C3:1 Bb2:1 G2:2 | Bb2:2 C#3:2 | E3:2 A2:2", v=96, legato=0.95)
    trombone.seq(t, "D4:2 F4:1 Eb4:1 | D4:3 r:1 | Eb4:2 G4:1 F4:1 | Eb4:3 r:1 | "
                 "C4:2 Eb4:1 D4:1 | C4:1 Bb3:1 G3:2 | Bb3:2 C#4:2 | E4:2 A3:2", v=70, legato=0.95)
    pad(choir, t, b, "A3", 3, v=58)
    choir.swell(t, t + 32, 70, 120)
    for bar in (0, 4):
        bells.note(t + bar * 4, 4, "D4", 80, 1.0)
        bells.note(t + bar * 4 + 2, 2, "Eb4", 60, 1.0)
    t += 32
    # C: тема Ладо искажённо в высоких струнах, напряжение к повтору
    c = prog("Gm Gm Dm Dm Bb Eb A A", 4)
    ostinato(t, c, v=84)
    pulse(t, 8)
    trem.seq(t, "D5:4 | C5:2 Bb4:2 | A4:4 | F4:2 A4:2 | Bb4:4 | Eb5:4 | C#5:4 | E5:4", v=74,
             legato=1.0)
    trombone.seq(t + 16, "Bb2:4 | Eb3:4 | A2:4 | A2:2 C#3:2", v=100)
    pad(organ, t, c, "D3", 4, v=70)
    drum.hit(t, "crash", 72)
    drum.hit(t + 16, "china", 64)
    for k in range(16):
        drum.hit(t + 28 + k * 0.25, "snare", 34 + k * 3)
    t += 32
    # D: остинато с хором и колоколами, тромбоны отвечают теме, затем всё к началу петли
    d = prog("Dm Dm Eb Dm Cm Eb A7 A7", 4)
    ostinato(t, d)
    pulse(t, 8)
    pad(choir, t, d, "D4", 3, v=62)
    pad(organ, t, d, "D3", 4, v=58)
    trombone.seq(t + 4, "A2:2 Bb2:2 | r:4 | Bb2:2 G2:2 | r:4 | G2:2 Eb2:2 | r:4 | "
                 "A2:4 | A2:4", v=84, legato=0.98)
    for bar in range(0, 8, 2):
        bells.note(t + bar * 4, 4, "D4" if bar % 4 == 0 else "Eb4", 66, 1.0)
    t += 32
    return s, t, True


# --- Деревня Вороний Брод в сумерках -----------------------------------------------------

def village():
    s = Song("village", 76, 4, seed=14)
    lute = s.track("lute", "nylon_guitar", vol=96, pan=46, reverb=60, human=0.01)
    clar = s.track("clarinet", "clarinet", vol=86, pan=70, reverb=80)
    flute = s.track("flute", "flute", vol=84, pan=58, reverb=85)
    cello = s.track("cello", "cello", vol=70, pan=64, reverb=80)
    strings = s.track("strings", "slow_strings", vol=56, pan=64, reverb=100)
    trem = s.track("tremolo", "tremolo_strings", vol=44, pan=90, reverb=100)
    harp = s.track("harp", "harp", vol=62, pan=84, reverb=90)
    a_mel = ("E4:1.5 A4:.5 C5:1 B4:1 | A4:2 G4:1 F4:1 | E4:1.5 G4:.5 C5:1 D5:1 | D5:1 B4:1 G4:2 | "
             "A4:1.5 B4:.5 C5:1 E5:1 | D5:1 C5:1 A4:2 | F4:1 A4:1 D5:1 C5:1 | B4:3 G#4:1")
    b_mel = ("C5:1.5 A4:.5 F4:2 | D5:1.5 B4:.5 G4:2 | E5:1 D5:1 B4:1 G4:1 | A4:2 C5:2 | "
             "D5:1.5 C5:.5 A4:1 F4:1 | E4:1 A4:1 C5:2 | B4:1 A4:1 G#4:1 A4:1 | B4:2 E4:2")
    # подголосок кларнета под флейтой, сверен с аккордами
    a_cnt = "C4:2 E4:2 | C4:2 A3:2 | G3:2 E4:2 | B3:2 D4:2 | C4:2 E4:2 | F4:2 C4:2 | D4:2 F4:2 | E4:2 D4:1 B3:1"
    b_cnt = "A3:2 C4:2 | B3:2 D4:2 | G3:2 B3:2 | C4:2 E4:2 | F4:2 D4:2 | C4:2 A3:2 | D4:2 B3:1 C4:1 | G#3:2 B3:2"
    a_ch = prog("Am F C G Am F Dm E", 4)
    b_ch = prog("F G Em Am Dm Am Bm7b5 E", 4)
    pat = [0, 2, 3, 4, 2, 3, 4, 3]
    t = 0.0
    intro = prog("Am F", 4)
    arp(lute, t, intro, "E3", pat, bass_low="A2", v=58)
    t += 8
    for rnd in range(2):
        mel_tr = clar if rnd == 0 else flute
        mel_tr.seq(t, a_mel + " | " + b_mel, v=80, legato=0.96)
        if rnd == 1:
            clar.seq(t, a_cnt + " | " + b_cnt, v=60, legato=0.97)
            arp(harp, t, a_ch + b_ch, "A4", [0, 1, 2, 1], step=1.0, v=46, legato=2.5)
        ch = a_ch + b_ch
        arp(lute, t, ch, "E3", pat, bass_low="A2", v=56)
        bass(cello, t, ch, "A2", v=52, legato=0.98)
        pad(strings, t, ch, "C4", 3, v=34 + 8 * rnd)
        # Тревога в каденциях: тремоло на тритоне
        trem.seq(t + 28, "G#5:4", v=44, legato=1.0)
        trem.seq(t + 60, "D5:2 F5:2", v=48, legato=1.0)
        t += 64
    # Тихая связка: только лютня и далёкая флейта
    c_ch = prog("Dm Am Dm E", 4)
    arp(lute, t, c_ch, "E3", pat, bass_low="A2", v=50)
    flute.seq(t + 4, "E5:4 | D5:2 C5:2 | B4:4", v=56, legato=1.0)
    bass(cello, t, c_ch, "A2", v=44)
    t += 16
    return s, t, True


# --- Таверна «Пьяный Ворон» ---------------------------------------------------------------

def tavern():
    s = Song("tavern", 168, 3, seed=15)
    fiddle = s.track("fiddle", "fiddle", vol=98, pan=70, reverb=40, human=0.006)
    whistle = s.track("whistle", "whistle", vol=74, pan=40, reverb=40)
    acc = s.track("accordion", "accordion", vol=78, pan=56, reverb=40)
    guitar = s.track("guitar", "steel_guitar", vol=86, pan=40, reverb=35, human=0.006)
    bassist = s.track("bass", "acoustic_bass", vol=92, pan=64, reverb=30)
    drum = s.drums(vol=86, reverb=35)
    a = ("A4:.5 F#4:.5 A4:.5 D5:1 A4:.5 | B4:.5 G4:.5 B4:.5 D5:1 B4:.5 | "
         "A4:.5 F#4:.5 A4:.5 D5:.5 E5:.5 F#5:.5 | E5:1 C#5:.5 A4:1.5 | "
         "A4:.5 F#4:.5 A4:.5 D5:1 E5:.5 | F#5:.5 G5:.5 F#5:.5 E5:1 D5:.5 | "
         "C#5:.5 B4:.5 A4:.5 B4:.5 C#5:.5 E5:.5 | D5:1 A4:.5 D5:1.5")
    b = ("D5:.5 B4:.5 D5:.5 G5:1 D5:.5 | F#5:.5 E5:.5 D5:.5 A5:1 F#5:.5 | "
         "G5:.5 F#5:.5 E5:.5 B4:1 E5:.5 | C#5:.5 B4:.5 A4:.5 E5:1.5 | "
         "D5:.5 B4:.5 D5:.5 G5:1 B5:.5 | A5:.5 F#5:.5 D5:.5 F#5:1 A5:.5 | "
         "G5:.5 E5:.5 C#5:.5 E5:.5 D5:.5 C#5:.5 | D5:1.5 r:1.5")
    a_ch = prog("D G D A D G A D", 3)
    b_ch = prog("G D Em A G D A D", 3)

    def comp(t0, chords, v=70):
        for t, c, d in chords_over(chords):
            r = chord_root(c, "D2")
            bassist.note(t0 + t, 1.5, r, v + 10, 0.8)
            bassist.note(t0 + t + 1.5, 1.5, r + 7, v, 0.8)
            tones = voicing(c, "D4", 3)
            guitar.chord(t0 + t, 1.0, tones, v + 4, 0.5, strum=0.015)
            guitar.chord(t0 + t + 1.0, 0.5, tones, v - 14, 0.5, strum=0.01)
            guitar.chord(t0 + t + 1.5, 1.0, tones, v, 0.5, strum=0.015)
            guitar.chord(t0 + t + 2.5, 0.5, tones, v - 14, 0.5, strum=0.01)
            acc.chord(t0 + t + 0.5, 0.5, voicing(c, "F#3", 3), v - 10, 0.6)
            acc.chord(t0 + t + 2.0, 0.5, voicing(c, "F#3", 3), v - 10, 0.6)
            drum.hit(t0 + t, "kick", 80)
            drum.hit(t0 + t + 1.5, "low_tom", 70)
            drum.hit(t0 + t + 2.5, "low_tom", 46)
            drum.hit(t0 + t + 1.0, "tambourine", 50)
            drum.hit(t0 + t + 2.5, "tambourine", 40)

    t = 0.0
    comp(t, prog("D D", 3))
    t += 6
    for rnd in range(2):
        for part, ch in ((a, a_ch), (a, a_ch), (b, b_ch), (b, b_ch)):
            fiddle.seq(t, part, v=88, legato=0.85)
            if rnd == 1:
                whistle.seq(t, part, v=70, legato=0.8, octave=1 if part is a else 0)
            else:
                acc.seq(t, part, v=50, legato=0.8, octave=-1)
            comp(t, ch, v=70 + 6 * rnd)
            t += 24
    return s, t, True


# --- Туманный Ольшаник ------------------------------------------------------------------

def forest():
    s = Song("forest", 56, 4, seed=16)
    padt = s.track("pad", "warm_pad", vol=66, pan=64, reverb=110)
    bowed = s.track("bowed", "bowed_pad", vol=54, pan=40, reverb=110)
    air = s.track("air", "atmosphere", vol=40, pan=90, reverb=120)
    flute = s.track("flute", "shakuhachi", vol=82, pan=52, reverb=120)
    recorder = s.track("recorder", "recorder", vol=68, pan=78, reverb=120)
    drip = s.track("drip", "kalimba", vol=40, pan=80, reverb=120, human=0.0)
    harp = s.track("harp", "harp", vol=52, pan=30, reverb=120)
    cb = s.track("contrabass", "contrabass", vol=62, pan=64, reverb=100)
    ch = prog("Dm:8 Bb:8 Gm:8 Asus4:4 A:4", 4)
    t = 0.0
    phrases = [
        (flute, "D5:1.5 C5:.5 A4:2 | G4:1 A4:1 F4:2 | E4:4 | r:4"),
        (recorder, "A4:1 Bb4:1 A4:2 | G4:2 E4:2 | D4:4 | r:4"),
        (flute, "F4:1 G4:1 A4:1 C5:1 | D5:3 C5:1 | A4:4 | r:4"),
        (recorder, "E5:2 D5:1 C5:1 | A4:2 G4:2 | A4:4 | r:4"),
    ]
    rng = np.random.default_rng(16)
    penta = [pitch(n) for n in ("D5", "F5", "G5", "A5", "C6", "D6")]
    for rnd in range(2):
        pad(padt, t, ch, "D3", 4, v=56)
        pad(bowed, t, ch, "A3", 2, v=44)
        bass(cb, t, ch, "D2", v=50, legato=1.0)
        air.note(t, 32, "D4", 40, 1.0)
        padt.swell(t, t + 16, 70, 120)
        padt.swell(t + 16, t + 32, 120, 80)
        for i, (tr, ph) in enumerate(phrases):
            if rnd == 1:  # во втором круге фразы меняются инструментами
                tr = recorder if tr is flute else flute
            tr.seq(t + 8 * i, ph, v=70 - 6 * rnd, legato=1.0)
        for k in range(14):
            x = t + float(rng.uniform(0, 32))
            drip.note(x, 1, int(rng.choice(penta)), int(rng.integers(30, 60)), 1.0)
        for x in (t + 6, t + 22):
            arp(harp, x, prog("Dm", 2), "D4", [0, 1, 2, 3], step=0.5, v=40, legato=3.0)
        t += 32
    return s, t, True


# --- Обычный бой: волки, утопленники, гоблины -------------------------------------------

def combat():
    s = Song("combat", 138, 4, seed=17)
    strings = s.track("strings", "strings", vol=100, pan=46, reverb=50, human=0.004)
    cello = s.track("cello", "cello", vol=100, pan=60, reverb=50, human=0.004)
    fiddle = s.track("fiddle", "fiddle", vol=96, pan=74, reverb=60)
    horns = s.track("horns", "french_horn", vol=96, pan=58, reverb=80)
    brass = s.track("brass", "brass", vol=88, pan=64, reverb=70)
    taiko = s.track("taiko", "taiko", vol=110, pan=64, reverb=50, human=0.003)
    timp = s.track("timpani", "timpani", vol=96, pan=64, reverb=60, human=0.003)
    drum = s.drums(vol=100, reverb=50)

    def ostinato(t0, chords, v=74):
        pat = [0, 0, 12, 0, 10, 0, 7, 3]
        for t, c, d in chords_over(chords):
            r = chord_root(c, "E3")
            for k in range(int(d * 2)):
                p = r + pat[k % 8]
                strings.note(t0 + t + k * 0.5, 0.5, p, v + (14 if k % 4 == 0 else 0), 0.55)
            cr = chord_root(c, "E2")
            for k in range(int(d * 2)):
                cello.note(t0 + t + k * 0.5, 0.5, cr, v - 2 + (10 if k % 2 == 0 else 0), 0.6)

    def drums(t0, bars, full=True):
        for b in range(bars):
            x = t0 + b * 4
            for off, v in ((0, 110), (1.5, 80), (2.0, 96), (3.0, 86), (3.5, 70)):
                taiko.note(x + off, 0.5, "C3", v, 0.9)
            drum.hit(x, "kick", 100)
            drum.hit(x + 2, "kick", 88)
            if full:
                drum.hit(x + 1, "low_tom", 70)
                drum.hit(x + 3, "mid_tom", 72)
                drum.hit(x + 3.5, "mid_tom", 60)
            drum.hit(x + 0.5, "shaker", 40)
            drum.hit(x + 2.5, "shaker", 40)
            if b % 4 == 3:
                for k in range(4):
                    drum.hit(x + 2 + k * 0.5, "hi_tom" if k % 2 else "mid_tom", 70 + k * 8)

    a = prog("Em Em C D Em Em C B", 4)
    b_ch = prog("Em D C B Em D C B", 4)
    c_ch = prog("Am Em C D Am Em B B", 4)
    b_mel = ("E5:1 B4:.5 E5:.5 G5:1 F#5:1 | E5:1 D5:.5 B4:.5 A4:2 | G4:1 A4:.5 B4:.5 C5:1 B4:1 | "
             "A4:.5 G4:.5 F#4:1 D#4:2 | E4:1 G4:.5 B4:.5 E5:1 G5:1 | F#5:1.5 E5:.5 D5:1 A4:1 | "
             "G4:1 C5:1 B4:1 A4:1 | B4:4")
    c_mel = "A4:2 C5:2 | B4:2 E4:2 | G4:2 E5:2 | D5:2 A4:2 | C5:2 E5:2 | G5:2 E5:2 | D#5:2 F#5:2 | B4:4"
    t = 0.0
    ostinato(t, a)
    drums(t, 8, full=False)
    horns.seq(t + 16, "E4:4 | E4:4 | C4:4 | B3:4", v=80, legato=1.0)
    timp.note(t + 28, 4, "B1", 90, 1.0)
    t += 32
    ostinato(t, b_ch)
    drums(t, 8)
    fiddle.seq(t, b_mel, v=92, legato=0.9)
    horns.seq(t, b_mel, v=74, legato=0.9, octave=-1)
    brass.swell(t, t + 32, 80, 115)
    pad(brass, t, b_ch, "B3", 3, v=58, legato=0.5)
    drum.hit(t, "crash", 96)
    t += 32
    ostinato(t, c_ch, v=80)
    drums(t, 8)
    horns.seq(t, c_mel, v=96, legato=0.98)
    brass.seq(t, c_mel, v=80, legato=0.98, octave=-1)
    fiddle.seq(t, " | ".join(["E5:.5 B4:.5 E5:.5 G5:.5 F#5:.5 E5:.5 D5:.5 B4:.5"] * 6
                             + ["D#5:.5 F#5:.5 B5:.5 F#5:.5 D#5:.5 B4:.5 F#4:.5 B4:.5"] * 2),
               v=70, legato=0.8)
    drum.hit(t, "crash", 84)
    drum.hit(t + 16, "crash2", 76)
    t += 32
    # D: тема снова, теперь у меди, фидл играет подголосок восьмыми
    ostinato(t, b_ch, v=78)
    drums(t, 8)
    brass.seq(t, b_mel, v=88, legato=0.95, octave=-1)
    horns.seq(t, b_mel, v=80, legato=0.95, octave=-1)
    fiddle.seq(t, " | ".join(["B4:.5 E5:.5 G5:.5 E5:.5 B5:.5 G5:.5 E5:.5 G5:.5",
                              "A4:.5 D5:.5 F#5:.5 D5:.5 A5:.5 F#5:.5 D5:.5 F#5:.5",
                              "G4:.5 C5:.5 E5:.5 C5:.5 G5:.5 E5:.5 C5:.5 E5:.5",
                              "F#4:.5 B4:.5 D#5:.5 B4:.5 F#5:.5 D#5:.5 B4:.5 D#5:.5"] * 2),
               v=66, legato=0.8)
    for k in range(8):
        timp.note(t + 30 + k * 0.25, 0.25, "B1", 70 + k * 6, 0.9)
    t += 32
    return s, t, True


# --- Лагерь гоблинов на Кривом Кургане --------------------------------------------------

def goblin_camp():
    s = Song("goblin_camp", 100, 4, seed=18)
    bassoon = s.track("bassoon", "bassoon", vol=100, pan=56, reverb=60)
    clar = s.track("clarinet", "clarinet", vol=80, pan=76, reverb=60)
    pizz = s.track("pizz", "pizzicato", vol=96, pan=40, reverb=50)
    tuba = s.track("tuba", "tuba", vol=90, pan=64, reverb=50)
    chant = s.track("chant", "choir", vol=92, pan=70, reverb=70, human=0.004)
    taiko = s.track("taiko", "taiko", vol=104, pan=64, reverb=50, human=0.003)
    xylo = s.track("xylo", "xylophone", vol=70, pan=86, reverb=60)
    drum = s.drums(vol=96, reverb=45)
    riff = ("D3:.5 r:.5 D3:.5 Eb3:.5 D3:.5 r:.5 C3:.5 r:.5 | D3:.5 F3:.5 Eb3:.5 D3:.5 C#3:1 r:1 | "
            "D3:.5 r:.5 D3:.5 Eb3:.5 F3:.5 G3:.5 A3:.5 r:.5 | Bb3:.5 A3:.5 G3:.5 F3:.5 Eb3:.5 D3:.5 C#3:.5 D3:.5")
    ch = prog("Dm Dm Dm A", 4)

    def groove(t0, bars, heavy=False):
        for b in range(bars):
            x = t0 + b * 4
            for off, v in ((0, 110), (1.5, 76), (2, 96), (3.5, 70)):
                taiko.note(x + off, 0.5, "C3", v, 0.9)
            for k in range(8):
                drum.hit(x + k * 0.5, "low_wood" if k % 2 else "hi_wood", 54 if k % 2 else 40)
            drum.hit(x + 1, "low_bongo", 70)
            drum.hit(x + 3, "low_bongo", 70)
            if heavy:
                drum.hit(x, "kick", 96)
                drum.hit(x + 2, "kick", 90)
            if b % 4 == 3:
                for k in range(6):
                    drum.hit(x + 2.5 + k * 0.25, "low_conga" if k % 2 else "hi_bongo", 70 + 5 * k)

    def tuba_line(t0, chords):
        for t, c, d in chords_over(chords):
            r = chord_root(c, "D2")
            for k in range(int(d)):
                tuba.note(t0 + t + k, 0.5, r if k % 2 == 0 else r - 5, 86, 0.7)

    t = 0.0
    groove(t, 4)
    tuba_line(t, ch)
    t += 16
    for rnd in range(2):
        bassoon.seq(t, riff, v=96, legato=0.6)
        pizz.seq(t, riff, v=84, legato=0.5, octave=1)
        if rnd == 1:
            clar.seq(t, riff, v=74, legato=0.5, octave=1)
            xylo.seq(t, riff, v=64, legato=0.5, octave=2)
        tuba_line(t, ch)
        groove(t, 4, heavy=rnd == 1)
        t += 16
        # Распев «гоблинов»: хор отрывисто на сильные доли
        for b in range(4):
            x = t + b * 4
            chant.seq(x, "D3:.5! r:.5 D3:.5 r:.5 F3:.5! r:.5 Eb3:1" if b % 2 == 0
                      else "D3:.5! r:.5 C3:.5 r:.5 C#3:1 D3:.5! r:.5", v=88, legato=0.6)
            chant.seq(x, "A3:.5 r:.5 A3:.5 r:.5 A3:.5 r:.5 Bb3:1" if b % 2 == 0
                      else "A3:.5 r:.5 G3:.5 r:.5 E3:1 F3:.5 r:.5", v=70, legato=0.6)
        pizz.seq(t, "D4:.5 r:1.5 D4:.5 r:1.5 | Eb4:.5 r:1.5 D4:.5 r:1.5 | "
                 "D4:.5 r:1.5 F4:.5 r:1.5 | C#4:.5 r:.5 E4:.5 r:.5 A3:1 r:1", v=80, legato=0.5)
        tuba_line(t, ch)
        groove(t, 4, heavy=True)
        t += 16
    return s, t, True


# --- Босс: шаман Мухоглот и ходячее тело Ладо ------------------------------------------

def _distort(p):
    """Искажение темы Ладо: си -> си-бемоль, ми -> ми-бемоль, до -> до-диез."""
    pc = p % 12
    return p + {11: -1, 4: -1, 0: 1}.get(pc, 0)


def boss_lado():
    s = Song("boss_lado", 138, 3, seed=19)
    xylo = s.track("xylophone", "xylophone", vol=96, pan=80, reverb=60)
    bassoon = s.track("bassoon", "bassoon", vol=86, pan=50, reverb=60)
    brass = s.track("brass", "brass", vol=100, pan=60, reverb=80)
    choir = s.track("choir", "choir", vol=86, pan=70, reverb=100)
    organ = s.track("organ", "church_organ", vol=70, pan=64, reverb=100)
    strings = s.track("strings", "strings", vol=92, pan=44, reverb=70, human=0.004)
    trem = s.track("tremolo", "tremolo_strings", vol=70, pan=84, reverb=90)
    cb = s.track("contrabass", "contrabass", vol=100, pan=64, reverb=60)
    timp = s.track("timpani", "timpani", vol=104, pan=64, reverb=70, human=0.003)
    drum = s.drums(vol=96, reverb=60)
    melody = " | ".join(LADO)
    chords = prog("Dm Dm Gm Dm  Dm Eb Bb Eb  A Eb A7 A  Dm Gm Bb:2 A7:1 Dm", 3)

    def oompah(t0, chords, v=74):
        """Вальс смерти: бас на раз, отрывистые аккорды на два и три."""
        for t, c, d in chords_over(chords):
            if d < 3:  # аккорд внутри такта: только отрывистый аккорд
                strings.chord(t0 + t, d, voicing(c, "D4", 3), v, 0.35)
                continue
            r = chord_root(c, "D2")
            for bar in range(int(d // 3)):
                x = t0 + t + bar * 3
                cb.note(x, 1, r, v + 14, 0.7)
                timp.note(x, 1, chord_root(c, "A1"), v + 6, 0.8)
                for beat in (1, 2):
                    strings.chord(x + beat, 1, voicing(c, "D4", 3), v, 0.35)

    t = 0.0
    oompah(t, prog("Dm Dm Eb A7", 3))
    drum.hit(t, "china", 70)
    t += 12
    # Проведение 1: ксилофон-кости и фагот, «шаманский» вариант
    xylo.seq(t, melody, v=90, fn=_distort, legato=0.5)
    bassoon.seq(t, melody, v=80, octave=-1, fn=_distort, legato=0.7)
    oompah(t, chords)
    t += 48
    # Проведение 2: медь, хор и орган во всю силу
    brass.seq(t, melody, v=100, fn=_distort, legato=0.95)
    choir.seq(t, melody, v=90, octave=-1, fn=_distort, legato=0.98)
    pad(organ, t, chords, "A3", 3, v=66)
    trem.seq(t, " | ".join(["D6:3"] * 4 + ["Eb6:3"] * 4 + ["E6:3"] * 4 + ["D6:3"] * 4), v=54, legato=1.0)
    oompah(t, chords, v=82)
    for bar in range(0, 16, 4):
        drum.hit(t + bar * 3, "crash", 92)
    t += 48
    # Связка: хроматический подъём над педалью ля
    bridge = ("A3 Bb3 A3 | C#4 D4 C#4 | E4 F4 E4 | G4 A4 G4 | "
              "Bb4 A4 G4 | F4 Eb4 D4 | C#4:3 | E4:3")
    strings.seq(t, bridge, v=90, legato=0.9, octave=1)
    brass.seq(t, bridge, v=84, legato=0.9)
    for bar in range(8):
        cb.note(t + bar * 3, 1, "A1", 96, 0.7)
        timp.note(t + bar * 3, 1, "A1", 90, 0.8)
        if bar >= 6:
            for k in range(6):
                timp.note(t + bar * 3 + k * 0.5, 0.5, "A1", 60 + k * 6, 0.9)
    choir.seq(t, "A3:12 | Bb3:6 | A3:6", v=70, legato=1.0)
    t += 24
    return s, t, True


# --- Погребальный костёр, прощание с призраком Ладо -------------------------------------

def farewell():
    s = Song("farewell", 72, 3, seed=20)
    violin = s.track("violin", "violin", vol=96, pan=60, reverb=90)
    strings = s.track("strings", "strings", vol=86, pan=64, reverb=100)
    cello = s.track("cello", "cello", vol=84, pan=52, reverb=90)
    horns = s.track("horns", "french_horn", vol=80, pan=56, reverb=100)
    choir = s.track("choir", "choir", vol=74, pan=72, reverb=110)
    harp = s.track("harp", "harp", vol=78, pan=84, reverb=100)
    lute = s.track("lute", "nylon_guitar", vol=80, pan=40, reverb=80)
    cb = s.track("contrabass", "contrabass", vol=80, pan=64, reverb=90)
    timp = s.track("timpani", "timpani", vol=76, pan=64, reverb=90)
    melody, chords = lado_all()
    t = 0.0
    arp(harp, t, prog("Dm Bb", 3), "D3", [0, 1, 2, 3, 4, 5], step=0.5, v=60, legato=2.5)
    t += 6
    # Проведение 1: сольная скрипка, лютня и арфа
    violin.seq(t, melody, v=84, legato=0.98)
    arp(lute, t, chords, "D3", [0, 2, 3, 4, 3, 2], bass_low="D2", v=54)
    bass(cello, t, chords, "D2", v=56, legato=1.0)
    pad(strings, t, chords, "F3", 3, v=36)
    t += 48
    # Проведение 2: весь оркестр, струнные октавой, валторны вторым голосом
    strings.seq(t, melody, v=92, octave=1, legato=1.0)
    violin.seq(t, melody, v=80, legato=1.0)
    horns.seq(t, " | ".join(LADO_COUNTER), v=72, legato=1.0)
    pad(choir, t, chords, "A3", 3, v=56)
    choir.swell(t, t + 36, 70, 120)
    arp(harp, t, chords, "D3", [0, 1, 2, 3, 4, 5], step=0.5, v=56, legato=2.5)
    bass(cb, t, chords, "D2", v=70, legato=1.0)
    bass(cello, t, chords, "D3", v=62, legato=1.0)
    for x in (t + 36, t + 45):
        for k in range(6):
            timp.note(x + k * 0.5, 0.5, "A1", 50 + k * 8, 0.9)
    t += 48
    # Светлый конец: ре мажор (пикардийская терция)
    end = prog("Bb:3 A:3 D:6", 3)
    pad(strings, t, end, "F#3", 4, v=66)
    pad(choir, t, end, "A3", 3, v=60)
    horns.seq(t, "D4:3 | C#4:3 | D4:6", v=70, legato=1.0)
    violin.seq(t, "F5:1.5 E5:1.5 | E5:3 | F#5:6", v=78, legato=1.0)
    bass(cb, t, end, "D2", v=66, legato=1.0)
    arp(harp, t + 6, prog("D:6", 3), "D3", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], step=0.25,
        v=50, legato=4.0)
    timp.note(t + 6, 3, "D2", 70, 1.0)
    t += 12
    return s, t, True


# --- Эпилог: пустой дом священника ------------------------------------------------------

def epilogue():
    s = Song("epilogue", 50, 4, seed=21)
    drone = s.track("drone", "warm_pad", vol=72, pan=64, reverb=120)
    bowed = s.track("bowed", "bowed_pad", vol=60, pan=40, reverb=120)
    cel = s.track("celesta", "celesta", vol=70, pan=80, reverb=127)
    cb = s.track("contrabass", "contrabass", vol=60, pan=64, reverb=110)
    trem = s.track("tremolo", "tremolo_strings", vol=36, pan=90, reverb=120)
    t = 0.0
    ch = prog("Dm:8 Gm:4 Eb:4 Dm:8 Bbm:4 A:4", 4)
    pad(drone, t, ch, "D3", 3, v=58)
    pad(bowed, t, ch, "A3", 2, v=46)
    bass(cb, t, ch, "D2", v=46, legato=1.0)
    # Обрывки темы Ладо, медленно и неуверенно, как воспоминание
    cel.seq(t + 4, "D5:1 F5:1 G5:1 | A5:3 r:3", v=56, legato=1.0)
    cel.seq(t + 14, "D6:1.5 C6:.5 A5:1 | G5:1 F5:1 Eb5:2 r:4", v=50, legato=1.0)
    cel.seq(t + 24, "A5:1 C#6:1 D6:1 | Eb6:4 r:4", v=46, legato=1.0)
    trem.seq(t + 16, "Eb5:8 | D5:8", v=40, legato=1.0)
    t += 32
    ch2 = prog("Gm:8 Dm:8 Eb:8 A:8", 4)
    pad(drone, t, ch2, "D3", 3, v=54)
    pad(bowed, t, ch2, "A3", 2, v=42)
    bass(cb, t, ch2, "D2", v=42, legato=1.0)
    cel.seq(t + 6, "Bb5:1 A5:1 G5:1 | D5:4 r:2", v=48, legato=1.0)
    cel.seq(t + 18, "F5:1.5 Eb5:.5 D5:1 | C#5:3 r:3", v=44, legato=1.0)
    trem.seq(t + 24, "C#5:8", v=36, legato=1.0)
    t += 32
    s.post.append(bell_layer([(0, 1.0)], freq=110.0, level=4.0, decay=6.0, seed=21))
    return s, t, True


# --- Стингеры -------------------------------------------------------------------------

def omen():
    """Колокол бьёт сам, земля гудит, гроб трескается, мертвецы встают."""
    s = Song("omen", 60, 4, seed=31)
    choir = s.track("choir", "choir", vol=100, pan=64, reverb=110)
    trem = s.track("tremolo", "tremolo_strings", vol=100, pan=50, reverb=90)
    brass = s.track("brass", "brass", vol=110, pan=64, reverb=90)
    organ = s.track("organ", "church_organ", vol=80, pan=64, reverb=110)
    timp = s.track("timpani", "timpani", vol=110, pan=64, reverb=90)
    drum = s.drums(vol=110, reverb=90)
    choir.chord(2.4, 3.2, [pitch("D4"), pitch("Eb4"), pitch("A4")], 70, 1.0)
    choir.swell(2.4, 5.4, 40, 127)
    trem.chord(2.0, 3.6, [pitch("D2"), pitch("Eb2"), pitch("D3")], 80, 1.0)
    trem.swell(2.0, 5.4, 30, 127)
    for k in range(24):
        timp.note(3.6 + k * 0.075, 0.075, "D2", 40 + k * 3, 1.0)
    brass.chord(5.4, 2.4, [pitch("D2"), pitch("D3"), pitch("Eb3"), pitch("A3")], 120, 1.0)
    organ.chord(5.4, 4.0, [pitch("D2"), pitch("A2"), pitch("Eb3"), pitch("D4")], 100, 1.0)
    organ.swell(5.4, 9.4, 127, 30)
    timp.note(5.4, 1.5, "D2", 127, 1.0)
    drum.hit(5.4, "kick2", 127)
    drum.hit(5.4, "crash", 110)
    drum.hit(5.4, "china", 100)

    def layers(audio, song, body):
        rng = np.random.default_rng(31)
        ref = ref_rms(audio[:body])
        b1 = norm_peak(dsp.lp(dsp.bell(146.8, 9.0, decay=4.5, rng=rng), 6000))
        b2 = norm_peak(dsp.lp(dsp.bell(138.6, 8.0, decay=4.0, rng=rng), 5000))  # второй удар ниже, фальшиво
        dsp.place(audio, dsp.pan(b1, -0.15) * ref * 4.0, 0.0)
        dsp.place(audio, dsp.pan(b2, 0.15) * ref * 3.5, 1.6)
        n = int(6.5 * dsp.SR)
        env = dsp.env_points(6.5, [(0, 0), (3.0, 0.6), (3.8, 1.0), (5.0, 0.8), (6.5, 0)])
        rumble = dsp.lp(dsp.brown(6.5, rng), 110, 4)
        rumble = rumble / ref_rms(rumble) * env * (1 + 0.4 * np.sin(2 * np.pi * 7 * np.arange(n) / dsp.SR))
        dsp.place(audio, dsp.pan(rumble, 0) * ref * 1.2, 1.4)
        crack = norm_peak(_wood_crack(rng, 1.4))
        dsp.place(audio, dsp.pan(crack, 0.1) * ref * 4.0, 5.35)
        return audio

    s.post.append(layers)
    return s, 9.6, False


def _wood_crack(rng, dur):
    """Треск дерева: пачка щелчков через деревянные резонансы."""
    n = int(dur * dsp.SR)
    x = np.zeros(n)
    t = 0.0
    while t < dur * 0.7:
        i = int(t * dsp.SR)
        burst = rng.normal(0, 1, 160) * np.exp(-np.arange(160) / 30)
        x[i:i + 160] += burst[: max(0, min(160, n - i))] * rng.uniform(0.3, 1.0) * np.exp(-t * 3)
        t += rng.exponential(0.018)
    body = dsp.resonators(x, [180, 420, 910, 1650, 2900], q=9, gains=[1.0, 0.8, 0.6, 0.4, 0.3])
    return dsp.drive(body * 3, 1.5) * dsp.env_exp(dur, 0.35)


def victory():
    s = Song("victory", 112, 4, seed=32)
    brass = s.track("brass", "brass", vol=110, pan=64, reverb=70)
    trumpet = s.track("trumpet", "trumpet", vol=100, pan=56, reverb=70)
    horns = s.track("horns", "french_horn", vol=96, pan=70, reverb=80)
    trem = s.track("tremolo", "tremolo_strings", vol=86, pan=44, reverb=80)
    timp = s.track("timpani", "timpani", vol=104, pan=64, reverb=70)
    drum = s.drums(vol=100, reverb=70)
    # Начало темы Ладо в ре мажоре
    trumpet.seq(0, "D5:.5 F#5:.5 G5:.5 | A5:1.5 B5:.5 A5:1 | D6:4", v=104, legato=0.9)
    horns.seq(0, "A4:.5 D5:.5 E5:.5 | F#5:1.5 G5:.5 F#5:1 | F#5:4", v=88, legato=0.9)
    brass.chord(1.5, 1.5, voicing("D", "D3", 4), 96, 0.95)
    brass.chord(3.0, 1.0, voicing("G", "D3", 4), 96, 0.95)
    brass.chord(4.0, 4.0, voicing("D", "D3", 5), 110, 1.0)
    trem.chord(0, 8, voicing("D", "A3", 4), 76, 1.0)
    for k in range(6):
        timp.note(k * 0.25, 0.25, "A1", 60 + 8 * k, 0.9)
    timp.note(1.5, 1, "D2", 110, 0.9)
    timp.note(4.0, 2, "D2", 120, 0.9)
    drum.hit(4.0, "crash", 110)
    drum.hit(4.0, "kick2", 110)
    return s, 8.0, False


def defeat():
    s = Song("defeat", 56, 4, seed=33)
    horns = s.track("horns", "french_horn", vol=96, pan=56, reverb=100)
    strings = s.track("strings", "slow_strings", vol=96, pan=64, reverb=110)
    cb = s.track("contrabass", "contrabass", vol=96, pan=64, reverb=100)
    choir = s.track("choir", "choir", vol=70, pan=70, reverb=110)
    timp = s.track("timpani", "timpani", vol=90, pan=64, reverb=100)
    # Конец темы Ладо, медленно и вниз
    horns.seq(0, "F4:1 D4:1 E4:1 | D4:1 C4:1 A3:1 | D3:5", v=86, legato=1.0)
    strings.chord(0, 3, voicing("Gm", "D3", 3), 66, 1.0)
    strings.chord(3, 3, voicing("A7", "C#3", 4), 70, 1.0)
    strings.chord(6, 5, voicing("Dm", "D3", 4), 74, 1.0)
    strings.swell(6, 11, 120, 40)
    choir.chord(6, 5, voicing("Dm", "A3", 3), 60, 1.0)
    cb.note(0, 3, "G1", 76, 1.0)
    cb.note(3, 3, "A1", 76, 1.0)
    cb.note(6, 5, "D1", 86, 1.0)
    timp.note(6, 2, "D2", 96, 1.0)
    return s, 11.0, False


def level_up():
    s = Song("level_up", 120, 4, seed=34)
    harp = s.track("harp", "harp", vol=100, pan=40, reverb=90, human=0.0)
    glock = s.track("glock", "glockenspiel", vol=86, pan=80, reverb=100)
    brass = s.track("brass", "brass", vol=84, pan=64, reverb=90)
    choir = s.track("choir", "choir", vol=80, pan=64, reverb=110)
    crystal = s.track("crystal", "crystal", vol=60, pan=64, reverb=110)
    scale = ["D4", "E4", "F#4", "G4", "A4", "B4", "C#5", "D5", "E5", "F#5", "G5", "A5", "B5", "C#6", "D6"]
    for i, n in enumerate(scale):
        harp.note(i * 0.07, 2.0, n, 60 + i * 3, 1.0)
    x = len(scale) * 0.07
    glock.seq(x, "D6:.25 F#6:.25 A6:.25 D7:2", v=90, legato=1.0)
    brass.chord(x, 3, voicing("D", "D4", 4), 84, 1.0)
    choir.chord(x, 3, voicing("D", "A3", 4), 76, 1.0)
    crystal.note(x, 3, "D6", 70, 1.0)
    return s, x + 4.0, False


def quest():
    s = Song("quest", 96, 4, seed=35)
    harp = s.track("harp", "harp", vol=96, pan=40, reverb=90)
    flute = s.track("flute", "flute", vol=90, pan=70, reverb=100)
    cel = s.track("celesta", "celesta", vol=70, pan=80, reverb=100)
    strings = s.track("strings", "slow_strings", vol=70, pan=64, reverb=100)
    harp.seq(0, "A4:.5 D5:.5 F5:.5 A5:2", v=80, legato=2.0)
    flute.seq(0.5, "D5:.5 E5:.5 F5:.5 A5:1.5", v=80, legato=1.0)
    cel.note(1.5, 1.5, "D6", 60, 1.0)
    strings.chord(0, 3.5, voicing("Dm", "D4", 3), 56, 1.0)
    return s, 4.5, False


def quest_done():
    s = Song("quest_done", 100, 4, seed=36)
    brass = s.track("brass", "brass", vol=96, pan=64, reverb=80)
    harp = s.track("harp", "harp", vol=96, pan=40, reverb=90)
    glock = s.track("glock", "glockenspiel", vol=80, pan=80, reverb=100)
    strings = s.track("strings", "strings", vol=86, pan=60, reverb=90)
    timp = s.track("timpani", "timpani", vol=96, pan=64, reverb=90)
    brass.seq(0, "A4:.5 D5:.5 F#5:.5 | A5:3", v=96, legato=0.95)
    brass.chord(1.5, 3, voicing("D", "D4", 3), 80, 1.0)
    harp.seq(0, "D4:.25 F#4:.25 A4:.25 D5:.25 F#5:.25 A5:.25 D6:2", v=76, legato=2.0)
    glock.seq(1.5, "F#6:.5 A6:.5 D7:2", v=80, legato=1.0)
    strings.chord(1.5, 3, voicing("D", "A3", 4), 76, 1.0)
    strings.note(0, 1.5, "A3", 70, 1.0)
    timp.note(1.5, 1, "D2", 100, 0.9)
    return s, 5.5, False


MUSIC = {
    "theme_lado": theme_lado, "funeral": funeral, "combat_undead": combat_undead,
    "village": village, "tavern": tavern, "forest": forest, "combat": combat,
    "goblin_camp": goblin_camp, "boss_lado": boss_lado, "farewell": farewell, "epilogue": epilogue,
}
STINGERS = {
    "omen": omen, "victory": victory, "defeat": defeat, "level_up": level_up,
    "quest": quest, "quest_done": quest_done,
}
