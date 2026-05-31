/* Metal shaders for the GNU Emacs Metal backend.
   Two pipelines:
   1. Glyph pipeline: renders glyphs from the atlas texture as textured quads.
   2. Rect pipeline: fills solid-color rectangles (backgrounds, borders, cursor).

   Copyright (C) 2026 Free Software Foundation, Inc.
   License: GPL-3+ */

#include <metal_stdlib>
using namespace metal;

/* -----------------------------------------------------------------------
   Shared vertex/uniform types (must match C-side structs in mtlterm.m)
   ----------------------------------------------------------------------- */

struct GlyphVertex
{
  float2 position  [[attribute(0)]];
  float2 texCoord  [[attribute(1)]];
  float4 color     [[attribute(2)]];
};

struct RectVertex
{
  float2 position  [[attribute(0)]];
  float4 color     [[attribute(1)]];
};

struct Uniforms
{
  float2 screenSize; /* width, height in points */
};

struct GlyphRasterizerData
{
  float4 position [[position]];
  float2 texCoord;
  float4 color;
};

struct RectRasterizerData
{
  float4 position [[position]];
  float4 color;
};

/* -----------------------------------------------------------------------
   Utility: convert from Emacs pixel coordinates (top-left origin, y down)
   to Metal NDC (center origin, y up, [-1,1]).
   ----------------------------------------------------------------------- */

static float2 pixel_to_ndc(float2 px, float2 screen)
{
  return float2(
    (px.x / screen.x) * 2.0 - 1.0,
    1.0 - (px.y / screen.y) * 2.0
  );
}

/* -----------------------------------------------------------------------
   Glyph pipeline
   ----------------------------------------------------------------------- */

vertex GlyphRasterizerData
glyph_vertex(GlyphVertex in [[stage_in]],
             constant Uniforms &u [[buffer(1)]])
{
  GlyphRasterizerData out;
  float2 ndc = pixel_to_ndc(in.position, u.screenSize);
  out.position = float4(ndc, 0.0, 1.0);
  out.texCoord = in.texCoord;
  out.color    = in.color;
  return out;
}

fragment float4
glyph_fragment(GlyphRasterizerData in [[stage_in]],
               texture2d<float> atlas [[texture(0)]],
               sampler smp           [[sampler(0)]])
{
  /* Atlas stores glyph coverage in red channel (grayscale bitmap).
     Multiply foreground color alpha by coverage for anti-aliased text. */
  float coverage = atlas.sample(smp, in.texCoord).r;
  return float4(in.color.rgb, in.color.a * coverage);
}

/* -----------------------------------------------------------------------
   Rectangle pipeline (backgrounds, cursor, borders)
   ----------------------------------------------------------------------- */

vertex RectRasterizerData
rect_vertex(RectVertex in [[stage_in]],
            constant Uniforms &u [[buffer(1)]])
{
  RectRasterizerData out;
  float2 ndc = pixel_to_ndc(in.position, u.screenSize);
  out.position = float4(ndc, 0.0, 1.0);
  out.color    = in.color;
  return out;
}

fragment float4
rect_fragment(RectRasterizerData in [[stage_in]])
{
  return in.color;
}
