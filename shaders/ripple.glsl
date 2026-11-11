// Shared core of the trackpad field shader (KDE ShaderEffect and GTK GLArea).
//
// A dense, jittered dot texture. Waves travel outwards, push dots radially and
// light them up (main crest plus a softer trailing echo); fingers light the
// dots underneath them. Rendered in two passes so the expensive part runs
// once per dot instead of once per pixel:
//
//   pass 1  dotState(cell) for every dot into a small grid texture, encoded
//           with encodeState(). Needs: fieldSize, time, W[8], T[5].
//   pass 2  shade(px) per pixel, reading its 3x3 nearest dots through
//           loadState(cell), which the wrapper defines before this file.
//           Needs: fieldSize, T[5].
//
// Wrapper inputs, in logical pixels:
//   vec2  fieldSize      field size
//   float time           seconds, same clock as the wave start times
//   vec4  W[8]           waves: x, y, start time, kind (0 none, 1 click, 2 force click)
//   vec4  T[5]           fingers: x, y, pressure 0..1, active (0/1)

const float SPACING = 6.0;
const vec3 BACKGROUND = vec3(0.008, 0.027, 0.067);

float hash(vec2 p)
{
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float roundedBox(vec2 p, vec2 half_, float r)
{
    vec2 q = abs(p) - half_ + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Light and radial push a wave gives a dot at `pos`
void wave(vec4 w, vec2 pos, inout float energy, inout vec2 push)
{
    if (w.w < 0.5) {
        return;
    }
    bool force = w.w > 1.5;
    float duration = force ? 2.4 : 1.3;
    float age = time - w.z;
    if (age < 0.0 || age > duration) {
        return;
    }
    float speed = force ? 330.0 : 230.0;
    float wwidth = force ? 34.0 : 20.0;
    float strength = force ? 4.0 : 2.2;
    float gain = force ? 1.0 : 0.7;

    vec2 d = pos - w.xy;
    float dist = length(d);
    float offset = dist - age * speed;
    float fade = pow(1.0 - age / duration, 1.5);

    float a = offset / wwidth;
    float b = (offset + wwidth * 1.6) / (wwidth * 0.6);
    float crest = exp(-a * a);
    float echo = 0.35 * exp(-b * b);
    float intensity = (crest + echo) * fade * gain;
    energy += intensity;
    if (dist > 0.0) {
        push += d / dist * sin(offset / (wwidth * 0.5)) * intensity * strength;
    }
}

// Grid size (in dots) of the pass 1 texture for a field of the given size
vec2 gridSize(vec2 size)
{
    return ceil(size / SPACING) + 1.0;
}

vec2 dotBase(vec2 c)
{
    return (c + 0.5) * SPACING + (vec2(hash(c), hash(c + 17.17)) - 0.5) * 3.0;
}

// x: light, yz: push in pixels
vec3 dotState(vec2 c)
{
    vec2 base = dotBase(c);
    float energy = 0.0;
    vec2 push = vec2(0.0);
    for (int i = 0; i < 8; i++) {
        wave(W[i], base, energy, push);
    }
    for (int i = 0; i < 5; i++) {
        if (T[i].w > 0.5) {
            float d = length(base - T[i].xy);
            energy += (0.35 + 0.65 * T[i].z) * exp(-pow(d / (14.0 + 22.0 * T[i].z), 2.0));
        }
    }
    return vec3(min(energy, 1.5), clamp(push, -7.5, 7.5));
}

// Fits 8-bit textures: push keeps ~0.06 px precision
vec4 encodeState(vec3 s)
{
    return vec4(s.x / 1.5, s.yz / 15.0 + 0.5, 1.0);
}

vec3 decodeState(vec4 e)
{
    return vec3(e.x * 1.5, (e.yz - 0.5) * 15.0);
}

vec4 shade(vec2 px)
{
    float edge = roundedBox(px - fieldSize * 0.5, fieldSize * 0.5 - 0.5, fieldSize.x * 0.06);
    float inside = clamp(0.5 - edge, 0.0, 1.0);
    if (inside <= 0.0) {
        return vec4(0.0);
    }

    // Soft halo under each finger
    vec3 color = BACKGROUND;
    for (int i = 0; i < 5; i++) {
        if (T[i].w > 0.5) {
            float d = length(px - T[i].xy);
            color += vec3(0.05, 0.25, 0.75) * (0.15 + 0.35 * T[i].z) * exp(-pow(d / (26.0 + 30.0 * T[i].z), 2.0));
        }
    }

    vec2 cell = floor(px / SPACING);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 c = cell + vec2(float(x), float(y));
            vec3 state = decodeState(loadState(c));
            float light = state.x;
            float size = 0.45 + hash(c + 31.7) * 0.65;
            float brightness = 0.12 + hash(c + 5.31) * 0.22;
            float alpha = min(0.95, brightness + light * 0.65);
            float radius = size + light * 0.85;
            float cover = clamp(radius + 0.5 - length(px - dotBase(c) - state.yz), 0.0, 1.0);
            vec3 dotColor = vec3((22.0 + light * 45.0) / 255.0, (100.0 + light * 80.0) / 255.0, 1.0);
            color = mix(color, dotColor, cover * alpha);
        }
    }

    // Thin rim
    color = mix(color, vec3(0.25, 0.45, 0.85), 0.35 * clamp(1.0 - abs(edge + 1.0), 0.0, 1.0));
    return vec4(color * inside, inside);
}
