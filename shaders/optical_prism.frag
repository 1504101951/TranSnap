#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uAngle;
uniform float uSweep;
uniform float uRadius;
uniform float uStroke;
uniform float uIsDark;
uniform vec3 uCoolTint;
uniform vec3 uWarmTint;
uniform float uPeakAlpha;
uniform float uDispersionAlpha;

out vec4 fragColor;

float roundedBoxSDF(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + vec2(r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  vec2 pos = FlutterFragCoord().xy;
  vec2 halfSize = max(uSize * 0.5, vec2(1.0));
  vec2 centered = pos - halfSize;
  float r = min(uRadius, min(halfSize.x, halfSize.y));
  float dist = roundedBoxSDF(centered, halfSize - vec2(uStroke * 0.5), r);

  float edgeMask = 1.0 - smoothstep(0.0, max(0.6, uStroke), abs(dist));

  vec2 normPos = normalize(centered + vec2(0.0001));
  vec2 lightDir = vec2(cos(uAngle), sin(uAngle));
  float aligned = dot(normPos, lightDir);
  float primaryHighlight = pow(clamp(aligned * 0.5 + 0.5, 0.0, 1.0), 3.2);
  float oppHighlight = pow(clamp(-aligned * 0.5 + 0.5, 0.0, 1.0), 4.5) * 0.28;

  vec2 coolDir = vec2(cos(uAngle + 0.42), sin(uAngle + 0.42));
  vec2 warmDir = vec2(cos(uAngle - 0.42), sin(uAngle - 0.42));
  float coolFactor = pow(clamp(dot(normPos, coolDir) * 0.5 + 0.5, 0.0, 1.0), 4.0);
  float warmFactor = pow(clamp(dot(normPos, warmDir) * 0.5 + 0.5, 0.0, 1.0), 4.0);

  vec3 whiteSpec = vec3(1.0);
  float rimSpecAlpha = (0.08 + primaryHighlight * uPeakAlpha + oppHighlight * uPeakAlpha) * edgeMask;
  float coolAlpha = coolFactor * uDispersionAlpha * edgeMask;
  float warmAlpha = warmFactor * (uDispersionAlpha * 0.72) * edgeMask;

  vec3 color = whiteSpec * rimSpecAlpha + uCoolTint * coolAlpha + uWarmTint * warmAlpha;
  float alpha = clamp(rimSpecAlpha + (coolAlpha + warmAlpha) * 0.55, 0.0, 0.92);

  if (uSweep > 0.001 && uSweep < 0.999 && dist <= 0.0) {
    float diag = (pos.x / max(uSize.x, 1.0)) * 0.72 + (pos.y / max(uSize.y, 1.0)) * 0.28;
    float center = mix(-0.25, 1.25, uSweep);
    float band = exp(-pow((diag - center) / 0.085, 2.0));
    float fade = sin(uSweep * 3.14159265);
    float sweepAlpha = band * fade * mix(0.14, 0.10, uIsDark);
    color += whiteSpec * sweepAlpha;
    alpha = clamp(alpha + sweepAlpha, 0.0, 0.92);
  }

  color = clamp(color, vec3(0.0), vec3(alpha));
  fragColor = vec4(color, alpha);
}
