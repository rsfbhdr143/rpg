// Последний проход по картинке мира: меньше цветов с дизерингом (пиксельный вид), лёгкая виньетка,
// тон локации и затемнение. Работает по пикселям маленького экрана мира, а не по пикселям окна.
shader_type canvas_item;

uniform bool posterize = true;
uniform float levels = 14.0;
uniform float dither = 0.6;
uniform float vignette = 0.25;
uniform vec4 tint : source_color = vec4(1.0);
uniform float fade = 0.0;
uniform float flash = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

float bayer2(vec2 a) {
	a = floor(a);
	return fract(dot(a, vec2(0.5, a.y * 0.75)));
}

float bayer4(vec2 a) {
	return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

void fragment() {
	vec2 size = vec2(textureSize(TEXTURE, 0));
	vec2 px = floor(UV * size);
	vec3 c = texture(TEXTURE, (px + 0.5) / size).rgb * tint.rgb;
	c = mix(c, flash_color.rgb, flash);
	vec2 q = UV - 0.5;
	float v = 1.0 - dot(q, q) * vignette * 2.2;
	c *= v;
	if (posterize) {
		float d = (bayer4(px) - 0.5) * dither;
		c = floor(c * levels + 0.5 + d) / levels;
	}
	c *= 1.0 - fade;
	COLOR = vec4(clamp(c, 0.0, 1.0), 1.0);
}
