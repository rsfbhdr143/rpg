// Земля локации в изометрии: трава/грязь, поверхности (вода, огонь, яд, лёд...), выходы и подсветка боя.
// Рисуется по пикселям мира: клетка 32×16, всё дизерингом, поэтому выглядит как пиксель-арт.
// Данные приходят маленькими текстурами размером с карту (одна точка = одна клетка):
//   cells_tex: r = 1 непроходимо, g = номер поверхности (палитра surf_pal), b = 1 выход
//   hl_tex:    r = можно дойти, g = дальность навыка, b = область удара, a = путь
//   deco_tex:  r = рисунок на земле (WorldView.DECO): 1 тропа, 2 мостовая, 3 грядки, 4/5 мост вдоль x/y, 6 камни брода
// За краем карты — та же земля, темнеющая к цвету фона (outer_color), чтобы не было чёрных углов.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D cells_tex : filter_nearest;
uniform sampler2D hl_tex : filter_nearest;
uniform sampler2D surf_pal : filter_nearest;
uniform sampler2D deco_tex : filter_nearest;
uniform vec4 path_a : source_color = vec4(0.43, 0.36, 0.24, 1.0);
uniform vec4 path_b : source_color = vec4(0.38, 0.32, 0.23, 1.0);
uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform sampler2D floor_tex : repeat_enable, filter_nearest;
uniform bool use_floor_tex = false;
uniform float floor_tex_cells = 3.0;
uniform ivec2 grid_size = ivec2(10, 10);
uniform vec4 floor_a : source_color = vec4(0.23, 0.26, 0.2, 1.0);
uniform vec4 floor_b : source_color = vec4(0.21, 0.24, 0.18, 1.0);
uniform vec4 floor_dark : source_color = vec4(0.15, 0.17, 0.13, 1.0);
uniform vec4 floor_light : source_color = vec4(0.3, 0.33, 0.24, 1.0);
uniform vec4 speck : source_color = vec4(0.38, 0.45, 0.28, 1.0);
uniform vec4 exit_color : source_color = vec4(1.0, 0.82, 0.35, 1.0);
uniform float grid_alpha = 0.0;
uniform vec2 hover = vec2(-99.0, -99.0);
uniform vec4 hover_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 outer_color : source_color = vec4(0.04, 0.04, 0.05, 1.0);

varying vec2 world;

void vertex() {
	world = VERTEX;
}

float bayer2(vec2 a) {
	a = floor(a);
	return fract(dot(a, vec2(0.5, a.y * 0.75)));
}

float bayer4(vec2 a) {
	return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	return texture(noise_tex, p).r;
}

vec4 cell_at(ivec2 c) {
	return texelFetch(cells_tex, clamp(c, ivec2(0), grid_size - 1), 0);
}

int deco_at(ivec2 c) {
	return int(texelFetch(deco_tex, clamp(c, ivec2(0), grid_size - 1), 0).r * 255.0 + 0.5);
}

vec3 dither_mix(vec3 a, vec3 b, float k, float d) {
	return k > d ? b : a;
}

// Текстура пола без видимого повтора: пол разбит на неровные пятна по паре клеток, каждое берёт плитку
// со своим сдвигом, а большие пятна чуть светлее или темнее. Иначе плитка 3×3 клетки складывается в сетку квадратов.
// Крупные пятна из самой плитки заранее убраны (WorldView._flat_floor), в ней осталась только мелкая фактура.
vec3 floor_sample(vec2 p, vec2 g, float d) {
	vec2 wob = vec2(noise(p / 37.0 + vec2(0.13, 0.4)), noise(p / 37.0 + vec2(0.61, 0.17))) - 0.5;
	vec2 spot = floor(g / 2.0 + wob * 0.9);
	vec2 shift = vec2(hash(spot), hash(spot + vec2(17.0, 3.0)));
	vec2 uv = fract(g / floor_tex_cells + shift);
	vec3 col = texture(floor_tex, uv).rgb;
	// два шума разного масштаба: их сумма не повторяется на экране
	float big = noise(p / 233.0 + vec2(0.3, 0.8)) * 0.6 + noise(p / 97.0 + vec2(0.41, 0.13)) * 0.4 + (d - 0.5) * 0.2;
	if (big < 0.4) col *= 0.93;
	else if (big > 0.62) col *= 1.05;
	return col;
}

vec3 surface_color(int s, vec2 p, float d, float t, vec3 base) {
	vec4 pal = texelFetch(surf_pal, ivec2(s, 0), 0);
	int kind = int(pal.a * 255.0 + 0.5);
	vec3 c = pal.rgb;
	float n = noise(p / 48.0 + vec2(t * 0.015, t * 0.01));
	if (kind == 1 || kind == 6 || kind == 4) {
		// жидкость: два тона, бегущие блики
		c = dither_mix(c * 0.78, c * 1.08, n + (d - 0.5) * 0.35, 0.5);
		float w = sin(p.x * 0.31 + p.y * 0.83 + t * 2.2 + n * 9.0);
		if (w > 0.94) c = mix(c, vec3(1.0), 0.4);
		if (kind == 4 && hash(floor(p / 2.0) + floor(t * 7.0)) > 0.991) c = vec3(1.0, 0.98, 0.7);
		if (kind == 6 && hash(floor(p / 2.0) + floor(t * 2.0)) > 0.994) c = c * 1.5;
	} else if (kind == 2) {
		// огонь: языки пламени ползут вверх
		float f = noise(vec2(p.x / 22.0, p.y / 12.0 + t * 0.35)) + (d - 0.5) * 0.25;
		f += noise(vec2(p.x / 9.0, p.y / 7.0 + t * 0.9)) * 0.25;
		c = f > 0.78 ? vec3(1.0, 0.92, 0.55) : (f > 0.6 ? vec3(0.98, 0.55, 0.15) : (f > 0.42 ? vec3(0.75, 0.22, 0.06) : vec3(0.32, 0.1, 0.05)));
	} else if (kind == 3) {
		// лёд: светлый, с косыми бликами
		c = dither_mix(c * 0.88, c, n + (d - 0.5) * 0.3, 0.5);
		if (fract((p.x + p.y * 2.0) / 29.0) < 0.05) c = vec3(0.97, 1.0, 1.0);
	} else if (kind == 5) {
		// масло: тёмное, с радужным отливом
		vec3 sheen = vec3(0.35, 0.25, 0.45);
		c = dither_mix(c, mix(c, sheen, 0.6), n + (d - 0.5) * 0.3, 0.62);
	} else {
		c = dither_mix(c * 0.85, c, n + (d - 0.5) * 0.3, 0.5);
	}
	return c;
}

// Клетка внутри карты: пол, поверхности, выход и подсветка боя.
// (Отдельной функцией: return во fragment() Godot не компилирует.)
vec3 map_color(vec2 p, vec2 g, ivec2 c, float d) {
	// неровные края пятен: клетка берётся со смещением по шуму
	vec2 wob = vec2(noise(p / 61.0), noise(p / 61.0 + vec2(0.37, 0.71))) - 0.5;
	ivec2 cw = ivec2(floor(g + wob * 0.62));
	vec4 cell = cell_at(c);
	vec4 cellw = cell_at(cw);

	// пол
	vec3 col;
	float big = noise(p / 190.0);
	float fine = noise(p / 27.0 + vec2(0.5, 0.2));
	if (use_floor_tex) {
		col = floor_sample(p, g, d);
		col = dither_mix(col * 0.92, col, fine + (d - 0.5) * 0.3, 0.45);
	} else {
		float v = big * 0.7 + fine * 0.3 + (d - 0.5) * 0.16;
		col = v > 0.5 ? floor_a.rgb : floor_b.rgb;
		float f2 = fine + (d - 0.5) * 0.22;
		if (f2 < 0.3) col = floor_dark.rgb;
		if (f2 > 0.76) col = floor_light.rgb;
		// травинки и камешки: столбики 1×2
		float hb = hash(vec2(floor(p.x), floor(p.y * 0.5)));
		if (hb > 0.982) col = speck.rgb;
		else if (hb < 0.006) col = floor_dark.rgb * 0.8;
	}
	// под стенами и домами — тень
	if (cellw.r > 0.5) col *= 0.72;

	// тропы и мостовая — с неровным краем (клетка со смещением по шуму), грядки — ровными рядами
	int dw = deco_at(cw);
	int dc = deco_at(c);
	if (dw == 1) {
		float pv = fine + (d - 0.5) * 0.3;
		col = pv > 0.5 ? path_a.rgb : path_b.rgb;
		if (pv < 0.24) col = path_b.rgb * 0.84;
		if (hash(vec2(floor(p.x / 2.0), floor(p.y))) > 0.986) col = path_a.rgb * 1.28;   // камешки
		if (deco_at(ivec2(floor(g + wob * 0.3))) != 1 && d > 0.5) col = mix(col, floor_b.rgb, 0.6);   // трава по краю
	} else if (dw == 2) {
		vec2 q = g * 3.0;
		float shift = mod(floor(q.y), 2.0) * 0.5;
		vec2 qi = floor(q + vec2(shift, 0.0));
		vec2 qf = fract(q + vec2(shift, 0.0));
		col = mix(vec3(0.40, 0.38, 0.34), vec3(0.53, 0.50, 0.44), hash(qi));
		col = dither_mix(col * 0.9, col, fine + (d - 0.5) * 0.3, 0.45);
		if (qf.x < 0.09 || qf.y < 0.13) col = vec3(0.23, 0.21, 0.18);
	}
	if (dc == 3) {
		float row = fract(g.y * 3.0);
		col = row < 0.42 ? vec3(0.26, 0.18, 0.11) : vec3(0.36, 0.26, 0.16);
		if (row > 0.55 && row < 0.9 && hash(floor(p / 2.0)) > 0.55) col = vec3(0.34, 0.49, 0.21);
	}

	// поверхности
	int s = int(cellw.g * 255.0 + 0.5);
	if (s > 0) {
		col = surface_color(s, p, d, TIME, col);
	}
	// тёмный ободок по краю пятна поверхности
	int s_raw = int(cell_at(ivec2(floor(g + wob * 0.5))).g * 255.0 + 0.5);
	if (s > 0 && s_raw != s) col *= 0.82;

	vec2 f = fract(g);
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));

	// мост: доски поперёк хода, щели, по краям брус перил; поверх воды
	if (dc == 4 || dc == 5) {
		bool ax = dc == 4;
		float along = ax ? f.x : f.y;
		float across = ax ? f.y : f.x;
		float plank = floor((ax ? g.x : g.y) * 4.0);
		col = mix(vec3(0.40, 0.27, 0.16), vec3(0.56, 0.40, 0.24), hash(vec2(plank, 7.0)));
		col = dither_mix(col * 0.88, col, fine + (d - 0.5) * 0.3, 0.5);
		if (fract(along * 4.0) < 0.13) col = vec3(0.15, 0.10, 0.06);
		bool open_a = deco_at(c + (ax ? ivec2(0, -1) : ivec2(-1, 0))) != dc;
		bool open_b = deco_at(c + (ax ? ivec2(0, 1) : ivec2(1, 0))) != dc;
		if ((open_a && across < 0.15) || (open_b && across > 0.85)) {
			col = vec3(0.30, 0.20, 0.11);
			if (fract(along * 2.0) < 0.2) col = vec3(0.20, 0.13, 0.07);   // столбики перил
		}
	}
	// брод: плоские камни в воде
	if (dc == 6) {
		vec2 s1 = (f - vec2(0.3, 0.32)) / vec2(0.2, 0.17);
		vec2 s2 = (f - vec2(0.7, 0.7)) / vec2(0.19, 0.16);
		float r = min(dot(s1, s1), dot(s2, s2));
		if (r < 1.0) {
			col = mix(vec3(0.45, 0.45, 0.42), vec3(0.62, 0.61, 0.56), step(0.5, hash(floor(g * 2.0))));
			if (r > 0.65) col *= 0.7;
			else if ((dot(s1, s1) < 1.0 ? s1.y : s2.y) < -0.35) col *= 1.15;
		}
	}

	// выход: мерцающая золотая сетка
	if (cell.b > 0.5) {
		float pulse = 0.5 + 0.5 * sin(TIME * 3.0);
		if (d < 0.25 + pulse * 0.25) col = mix(col, exit_color.rgb, 0.45);
		if (edge < 0.05) col = mix(col, exit_color.rgb, 0.7);
	}

	// бой: сетка и подсветка
	vec4 hl = texelFetch(hl_tex, c, 0);
	if (grid_alpha > 0.0 && edge < 0.034) col *= 1.0 - grid_alpha;
	if (hl.g > 0.5) {
		// дальность навыка: холодный голубой, заметен и на рыжей листве, и на траве
		if (d < 0.375) col = mix(col, vec3(0.62, 0.95, 1.0), 0.45);
		if (edge < 0.04) col = mix(col, vec3(0.55, 0.9, 1.0), 0.55);
	}
	if (hl.r > 0.5) {
		if (d < 0.5) col = mix(col, vec3(0.75, 0.9, 1.0), 0.18);
		if (edge < 0.04) col = mix(col, vec3(0.7, 0.85, 1.0), 0.35);
	}
	if (hl.a > 0.5) {
		vec2 cc = abs(f - 0.5);
		if (cc.x + cc.y < 0.16) col = mix(col, vec3(1.0, 1.0, 0.85), 0.85);
	}
	if (hl.b > 0.5) {
		if (d < 0.75) col = mix(col, vec3(1.0, 0.35, 0.2), 0.45);
		if (edge < 0.05) col = vec3(1.0, 0.55, 0.3);
	}
	if (float(c.x) == hover.x && float(c.y) == hover.y && edge < 0.075) {
		// клетка под курсором: светлая рамка через пиксель с тёмной, видна на любом полу
		col = d < 0.5 ? hover_color.rgb : vec3(0.06, 0.05, 0.04);
	}
	return col;
}

void fragment() {
	vec2 p = floor(world) + 0.5;
	vec2 g = vec2((p.x / 16.0 + p.y / 8.0) * 0.5, (p.y / 8.0 - p.x / 16.0) * 0.5);
	ivec2 c = ivec2(floor(g));
	float d = bayer4(p);
	if (c.x < 0 || c.y < 0 || c.x >= grid_size.x || c.y >= grid_size.y) {
		// за краем карты: пол темнеет и растворяется в цвете фона
		vec2 out_d = max(-g, g - vec2(grid_size));
		float k = clamp(max(out_d.x, out_d.y) / 6.0, 0.0, 1.0);
		float n0 = noise(p / 27.0 + vec2(0.5, 0.2)) * 0.6 + noise(p / 90.0) * 0.4;
		vec3 oc = n0 + (d - 0.5) * 0.2 > 0.5 ? floor_b.rgb : floor_dark.rgb;
		if (use_floor_tex) oc = floor_sample(p, g, d);
		oc *= 0.62 - 0.22 * k;
		if (hash(vec2(floor(p.x), floor(p.y * 0.5))) > 0.985) oc = floor_dark.rgb * 0.7;
		if (k * 1.1 + (d - 0.5) * 0.5 + (n0 - 0.5) * 0.4 > 0.7) oc = outer_color.rgb;
		COLOR = vec4(oc, 1.0);
	} else {
		COLOR = vec4(map_color(p, g, c, d), 1.0);
	}
}
