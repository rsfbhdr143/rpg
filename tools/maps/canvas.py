import random
from collections import deque

class Canvas:
    def __init__(self, w, h, border='#', seed=1):
        self.w, self.h = w, h
        self.g = [['.' for _ in range(w)] for _ in range(h)]
        self.keep = set()
        self.rng = random.Random(seed)
        for x in range(w):
            self.g[0][x] = border; self.g[h-1][x] = border
        for y in range(h):
            self.g[y][0] = border; self.g[y][w-1] = border

    def put(self, x, y, ch, keep=True):
        assert 0 <= x < self.w and 0 <= y < self.h, (x, y, ch)
        self.g[y][x] = ch
        if keep:
            self.keep.add((x, y))

    def get(self, x, y):
        return self.g[y][x]

    def clear(self, x0, y0, x1, y1):
        """reserve rectangle as keep-clear floor (doesn't overwrite)"""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if 0 < x < self.w - 1 and 0 < y < self.h - 1:
                    self.keep.add((x, y))

    def fill(self, x0, y0, x1, y1, ch, keep=True):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, ch, keep)

    def building(self, x, y, w, h, corner, doors):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                edge = xx in (x, x + w - 1) or yy in (y, y + h - 1)
                self.put(xx, yy, '=' if edge else '_')
        self.put(x, y, corner)
        for (dx, dy) in doors:
            self.put(dx, dy, '+')
        # keep the outside of doors clear
        for (dx, dy) in doors:
            for nx, ny in ((dx + 1, dy), (dx - 1, dy), (dx, dy + 1), (dx, dy - 1)):
                if not (x <= nx < x + w and y <= ny < y + h):
                    self.keep.add((nx, ny))
        # a ring around the house stays clear
        for yy in range(y - 1, y + h + 1):
            for xx in range(x - 1, x + w + 1):
                if 0 < xx < self.w - 1 and 0 < yy < self.h - 1:
                    self.keep.add((xx, yy))

    def footprint(self, x, y, w, h, corner, solid='h'):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.put(xx, yy, solid)
        self.put(x, y, corner)

    def scatter(self, chars, n, x0, y0, x1, y1, tries=4000):
        placed = 0
        t = 0
        while placed < n and t < tries:
            t += 1
            x = self.rng.randint(x0, x1); y = self.rng.randint(y0, y1)
            if (x, y) in self.keep or self.g[y][x] != '.':
                continue
            self.g[y][x] = self.rng.choice(chars)
            placed += 1
        return placed

    def rows(self):
        return [''.join(r) for r in self.g]


def blocked_set(rows, legend):
    """cells that block movement"""
    out = set()
    h = len(rows); w = len(rows[0])
    for y in range(h):
        for x in range(w):
            ch = rows[y][x]
            e = legend.get(ch, {})
            if ch == '#' or e.get('wall') or e.get('solid') or ch == '=':
                out.add((x, y))
            elif ('prop' in e or 'object' in e) and e.get('block', True):
                sz = e.get('size', [1, 1])
                for dx in range(sz[0]):
                    for dy in range(sz[1]):
                        out.add((x + dx, y + dy))
    return out


def check(name, rows, legend, start):
    h = len(rows); w = len(rows[0])
    assert all(len(r) == w for r in rows), name + ': ragged rows'
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            assert ch in legend or ch in '#. =_+', f'{name}: char {ch!r} at {x},{y} not in legend'
    bl = blocked_set(rows, legend)
    seen = {start}
    q = deque([start])
    while q:
        x, y = q.popleft()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                n = (x + dx, y + dy)
                if 0 <= n[0] < w and 0 <= n[1] < h and n not in seen and n not in bl:
                    seen.add(n); q.append(n)
    problems = []
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            e = legend.get(ch, {})
            need = None
            if any(k in e for k in ('spawn', 'exit', 'encounter', 'anchor', 'npc', 'trap')) or ch in '+_':
                need = 'self'
            if 'object' in e or 'npc' in e:
                need = 'near'
            if need == 'self' and (x, y) not in seen and (x, y) not in bl:
                problems.append((ch, x, y, 'unreachable'))
            if need == 'near':
                ok = any((x + dx, y + dy) in seen for dx in (-1, 0, 1) for dy in (-1, 0, 1) if (dx or dy))
                if not ok:
                    problems.append((ch, x, y, 'no reachable neighbour'))
    return problems, len(seen)
