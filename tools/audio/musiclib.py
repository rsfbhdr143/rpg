"""Мини-нотация для музыки: партитура в коде -> MIDI -> FluidSynth -> обработка -> OGG.

Время везде в долях (четвертях). Ноты пишутся строкой: "A4:2 G4 F4 | E4:1.5 F4:.5 D4:2".
  A4:2   нота ля первой октавы длиной 2 доли
  G4     длина как у предыдущей ноты
  r:1    пауза
  A4!    акцент (громче)
  |      черта такта, ничего не делает
"""

import os
import random
import subprocess
import tempfile
import warnings

import mido
import numpy as np
from scipy.io import wavfile

from dsp import SR, master, soft_limit

TPB = 480
SOUNDFONT = os.environ.get("RPG_SOUNDFONT", "/usr/share/sounds/sf2/FluidR3_GM.sf2")

# Номера инструментов General MIDI (с нуля).
GM = {
    "piano": 0, "celesta": 8, "glockenspiel": 9, "music_box": 10, "vibraphone": 11,
    "xylophone": 13, "tubular_bells": 14, "dulcimer": 15, "church_organ": 19, "reed_organ": 20,
    "accordion": 21, "nylon_guitar": 24, "steel_guitar": 25, "acoustic_bass": 32,
    "violin": 40, "viola": 41, "cello": 42, "contrabass": 43, "tremolo_strings": 44,
    "pizzicato": 45, "harp": 46, "timpani": 47, "strings": 48, "slow_strings": 49,
    "choir": 52, "voice_oohs": 53, "orchestra_hit": 55, "trumpet": 56, "trombone": 57,
    "tuba": 58, "french_horn": 60, "brass": 61, "oboe": 68, "english_horn": 69,
    "bassoon": 70, "clarinet": 71, "piccolo": 72, "flute": 73, "recorder": 74,
    "pan_flute": 75, "shakuhachi": 77, "whistle": 78, "ocarina": 79, "warm_pad": 89,
    "choir_pad": 91, "bowed_pad": 92, "halo_pad": 94, "sweep_pad": 95, "crystal": 98,
    "atmosphere": 99, "goblins": 101, "echoes": 102, "sitar": 104, "banjo": 105,
    "kalimba": 108, "bagpipe": 109, "fiddle": 110, "tinkle_bell": 112, "woodblock": 115,
    "taiko": 116, "melodic_tom": 117, "reverse_cymbal": 119, "breath": 121, "seashore": 122,
}

# Ударные на 10-м канале (номера нот General MIDI).
DR = {
    "kick": 36, "kick2": 35, "stick": 37, "snare": 38, "clap": 39, "low_tom": 41,
    "hat": 42, "mid_tom": 45, "hi_tom": 48, "crash": 49, "ride": 51, "china": 52,
    "tambourine": 54, "splash": 55, "cowbell": 56, "crash2": 57, "hi_bongo": 60,
    "low_bongo": 61, "low_conga": 64, "claves": 75, "hi_wood": 76, "low_wood": 77,
    "triangle": 81, "shaker": 82, "jingle": 83, "chimes": 84, "castanets": 85,
}

_NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

CHORD_TYPES = {
    "": [0, 4, 7], "m": [0, 3, 7], "7": [0, 4, 7, 10], "m7": [0, 3, 7, 10],
    "maj7": [0, 4, 7, 11], "dim": [0, 3, 6], "m7b5": [0, 3, 6, 10], "dim7": [0, 3, 6, 9],
    "sus4": [0, 5, 7], "sus2": [0, 2, 7], "aug": [0, 4, 8], "5": [0, 7],
    "add9": [0, 4, 7, 14], "madd9": [0, 3, 7, 14], "7b9": [0, 4, 7, 10, 13], "6": [0, 4, 7, 9],
    "m6": [0, 3, 7, 9],
}


def pitch(name):
    """'C#4' -> 61, 'Bb3' -> 58. Число возвращается как есть."""
    if isinstance(name, (int, np.integer)):
        return int(name)
    letter = name[0].upper()
    i, acc = 1, 0
    while i < len(name) and name[i] in "#b":
        acc += 1 if name[i] == "#" else -1
        i += 1
    return 12 * (int(name[i:]) + 1) + _NOTE[letter] + acc


def parse_chord(name):
    """'F#m7' -> (6, [0, 3, 7, 10]). Бас через '/', например 'C/E', возвращается третьим."""
    bass = None
    if "/" in name:
        name, b = name.split("/")
        bass = (_NOTE[b[0].upper()] + (1 if "#" in b else -1 if "b" in b[1:] else 0)) % 12
    letter = name[0].upper()
    i, acc = 1, 0
    while i < len(name) and name[i] in "#b":
        acc += 1 if name[i] == "#" else -1
        i += 1
    quality = name[i:]
    if quality not in CHORD_TYPES:
        raise ValueError(f"неизвестный аккорд {name}")
    return (_NOTE[letter] + acc) % 12, CHORD_TYPES[quality], bass


def voicing(chord, low, count=3):
    """Ноты аккорда снизу вверх, начиная с первой ступени не ниже low."""
    root, intervals, _ = parse_chord(chord)
    pcs = sorted({(root + iv) % 12 for iv in intervals})
    out = []
    p = pitch(low)
    while len(out) < count:
        if p % 12 in pcs:
            out.append(p)
        p += 1
    return out


def chord_root(chord, low):
    """Основной тон (или бас из '/') не ниже low."""
    root, _, bass = parse_chord(chord)
    pc = bass if bass is not None else root
    p = pitch(low)
    while p % 12 != pc:
        p += 1
    return p


def chord_tones(chord):
    root, intervals, _ = parse_chord(chord)
    return [(root + iv) % 12 for iv in intervals]


SCALES = {
    "major": [0, 2, 4, 5, 7, 9, 11], "minor": [0, 2, 3, 5, 7, 8, 10],
    "dorian": [0, 2, 3, 5, 7, 9, 10], "phrygian": [0, 1, 3, 5, 7, 8, 10],
    "harmonic": [0, 2, 3, 5, 7, 8, 11], "mixolydian": [0, 2, 4, 5, 7, 9, 10],
}


def diatonic_shift(p, steps, tonic, scale):
    """Сдвиг ноты на steps ступеней лада (для терций и секст второго голоса)."""
    degrees = SCALES[scale]
    tonic_pc = pitch(tonic) % 12
    rel = (p - tonic_pc) % 12
    octave = (p - tonic_pc) // 12
    # ближайшая ступень снизу (хроматические ноты лада не сдвигаем точно, а округляем)
    idx = max(i for i, d in enumerate(degrees) if d <= rel)
    chroma = rel - degrees[idx]
    idx += steps
    octave += idx // 7
    idx %= 7
    return tonic_pc + 12 * octave + degrees[idx] + chroma


def parse_seq(text, default_dur=1.0):
    """Строка нот -> список (длительность, высота или None, акцент)."""
    out = []
    dur = default_dur
    for tok in text.replace("|", " ").split():
        accent = tok.endswith("!")
        tok = tok.rstrip("!")
        if ":" in tok:
            name, d = tok.split(":")
            dur = float(d)
        else:
            name = tok
        out.append((dur, None if name.lower() == "r" else pitch(name), accent))
    return out


def seq_length(text):
    return sum(d for d, _, _ in parse_seq(text))


class Track:
    def __init__(self, song, name, program, channel, vol=100, pan=64, reverb=50, chorus=0,
                 human=0.012, vel_human=6, bank=0):
        self.song = song
        self.name = name
        self.program = program
        self.channel = channel
        self.vol, self.pan, self.reverb, self.chorus = vol, pan, reverb, chorus
        self.bank = bank
        self.human = human
        self.vel_human = vel_human
        self.notes = []  # (начало, длительность, высота, громкость)
        self.ccs = []  # (время, номер, значение)

    def note(self, t, d, p, v=90, legato=0.95):
        if p is None:
            return t + d
        self.notes.append((t, d * legato, pitch(p), int(v)))
        return t + d

    def chord(self, t, d, pitches, v=80, legato=0.98, strum=0.0):
        for i, p in enumerate(pitches):
            self.note(t + i * strum, d - i * strum, p, v, legato)
        return t + d

    def seq(self, t, text, v=90, legato=0.92, transpose=0, octave=0, accent=14, fn=None):
        """Мелодия из строки. fn(высота) может заменить ноту (для искажений темы)."""
        for d, p, acc in parse_seq(text):
            if p is not None:
                p = p + transpose + 12 * octave
                if fn:
                    p = fn(p)
                self.note(t, d, p, v + (accent if acc else 0), legato)
            t += d
        return t

    def seq_notes(self, t, text, transpose=0):
        """Те же ноты, но списком (начало, длительность, высота) без записи в дорожку."""
        out = []
        for d, p, _ in parse_seq(text):
            if p is not None:
                out.append((t, d, p + transpose))
            t += d
        return out

    def cc(self, t, number, value):
        self.ccs.append((t, number, int(max(0, min(127, value)))))

    def swell(self, t0, t1, v0, v1, number=11, steps=24):
        """Плавное изменение выразительности (CC11) или другого контроллера."""
        for i in range(steps + 1):
            k = i / steps
            self.cc(t0 + (t1 - t0) * k, number, v0 + (v1 - v0) * k)

    def hit(self, t, drum, v=100, d=0.25):
        return self.note(t, d, DR[drum] if isinstance(drum, str) else drum, v, 1.0)


class Song:
    def __init__(self, name, bpm, beats_per_bar=4, seed=1):
        self.name = name
        self.bpm = bpm
        self.bar = beats_per_bar
        self.tracks = []
        self.rng = random.Random(seed)
        self._free_channels = [c for c in range(16) if c != 9]
        self.post = []  # функции (audio, song) -> audio для подмешивания синтезированных слоёв

    def track(self, name, instrument, **kw):
        program = GM[instrument] if isinstance(instrument, str) else instrument
        ch = self._free_channels.pop(0)
        tr = Track(self, name, program, ch, **kw)
        self.tracks.append(tr)
        return tr

    def drums(self, name="drums", kit=0, **kw):
        kw.setdefault("human", 0.006)
        tr = Track(self, name, kit, 9, **kw)
        self.tracks.append(tr)
        return tr

    def beats(self, bars):
        return bars * self.bar

    def sec(self, beats):
        return beats * 60.0 / self.bpm

    def write_midi(self, path, end_beat, tail_sec):
        mid = mido.MidiFile(ticks_per_beat=TPB)
        meta = mido.MidiTrack()
        meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(self.bpm), time=0))
        end_tick = int((end_beat + tail_sec * self.bpm / 60.0) * TPB)
        meta.append(mido.MetaMessage("end_of_track", time=end_tick))
        mid.tracks.append(meta)
        rng = self.rng
        for tr in self.tracks:
            ev = []
            ch = tr.channel
            if ch == 9:
                ev.append((0, 0, mido.Message("program_change", channel=ch, program=tr.program)))
            else:
                ev.append((0, 0, mido.Message("control_change", channel=ch, control=0, value=tr.bank)))
                ev.append((0, 0, mido.Message("program_change", channel=ch, program=tr.program)))
            for num, val in ((7, tr.vol), (10, tr.pan), (91, tr.reverb), (93, tr.chorus), (11, 127)):
                ev.append((0, 0, mido.Message("control_change", channel=ch, control=num, value=val)))
            for t, num, val in tr.ccs:
                ev.append((int(t * TPB), 1, mido.Message("control_change", channel=ch, control=num, value=val)))
            for t, d, p, v in tr.notes:
                jitter = rng.gauss(0, tr.human) * self.bpm / 60.0 if tr.human else 0.0
                start = max(0.0, t + jitter)
                vel = int(max(1, min(127, v + rng.randint(-tr.vel_human, tr.vel_human))))
                on = int(start * TPB)
                off = max(on + 1, int((start + d) * TPB))
                ev.append((on, 2, mido.Message("note_on", channel=ch, note=int(p), velocity=vel)))
                ev.append((off, 0, mido.Message("note_off", channel=ch, note=int(p), velocity=0)))
            ev.sort(key=lambda e: (e[0], e[1]))
            mt = mido.MidiTrack()
            last = 0
            for tick, _, msg in ev:
                mt.append(msg.copy(time=tick - last))
                last = tick
            mid.tracks.append(mt)
        mid.save(path)


def render_midi(mid_path, wav_path, gain=0.5, reverb=(0.62, 0.35, 0.9, 0.55)):
    room, damp, width, level = reverb
    cmd = [
        "fluidsynth", "-ni", "-q", "-F", wav_path, "-r", str(SR), "-T", "wav", "-O", "float",
        "-g", str(gain),
        "-o", "synth.reverb.active=1",
        "-o", f"synth.reverb.room-size={room}", "-o", f"synth.reverb.damp={damp}",
        "-o", f"synth.reverb.width={width}", "-o", f"synth.reverb.level={level}",
        "-o", "synth.chorus.active=1", "-o", "synth.polyphony=512",
        SOUNDFONT, mid_path,
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        _, data = wavfile.read(wav_path)
    data = data.astype(np.float32)
    if data.ndim == 1:
        data = np.stack([data, data], axis=1)
    return data


def render_song(song, end_beat, loop=True, tail_sec=4.0, gain=0.5, reverb=None, target_db=-16.0):
    """Рендер песни. loop=True: хвост реверберации переносится в начало, петля бесшовная."""
    with tempfile.TemporaryDirectory() as tmp:
        mid = os.path.join(tmp, "song.mid")
        wav = os.path.join(tmp, "song.wav")
        song.write_midi(mid, end_beat, tail_sec)
        audio = render_midi(mid, wav, gain, reverb or (0.62, 0.35, 0.9, 0.55))
    body = int(round(song.sec(end_beat) * SR))
    if len(audio) < body:
        audio = np.concatenate([audio, np.zeros((body - len(audio), 2), np.float32)])
    for fn in song.post:
        audio = fn(audio, song, body)
    if loop:
        out = audio[:body].copy()
        tail = audio[body:]
        pos = 0
        while pos < len(tail):
            chunk = tail[pos:pos + body]
            out[:len(chunk)] += chunk
            pos += body
        return master(out, target_db=target_db, loop=True)
    return master(audio, target_db=target_db, loop=False)


__all__ = [
    "GM", "DR", "Song", "Track", "pitch", "voicing", "chord_root", "chord_tones", "parse_chord",
    "diatonic_shift", "parse_seq", "seq_length", "render_song", "soft_limit",
]
