/* Metal driver for the GNU Emacs GPU display backend (macOS).
   Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

ARCHITECTURE (Phase 2)
----------------------
Metal rendering is added on top of standard NS frames:
  1. Normal NS frame created by the NS backend (EmacsView in NSWindow)
  2. `mtl-enable-for-frame` called from Elisp adds a CAMetalLayer sublayer
     on top of EmacsView, stored as an associated object
  3. redisplay_interface hooks render to this Metal layer instead of CoreGraphics
  4. The NS backend handles events, scrollbars, menus — Metal handles pixels

Glyph atlas: 2048×2048 R8Unorm texture (grayscale coverage).
Shaders embedded as source string, compiled at runtime via newLibraryWithSource:.
Font rasterization: CoreText via macfont_get_nsctfont() (macfont.m).
Reference: neomacs glyph_atlas.rs, frame_glyphs.rs (Rust/wgpu equivalent).
*/

#include <config.h>

#ifdef HAVE_MTL

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

#include "lisp.h"
#include "blockinput.h"
#include "frame.h"
#include "window.h"
#include "termchar.h"
#include "dispextern.h"
#include "buffer.h"
#include "character.h"
#include "charset.h"
#include "composite.h"
#include "fontset.h"
#include "font.h"
#include "systime.h"
#include "atimer.h"
#include "termhooks.h"
#include "coding.h"
#include "keyboard.h"
#include "menu.h"
#include "macfont.h"
#include "nsterm.h"

#include "mtlterm.h"

/* -----------------------------------------------------------------------
   Metal shader source (embedded so we don't need a .metallib bundle).
   Compiled at runtime with newLibraryWithSource:options:error:.
   ----------------------------------------------------------------------- */

static NSString * const MTL_SHADER_SOURCE = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
  float2 position  [[attribute(0)]];
  float2 texCoord  [[attribute(1)]];
  float4 color     [[attribute(2)]];
};

struct RectVertex {
  float2 position  [[attribute(0)]];
  float4 color     [[attribute(1)]];
};

struct Uniforms {
  float2 screenSize;
};

struct GlyphOut {
  float4 position [[position]];
  float2 texCoord;
  float4 color;
};

struct RectOut {
  float4 position [[position]];
  float4 color;
};

static float2 to_ndc(float2 px, float2 sz) {
  return float2((px.x / sz.x) * 2.0 - 1.0,
                1.0 - (px.y / sz.y) * 2.0);
}

vertex GlyphOut glyph_vertex(GlyphVertex in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]]) {
  GlyphOut out;
  out.position = float4(to_ndc(in.position, u.screenSize), 0.0, 1.0);
  out.texCoord = in.texCoord;
  out.color    = in.color;
  return out;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                                texture2d<float> atlas [[texture(0)]],
                                sampler smp           [[sampler(0)]]) {
  float coverage = atlas.sample(smp, in.texCoord).r;
  // F3: the NS (CoreGraphics) backend renders on-screen text slightly heavier
  // (more ink at every level) thanks to its coverage gamma / stem darkening.
  // Plain linear coverage leaves Metal text a touch lighter than NS. Apply a
  // mild gamma (<1) to lift coverage uniformly and match NS's weight.
  coverage = pow(coverage, 0.82);
  return float4(in.color.rgb, in.color.a * coverage);
}

vertex RectOut rect_vertex(RectVertex in [[stage_in]],
                            constant Uniforms &u [[buffer(1)]]) {
  RectOut out;
  out.position = float4(to_ndc(in.position, u.screenSize), 0.0, 1.0);
  out.color    = in.color;
  return out;
}

fragment float4 rect_fragment(RectOut in [[stage_in]]) {
  return in.color;
}

// Full-screen blit: copy the staticTexture to screen
struct BlitVertex {
  float2 position [[attribute(0)]];
  float2 texCoord [[attribute(1)]];
};
struct BlitOut {
  float4 position [[position]];
  float2 texCoord;
};
vertex BlitOut blit_vertex(BlitVertex in [[stage_in]]) {
  BlitOut out;
  out.position = float4(in.position, 0.0, 1.0);
  out.texCoord = in.texCoord;
  return out;
}
fragment float4 blit_fragment(BlitOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp          [[sampler(0)]]) {
  return tex.sample(smp, in.texCoord);
}

// Particle: small rounded rect with alpha based on age
struct ParticleVertex {
  float2 position [[attribute(0)]];
  float4 color    [[attribute(1)]]; // rgb + alpha (pre-multiplied age)
};
struct ParticleOut {
  float4 position [[position]];
  float4 color;
};
vertex ParticleOut particle_vertex(ParticleVertex in [[stage_in]],
                                    constant Uniforms &u [[buffer(1)]]) {
  ParticleOut out;
  out.position = float4(to_ndc(in.position, u.screenSize), 0.0, 1.0);
  out.color    = in.color;
  return out;
}
fragment float4 particle_fragment(ParticleOut in [[stage_in]]) {
  return in.color;
}

// Phase 5: inline image — sample RGBA texture and output directly with alpha
struct ImageVertex {
  float2 position [[attribute(0)]];
  float2 texCoord [[attribute(1)]];
  float  alpha    [[attribute(2)]];
};
struct ImageOut {
  float4 position [[position]];
  float2 texCoord;
  float  alpha;
};
vertex ImageOut image_vertex(ImageVertex in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]]) {
  ImageOut out;
  out.position = float4(to_ndc(in.position, u.screenSize), 0.0, 1.0);
  out.texCoord = in.texCoord;
  out.alpha    = in.alpha;
  return out;
}
fragment float4 image_fragment(ImageOut in [[stage_in]],
                                texture2d<float> img [[texture(0)]],
                                sampler smp          [[sampler(0)]]) {
  float4 color = img.sample(smp, in.texCoord);
  /* The CGContext source is premultiplied.  Scale every channel so the
     image remains premultiplied when the caller supplies opacity.  */
  color *= in.alpha;
  return color;
}

struct BorderVertex {
  float2 position [[attribute(0)]];
  float2 local    [[attribute(1)]];
};
struct BorderOut {
  float4 position [[position]];
  float2 local;
};
struct BorderUniforms {
  float2 size;
  float radius;
  float stroke;
  float elapsed;
  float opacity;
  float state;
  float padding;
  float cycleDuration;
  float runnerFraction;
  float glowOpacity;
  float stylePadding;
  float4 color;
};
vertex BorderOut border_vertex(BorderVertex in [[stage_in]],
                                constant Uniforms &u [[buffer(1)]]) {
  BorderOut out;
  out.position = float4(to_ndc(in.position, u.screenSize), 0.0, 1.0);
  out.local = in.local;
  return out;
}

static float rounded_rect_distance(float2 p, float2 size, float radius) {
  float2 q = abs(p - size * 0.5) - (size * 0.5 - radius);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

static float rounded_rect_path(float2 p, float2 size, float radius) {
  const float half_pi = 1.57079632679;
  const float pi = 3.14159265359;
  const float two_pi = 6.28318530718;
  float top = max(size.x - 2.0 * radius, 0.0);
  float side = max(size.y - 2.0 * radius, 0.0);
  float quarter = half_pi * radius;
  float perimeter = 2.0 * (top + side) + two_pi * radius;
  float angle, path;
  if (p.y < radius && p.x > size.x - radius) {
    angle = atan2(p.y - radius, p.x - (size.x - radius));
    path = top + radius * (angle + half_pi);
  } else if (p.y > size.y - radius && p.x > size.x - radius) {
    angle = atan2(p.y - (size.y - radius), p.x - (size.x - radius));
    path = top + quarter + side + radius * angle;
  } else if (p.y > size.y - radius && p.x < radius) {
    angle = atan2(p.y - (size.y - radius), p.x - radius);
    path = top + quarter + side + quarter + top
      + radius * (angle - half_pi);
  } else if (p.y < radius && p.x < radius) {
    angle = atan2(p.y - radius, p.x - radius);
    if (angle < 0.0) angle += two_pi;
    path = perimeter - quarter + radius * (angle - pi);
  } else {
    /* Interior stroke pixels can lie beyond the corner regions when the
       radius is smaller than half the stroke width.  Choose the nearest
       straight edge instead of treating every such pixel as a left edge. */
    float2 distance = min(p, size - p);
    if (distance.y <= distance.x) {
      if (p.y < size.y * 0.5)
        path = clamp(p.x - radius, 0.0, top);
      else
        path = top + quarter + side + quarter
          + clamp(size.x - radius - p.x, 0.0, top);
    } else if (p.x > size.x * 0.5)
      path = top + quarter + clamp(p.y - radius, 0.0, side);
    else
      path = top + quarter + side + quarter + top + quarter
        + clamp(size.y - radius - p.y, 0.0, side);
  }
  return path / perimeter;
}

static float dash_along_distance(float phase, float perimeter,
                                 float dash_fraction) {
  float position = phase * perimeter;
  float dash_length = dash_fraction * perimeter;
  return position < dash_length
    ? min(position, dash_length - position)
    : -min(position - dash_length, perimeter - position);
}

fragment float4 border_fragment(BorderOut in [[stage_in]],
                                 constant BorderUniforms &b [[buffer(0)]]) {
  float d = rounded_rect_distance(in.local, b.size, b.radius);
  float aa = max(fwidth(d), 0.5);
  float edge = 1.0 - smoothstep(b.stroke * 0.5 - aa,
                                b.stroke * 0.5 + aa, abs(d));
  float alpha = 0.0;
  if (b.state < 0.5 && b.runnerFraction > 0.0) {
    float path = rounded_rect_path(in.local, b.size, b.radius);
    float phase = fract(path - b.elapsed / b.cycleDuration);
    float perimeter = 2.0 * (b.size.x + b.size.y - 4.0 * b.radius)
      + 6.28318530718 * b.radius;
    float runner_along = dash_along_distance(phase, perimeter, b.runnerFraction);
    float runner_distance = length(float2(min(runner_along, 0.0), d));
    float core = 1.0 - smoothstep(b.stroke * 0.5 - aa,
                                  b.stroke * 0.5 + aa, runner_distance);
    float halo_along = dash_along_distance(phase, perimeter,
                                           b.runnerFraction * (9.0 / 11.0));
    float halo_distance = length(float2(min(halo_along, 0.0), d));
    float halo_falloff = max(halo_distance - 3.5, 0.0) / 2.0;
    float halo = b.glowOpacity * exp(-0.5 * halo_falloff * halo_falloff);
    alpha = max(0.24 * edge, core + halo * (1.0 - core));
  } else {
    float opacity = 1.0;
    if (b.state > 2.5) opacity = 0.35;
    else if (b.state > 1.5) opacity = 0.7;
    else if (b.state < 0.5) opacity = 0.24;
    alpha = edge * opacity;
  }
  return float4(b.color.rgb, alpha * b.opacity);
}

struct DecorationUniforms {
  float2 size;
  float radius, strokeWidth;
  float opacity, shape, startAngle, sweepAngle;
  float4 fill, stroke;
};
static float decoration_distance(float2 p, constant DecorationUniforms &b) {
  if (b.shape < 0.5)
    return rounded_rect_distance(p, b.size, b.radius);
  if (b.shape < 2.5)
    return length(p - b.size * 0.5) - b.size.x * 0.5;
  float denominator = dot(b.size, b.size);
  float t = denominator > 0.0 ? clamp(dot(p, b.size) / denominator, 0.0, 1.0) : 0.0;
  return length(p - t * b.size);
}
static float4 decoration_paint(float2 p, constant DecorationUniforms &b) {
  const float tau = 6.28318530718;
  float d = decoration_distance(p, b);
  if (b.shape > 1.5 && b.shape < 2.5) {
    if (abs(b.sweepAngle) < 0.000001) return float4(0);
    float2 center = b.size * 0.5;
    float angle = atan2(p.y - center.y, p.x - center.x);
    float direction = b.sweepAngle < 0.0 ? -1.0 : 1.0;
    float phase = fmod(direction * (angle - b.startAngle) + tau * 2.0, tau);
    if (phase > abs(b.sweepAngle)) {
      float2 a = center + center.x * float2(cos(b.startAngle), sin(b.startAngle));
      float end = b.startAngle + b.sweepAngle;
      float2 z = center + center.x * float2(cos(end), sin(end));
      d = min(length(p - a), length(p - z));
    }
  }
  /* Arc endpoint selection is discontinuous away from its stroke.  Taking
     derivatives of that distance invents a radial fringe at the end angle.
     Screen-space coordinate derivatives give bounded antialiasing instead. */
  float aa = max(max(fwidth(p.x), fwidth(p.y)), 0.5);
  float fill = b.shape < 1.5 ? (1.0 - smoothstep(-aa, aa, d)) * b.fill.a : 0.0;
  float stroke = (1.0 - smoothstep(b.strokeWidth * 0.5 - aa,
                                  b.strokeWidth * 0.5 + aa, abs(d))) * b.stroke.a;
  float alpha = stroke + fill * (1.0 - stroke);
  float3 rgb = alpha > 0.0 ? (b.stroke.rgb * stroke + b.fill.rgb * fill * (1.0 - stroke)) / alpha : float3(0);
  return float4(rgb, alpha * b.opacity);
}
fragment float4 decoration_fragment(BorderOut in [[stage_in]],
                                     constant DecorationUniforms &b [[buffer(0)]]) {
  return decoration_paint(in.local, b);
}
)MSL";

/* -----------------------------------------------------------------------
   Vertex types
   ----------------------------------------------------------------------- */

typedef struct {
  float x, y, u, v, r, g, b, a;
} MtlGlyphVertex;

typedef struct {
  float x, y, r, g, b, a;
} MtlRectVertex;

typedef struct {
  float x, y, local_x, local_y;
} MtlBorderVertex;

typedef struct {
  float width, height, radius, stroke;
  float elapsed, opacity, state, padding;
  float cycleDuration, runnerFraction, glowOpacity, stylePadding;
  float color[4];
} MtlBorderUniforms;

typedef struct {
  float screen_width, screen_height;
} MtlUniforms;

typedef struct {
  NSRect rect;
  NSRect clip;
  MtlBorderState state;
  unsigned long color;
  MtlBorderStyle style;
  CFTimeInterval startTime;
  BOOL cleanupPresented;
} MtlBorderRecord;

#define MTL_BORDER_COMPLETE_DURATION 1.9

/* -----------------------------------------------------------------------
   Global state
   ----------------------------------------------------------------------- */

struct mtl_display_info *mtl_display_list = NULL;
static int selfds[2] = {-1, -1};

/* Shared Metal device (one per process) */
static id<MTLDevice>      g_device       = nil;
static id<MTLCommandQueue> g_queue       = nil;
static id<MTLLibrary>     g_library      = nil;
static id<MTLRenderPipelineState> g_glyph_pipeline = nil;
static id<MTLRenderPipelineState> g_rect_pipeline  = nil;
static id<MTLSamplerState>        g_sampler        = nil; /* linear: glyph atlas */
static id<MTLSamplerState>        g_nearest_sampler = nil; /* nearest: blit */

/* Glyph atlas */
static id<MTLTexture>    g_atlas         = nil;
static int               g_atlas_next_x  = 0;
static int               g_atlas_next_y  = 0;
static int               g_atlas_row_h   = 0;
/* Backing scale the atlas glyphs are rasterized at (1.0 on a 1x display, 2.0 on
   Retina).  Glyphs are baked at physical resolution so they stay crisp on the
   physical-pixel static texture; draw sites divide the physical metrics back to
   logical pixels.  Reset the atlas when this changes (e.g. window moves to a
   monitor with a different DPI).  */
static CGFloat           g_atlas_scale   = 1.0;
/* Color-glyph (emoji) cache lives further down; cleared on scale change. */
static void mtl_color_glyph_cache_clear (void);
static struct gfx_driver mtl_gfx_driver;

/* Unified glyph+rect batch (the glterm.c counterpart).  Glyph quads and
   solid rects accumulate in one CPU vertex array, in submission order,
   and flush as a single draw call; the rects sample a white block
   reserved in the atlas (coverage 1.0 passes the gamma curve unchanged),
   so no pipeline switch ever splits the batch.  Each quad is clipped on
   the CPU at queue time against the recording frame's clip rect, so the
   batch also survives clip changes and crosses glyph strings.  Flushed
   by: a different target frame, any non-batched primitive (image,
   fringe, color glyph), a blit (scroll/shift), the end of the cycle, a
   capture, and an atlas repack.  */
@class MtlFrameData;
static MtlGlyphVertex   *g_batch        = NULL;
static int               g_batch_verts  = 0;
static int               g_batch_cap    = 0;
static MtlFrameData     *g_batch_fd     = nil;  /* unretained owner */
/* Clip rect for the current glyph string (logical px).  Lives here, not
   on MtlFrameData: it is read per QUAD in mtl_batch_append, where an
   objc_msgSend per access would be measurable, and render cycles never
   interleave, so a single global pair is correct.  */
static BOOL              g_clip_on      = NO;
static NSRect            g_clip_rect;
static void mtl_flush_batch (void);
static void mtl_atlas_reset (void);

/* Texture coordinates of the white block's center texel.  */
#define MTL_WHITE_U (2.0f / MTL_ATLAS_WIDTH)
#define MTL_WHITE_V (2.0f / MTL_ATLAS_HEIGHT)

/* Phase 4: global animation configuration (Lisp-configurable) */
/* Sonicboom is the user's pick as the default for tests and demos
   (animations themselves stay opt-in behind g_mtl_animations_enabled).  */
MtlCursorMode   g_mtl_cursor_mode    = MTL_CURSOR_SONICBOOM;
MtlScrollEasing g_mtl_scroll_easing  = MTL_EASE_OUT_QUAD;
float           g_mtl_scroll_duration = 0.15f;
NSUInteger      g_mtl_trail_len       = 20;

/* When false, presents do not wait for the display refresh
   (CAMetalLayer.displaySyncEnabled): redisplay never blocks on a
   drawable, trading the 60 fps power cap for NS-like latency.  */
BOOL g_mtl_vsync_enabled = YES;

/* Master switch for the GPU animation layer (cursor effects, particles,
   CADisplayLink @60fps).  OFF by default: the goal is pixel-correct parity
   with the NS backend first.  When off, the cursor is drawn directly into the
   static texture (like NS) and no compositor overlay is drawn.  Toggle from
   Lisp with (mtl-animations t). */
BOOL            g_mtl_animations_enabled = YES;

/* Per-command gate set from Lisp (pre-command-hook): when YES, the cursor
   effects that imply motion (sonicboom/ripple/pixiedust bursts and the
   torpedo trail) are suppressed for this redisplay, so typing does not
   trigger them.  Cursor MOVEMENT commands leave it NO.  */
BOOL            g_mtl_cursor_suppress_effects = NO;

/* Phase 4: additional global pipeline state */
static id<MTLRenderPipelineState> g_blit_pipeline     = nil;
static id<MTLRenderPipelineState> g_particle_pipeline = nil;
static id<MTLRenderPipelineState> g_border_pipeline   = nil;
static id<MTLRenderPipelineState> g_decoration_pipeline = nil;

/* Phase 5: inline image pipeline (RGBA, full texture output) */
static id<MTLRenderPipelineState> g_image_pipeline    = nil;

/* Phase 5: image texture cache.
   Bug fix: NSMapTable with NSMapTableObjectPointerPersonality used the NSValue*
   POINTER ADDRESS for equality (not the wrapped pointer content), so lookups
   always missed, objects leaked, and the runtime confused them with
   OS_dispatch_source objects on macOS 26.5 → crash.

   Fix: CFMutableDictionaryRef with NULL key callbacks uses raw pointer
   equality (struct image * itself as key) with no ObjC runtime involvement.
   Values use kCFTypeDictionaryValueCallBacks (strong — MTLTexture retained). */
static CFMutableDictionaryRef g_image_texture_cache = NULL;
/* Pointer -> image spec hash, validating the texture cache: Emacs frees
   evicted images and the allocator can reuse the address for a different
   image, so pointer identity alone could serve a stale picture.  */
static CFMutableDictionaryRef g_image_hash_cache = NULL;

/* -----------------------------------------------------------------------
   Color utilities
   ----------------------------------------------------------------------- */

static inline void
unpack_color (unsigned long c, float *r, float *g, float *b)
{
  *r = ((c >> 16) & 0xFF) / 255.0f;
  *g = ((c >>  8) & 0xFF) / 255.0f;
  *b = ((c      ) & 0xFF) / 255.0f;
}

/* Convert an NSColor * (as returned by FRAME_BACKGROUND_COLOR /
   FRAME_FOREGROUND_COLOR from nsterm.h) to a packed 0xRRGGBB unsigned long
   suitable for our Metal rendering helpers.  */
static inline unsigned long
ns_color_to_pixel (NSColor *c)
{
  if (!c) return 0;
  NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
  if (!rgb) rgb = c;
  unsigned long r = (unsigned long)([rgb redComponent]   * 255.0 + 0.5) & 0xFF;
  unsigned long g = (unsigned long)([rgb greenComponent] * 255.0 + 0.5) & 0xFF;
  unsigned long b = (unsigned long)([rgb blueComponent]  * 255.0 + 0.5) & 0xFF;
  return (r << 16) | (g << 8) | b;
}

/* -----------------------------------------------------------------------
   Global Metal setup (called once)
   ----------------------------------------------------------------------- */

id<MTLDevice>
mtl_get_device (void) { return g_device; }

id<MTLCommandQueue>
mtl_get_queue (void) { return g_queue; }

static BOOL
mtl_global_setup (void)
{
  if (g_device) return YES;

  g_device = MTLCreateSystemDefaultDevice ();
  if (!g_device) return NO;

  g_queue = [g_device newCommandQueue];

  /* Compile shaders from embedded source */
  MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
  opts.fastMathEnabled = YES;
  NSError *err = nil;
  g_library = [g_device newLibraryWithSource:MTL_SHADER_SOURCE
                                      options:opts
                                        error:&err];
  if (!g_library)
    {
      NSLog (@"emacs-mtl: shader compile error: %@", err);
      return NO;
    }

  /* Glyph atlas — 2048×2048 R8Unorm (grayscale coverage) */
  MTLTextureDescriptor *td =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                       width:MTL_ATLAS_WIDTH
                                                      height:MTL_ATLAS_HEIGHT
                                                   mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  g_atlas = [g_device newTextureWithDescriptor:td];
  mtl_atlas_reset ();           /* reserve the white block for rect quads */

  /* Linear sampler: for glyph atlas (sub-pixel accuracy) */
  MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  g_sampler = [g_device newSamplerStateWithDescriptor:sd];

  /* Nearest sampler: for screen blit (pixel-perfect, no blur) */
  MTLSamplerDescriptor *nsd = [[MTLSamplerDescriptor alloc] init];
  nsd.minFilter = MTLSamplerMinMagFilterNearest;
  nsd.magFilter = MTLSamplerMinMagFilterNearest;
  g_nearest_sampler = [g_device newSamplerStateWithDescriptor:nsd];

  /* Build glyph pipeline */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction  = [g_library newFunctionWithName:@"glyph_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"glyph_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = offsetof (MtlGlyphVertex, x);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2;
    vd.attributes[1].offset = offsetof (MtlGlyphVertex, u);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat4;
    vd.attributes[2].offset = offsetof (MtlGlyphVertex, r);
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = sizeof (MtlGlyphVertex);
    pd.vertexDescriptor = vd;

    g_glyph_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd
                                                                error:&err];
    if (!g_glyph_pipeline)
      NSLog (@"emacs-mtl: glyph pipeline error: %@", err);
  }

  /* Build rect pipeline */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction  = [g_library newFunctionWithName:@"rect_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"rect_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = offsetof (MtlRectVertex, x);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat4;
    vd.attributes[1].offset = offsetof (MtlRectVertex, r);
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = sizeof (MtlRectVertex);
    pd.vertexDescriptor = vd;

    g_rect_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd
                                                               error:&err];
    if (!g_rect_pipeline)
      NSLog (@"emacs-mtl: rect pipeline error: %@", err);
  }

  /* Blit pipeline (texture → screen) */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction  = [g_library newFunctionWithName:@"blit_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"blit_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    /* No blending: blit replaces destination */

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2; /* position */
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2; /* texCoord */
    vd.attributes[1].offset = 8;
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = 16;
    pd.vertexDescriptor = vd;

    g_blit_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_blit_pipeline) NSLog(@"emacs-mtl: blit pipeline error: %@", err);
  }

  /* Particle pipeline */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction  = [g_library newFunctionWithName:@"particle_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"particle_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2; /* position */
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat4; /* color+alpha */
    vd.attributes[1].offset = 8;
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = 24;
    pd.vertexDescriptor = vd;

    g_particle_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_particle_pipeline) NSLog(@"emacs-mtl: particle pipeline error: %@", err);
  }

  /* Rounded, alpha-blended tool-card border overlay. */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [g_library newFunctionWithName:@"border_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"border_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = offsetof (MtlBorderVertex, x);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2;
    vd.attributes[1].offset = offsetof (MtlBorderVertex, local_x);
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = sizeof (MtlBorderVertex);
    pd.vertexDescriptor = vd;

    g_border_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_border_pipeline)
      NSLog (@"emacs-mtl: border pipeline error: %@", err);
  }

  /* Same quad layout and blend policy, independent generic paint. */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [g_library newFunctionWithName:@"border_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"decoration_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2;
    vd.attributes[1].offset = 8;
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = sizeof (MtlBorderVertex);
    pd.vertexDescriptor = vd;
    g_decoration_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_decoration_pipeline) NSLog (@"emacs-mtl: decoration pipeline error: %@", err);
  }

  /* Phase 5: image pipeline (RGBA textures, alpha blending) */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction  = [g_library newFunctionWithName:@"image_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"image_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    /* Image textures contain premultiplied alpha from CGContext. */
    pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format      = MTLVertexFormatFloat2; /* position */
    vd.attributes[0].offset      = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format      = MTLVertexFormatFloat2; /* texCoord */
    vd.attributes[1].offset      = 8;
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format      = MTLVertexFormatFloat;  /* alpha */
    vd.attributes[2].offset      = 16;
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride         = 20;
    pd.vertexDescriptor          = vd;

    g_image_pipeline = [g_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_image_pipeline) NSLog(@"emacs-mtl: image pipeline error: %@", err);
  }

  /* Phase 5: image texture cache using CFMutableDictionary.
     NULL key callbacks → pointer equality & no retain/release on keys (struct image*).
     kCFTypeDictionaryValueCallBacks → retain/release MTLTexture values (ARC-safe). */
  g_image_texture_cache =
    CFDictionaryCreateMutable (kCFAllocatorDefault, 0,
                                NULL,                            /* keys: raw pointer */
                                &kCFTypeDictionaryValueCallBacks /* values: CF retain */
                                );
  g_image_hash_cache =
    CFDictionaryCreateMutable (kCFAllocatorDefault, 0, NULL, NULL);

  return YES;
}

/* -----------------------------------------------------------------------
   Glyph cache — open-addressing hash, global (shared across all frames)
   ----------------------------------------------------------------------- */

#define MTL_CACHE_SLOTS 16384

static MtlGlyphCacheEntry g_glyph_cache[MTL_CACHE_SLOTS];

static void
glyph_cache_init (void)
{
  memset (g_glyph_cache, 0, sizeof (g_glyph_cache));
  g_atlas_next_x  = 0;
  g_atlas_next_y  = 0;
  g_atlas_row_h   = 0;
}

/* Reset the atlas packing and the glyph table, then re-reserve the 4x4
   white block at (0,0) that batched solid rects sample (see g_batch).
   Queued quads still reference the old layout, so they are flushed
   first.  Used at atlas creation, on overflow repack, and on a backing
   scale change.  */
static void
mtl_atlas_reset (void)
{
  if (getenv ("MTL_LOG_SEQ")) fprintf (stderr, "[mtlatlas] RESET\n");
  mtl_flush_batch ();
  glyph_cache_init ();
  if (g_atlas)
    {
      static const uint8_t white[16] = {
        255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255,
      };
      [g_atlas replaceRegion:MTLRegionMake2D (0, 0, 4, 4) mipmapLevel:0
                   withBytes:white bytesPerRow:4];
      g_atlas_next_x = 5;
      g_atlas_next_y = 0;
      g_atlas_row_h  = 4;
    }
}

static unsigned int
glyph_cache_slot (uint64_t key)
{
  /* Fibonacci hashing */
  return (unsigned int)((key * 11400714819323198485ULL) >> 50) & (MTL_CACHE_SLOTS - 1);
}

/* key = (font_ptr_as_int << 21) | codepoint */
static MtlGlyphCacheEntry *
glyph_cache_lookup (uint64_t key)
{
  unsigned int slot = glyph_cache_slot (key);
  for (int i = 0; i < 32; i++)
    {
      MtlGlyphCacheEntry *e = &g_glyph_cache[(slot + i) & (MTL_CACHE_SLOTS - 1)];
      if (!e->valid) return NULL;
      if (e->cache_key == key) return e;
    }
  return NULL;
}

static MtlGlyphCacheEntry *
glyph_cache_insert (uint64_t key)
{
  unsigned int slot = glyph_cache_slot (key);
  for (int i = 0; i < 32; i++)
    {
      MtlGlyphCacheEntry *e = &g_glyph_cache[(slot + i) & (MTL_CACHE_SLOTS - 1)];
      if (!e->valid)
        {
          memset (e, 0, sizeof *e);
          e->cache_key = key;
          e->valid = true;
          return e;
        }
    }
  /* Cache probe window full: evict first slot (not ideal, good enough) */
  MtlGlyphCacheEntry *e = &g_glyph_cache[slot];
  memset (e, 0, sizeof *e);
  e->cache_key = key;
  e->valid = true;
  return e;
}

/* -----------------------------------------------------------------------
   Glyph rasterization — CoreText → R8Unorm atlas patch
   ----------------------------------------------------------------------- */

/* Core glyph rasterization: rasterize a CGGlyph (ID already resolved) into
   the atlas.  This is the single rasterization path used by BOTH:
   - mtl_cache_glyph_id (from Emacs glyph_string.char2b — already glyph IDs)
   - mtl_cache_glyph (from off-screen PNG test, uses Unicode → glyph lookup)

   The critical insight: glyph_string.char2b stores GLYPH IDs for the macfont
   backend (not Unicode codepoints).  Always use glyph IDs with CTFont APIs
   that accept CGGlyph directly (CTFontGetBoundingRectsForGlyphs, CTFontDrawGlyphs).
   Never call CTFontGetGlyphsForCharacters on a value that is already a glyph ID.
*/
static MtlGlyphCacheEntry *
mtl_rasterize_glyph_id (CTFontRef font, CGGlyph cgGlyph, uint64_t key)
{
  if (!g_atlas) return NULL;

  MtlGlyphCacheEntry *entry;
  CGFloat s = g_atlas_scale;

  /* Rasterize at physical resolution: bake the glyph from a copy of the font
     scaled by the backing factor.  Bbox/advance then come out in physical
     pixels; draw sites divide the stored metrics by g_atlas_scale to get back to
     logical pixels.  On a 1x display this is a no-op (s == 1). */
  CTFontRef rfont = (s != 1.0)
    ? CTFontCreateCopyWithAttributes (font, CTFontGetSize (font) * s, NULL, NULL)
    : (CTFontRef) CFRetain (font);

  CGRect bbox = CTFontGetBoundingRectsForGlyphs (rfont,
                   kCTFontOrientationDefault, &cgGlyph, NULL, 1);

  /* Glyph advance (physical → store logical) */
  CGSize adv;
  CTFontGetAdvancesForGlyphs (rfont, kCTFontOrientationDefault,
                               &cgGlyph, &adv, 1);

  int bw = (int)ceil (bbox.size.width)  + 2;
  int bh = (int)ceil (bbox.size.height) + 2;
  if (bw <= 0 || bh <= 0)
    {
      /* Space or zero-size glyph: cache as empty with correct advance */
      entry = glyph_cache_insert (key);
      CFRelease (rfont);
      if (!entry) return NULL;
      entry->advance_x = (float)(adv.width / s);
      entry->width = entry->height = 0;
      return entry;
    }

  /* Atlas row wrap */
  if (g_atlas_next_x + bw > MTL_ATLAS_WIDTH)
    {
      g_atlas_next_x  = 0;
      g_atlas_next_y += g_atlas_row_h + 1;
      g_atlas_row_h   = 0;
    }
  if (g_atlas_next_y + bh > MTL_ATLAS_HEIGHT)
    {
      /* Atlas full: repack from the top (mtl_atlas_reset flushes the
         queued quads that still reference the old layout).  */
      mtl_atlas_reset ();
      entry = glyph_cache_insert (key);
    }

  /* Rasterize glyph to grayscale CGContext */
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray ();
  size_t bpr  = (size_t)bw;
  uint8_t *px = (uint8_t *)calloc (1, bpr * (size_t)bh);
  CGContextRef ctx = CGBitmapContextCreate (px, (size_t)bw, (size_t)bh,
                                             8, bpr, cs,
                                             (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease (cs);

  /* White glyph on black background — alpha-mask style (neomacs approach).
     Disable font smoothing (stem-darkening): it bolds the white-on-black mask
     and makes the final text heavier than the NS backend.  We want the plain
     geometric grayscale coverage. */
  CGContextSetShouldAntialias (ctx, true);
  CGContextSetShouldSmoothFonts (ctx, false);
  CGContextSetGrayFillColor (ctx, 1.0, 1.0);
  CGPoint origin = CGPointMake (floor (-bbox.origin.x) + 1,
                                 floor (-bbox.origin.y) + 1);
  CTFontDrawGlyphs (rfont, &cgGlyph, &origin, 1, ctx);
  CGContextRelease (ctx);
  CFRelease (rfont);

  /* Upload to atlas */
  MTLRegion region = MTLRegionMake2D ((NSUInteger)g_atlas_next_x,
                                       (NSUInteger)g_atlas_next_y,
                                       (NSUInteger)bw, (NSUInteger)bh);
  [g_atlas replaceRegion:region mipmapLevel:0
               withBytes:px bytesPerRow:bpr];
  free (px);

  entry = glyph_cache_insert (key);
  if (!entry) return NULL;

  /* The raster placed the baseline at raster_oy measured from the BOTTOM of the
     bh-tall cell (Core Graphics draws y-up).  All draw sites expect bearing_y to
     be the distance from the cell's TOP edge down to the baseline, so that
     y0 = baseline - bearing_y lands the cell top correctly.  That distance is
     (bh - raster_oy): the row at top-down index r covers CG y in
     [bh-1-r, bh-r), so the baseline CG y = raster_oy lies bh - raster_oy rows
     below the top edge.  The previous (bh - 1 - raster_oy) left every glyph one
     pixel LOWER than the NS backend across the whole frame (verified by
     cross-correlation: shifting Metal text up 1px dropped the per-row mean
     error from ~40 to ~3 gray levels). */
  int raster_oy = (int)(floor (-bbox.origin.y) + 1);

  entry->atlas_x   = g_atlas_next_x;
  entry->atlas_y   = g_atlas_next_y;
  entry->width     = bw;
  entry->height    = bh;
  entry->bearing_x = (int)(floor (-bbox.origin.x) + 1);
  entry->bearing_y = bh - raster_oy;
  entry->advance_x = (float)(adv.width / s);

  g_atlas_next_x += bw + 1;
  if (bh > g_atlas_row_h) g_atlas_row_h = bh;

  return entry;
}

/* mtl_cache_glyph_id — PRIMARY path for Emacs text rendering.
   char2b[i] in glyph_string is a GLYPH ID (CGGlyph), not a Unicode codepoint.
   We use it directly with CoreText APIs that accept CGGlyph. */
static MtlGlyphCacheEntry *
mtl_cache_glyph_id (CTFontRef font, CGGlyph glyphId)
{
  if (!font || glyphId == 0) return NULL;

  /* Cache key = (font_ptr × large_prime) XOR glyphId */
  uint64_t key = ((uint64_t)(uintptr_t)font * 6364136223846793005ULL) ^ (uint64_t)glyphId;

  MtlGlyphCacheEntry *e = glyph_cache_lookup (key);
  if (e) return e;
  if (!g_atlas) return NULL;

  return mtl_rasterize_glyph_id (font, glyphId, key);
}

/* mtl_cache_glyph — SECONDARY path for off-screen test renders.
   Accepts a Unicode codepoint, converts to glyph ID first. */
MtlGlyphCacheEntry *
mtl_cache_glyph (CTFontRef font, uint32_t codepoint)
{
  if (!font) return NULL;

  UniChar chars[2];
  int nc = 1;
  if (codepoint >= 0x10000)
    {
      codepoint -= 0x10000;
      chars[0] = 0xD800 | (codepoint >> 10);
      chars[1] = 0xDC00 | (codepoint & 0x3FF);
      nc = 2;
    }
  else
    chars[0] = (UniChar)codepoint;

  CGGlyph cgGlyph = 0;
  if (!CTFontGetGlyphsForCharacters (font, chars, &cgGlyph, nc) || cgGlyph == 0)
    return NULL;

  return mtl_cache_glyph_id (font, cgGlyph);
}

/* -----------------------------------------------------------------------
   Per-frame Metal state (stored as ObjC associated object on EmacsView)
   ----------------------------------------------------------------------- */

static const char mtl_frame_key;

MtlFrameData *
mtl_get_frame_data (struct frame *f)
{
  if (!FRAME_NS_P (f)) return NULL;
  NSView *view = FRAME_NS_VIEW (f);
  if (!view) return NULL;
  return (__bridge MtlFrameData *)objc_getAssociatedObject (
    view, &mtl_frame_key);
}

/* Add a CAMetalLayer sublayer to an existing NS frame's EmacsView.
   Returns the frame data object or NULL on failure. */
MtlFrameData *
mtl_setup_frame (struct frame *f)
{
  if (!mtl_global_setup ()) return NULL;

  NSView *view = FRAME_NS_VIEW (f);
  if (!view) return NULL;

  /* Already set up? */
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (fd) return fd;

  view.wantsLayer = YES;

  CAMetalLayer *layer = [CAMetalLayer layer];
  layer.device        = g_device;
  layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  layer.displaySyncEnabled = g_mtl_vsync_enabled;
  layer.frame         = view.bounds;
  layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;

  /* Retina scaling */
  CGFloat scale = view.window
    ? view.window.backingScaleFactor
    : [[NSScreen mainScreen] backingScaleFactor];
  layer.contentsScale = scale;
  layer.drawableSize  = CGSizeMake (view.bounds.size.width  * scale,
                                     view.bounds.size.height * scale);

  /* Add as sublayer on top of view's backing layer */
  [view.layer addSublayer:layer];

  /* Uniform buffer */
  id<MTLBuffer> ubuf = [g_device newBufferWithLength:sizeof (MtlUniforms)
                                             options:MTLResourceStorageModeShared];

  fd = [[MtlFrameData alloc] init];
  fd.metalLayer   = layer;
  fd.uniformBuffer = ubuf;
  [ubuf release];
  fd.emacsFrame   = f;

  /* Decorations as Core Animation layers, unless BMACS_CA_DECORATIONS is
     0.  The container sits above the Metal layer, in the same flipped
     frame coordinates, and frames present with the transaction that
     carries its changes.  */
  const char *ca_decorations = getenv ("BMACS_CA_DECORATIONS");
  if (!ca_decorations || strcmp (ca_decorations, "0") != 0)
    {
      CALayer *decorations = [CALayer layer];
      decorations.frame = layer.frame;
      decorations.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
      decorations.contentsScale = scale;
      [view.layer addSublayer:decorations];
      fd.decorationLayer = decorations;
      layer.presentsWithTransaction = YES;
    }

  /* Phase 4: create animator.  Only start the 60fps loop when the animation
     layer is explicitly enabled (correctness first, animation opt-in). */
  MtlAnimator *anim = [[MtlAnimator alloc] initWithFrame:f];
  fd.animator = anim;
  [anim release];

  /* Register the Metal implementation of the gfx driver vtable
     (the neutral policy in gfxterm.c draws through it).  */
  gfx_drv = &mtl_gfx_driver;
  if (g_mtl_animations_enabled)
    [anim startAnimating];

  objc_setAssociatedObject (view, &mtl_frame_key,
                             fd, OBJC_ASSOCIATION_RETAIN);
  [fd release];
  return fd;
}

/* -----------------------------------------------------------------------
   Phase 4: Spring physics helpers
   ----------------------------------------------------------------------- */

#define SPRING_OMEGA 8.0f  /* sqrt(k/m): settles in ~150ms */

/* How long a torpedo trail sample stays visible before it fully fades.
   The tail dissipates on its own this many seconds after the cursor stops. */
#define MTL_TRAIL_LIFETIME 0.40f

static void
spring_update (MtlSpring1D *s, float target, float dt)
{
  float omega = SPRING_OMEGA;
  float c1 = s->pos - target;
  float c2 = s->vel + omega * c1;
  float e   = expf (-omega * dt);
  s->pos = target + (c1 + c2 * dt) * e;
  s->vel = (c2 - omega * (c1 + c2 * dt)) * e;
}

static float
easing_apply (MtlScrollEasing mode, float t)
{
  t = fmaxf (0.0f, fminf (1.0f, t));
  switch (mode) {
    case MTL_EASE_LINEAR:       return t;
    case MTL_EASE_OUT_QUAD:     return 1.0f - (1.0f-t)*(1.0f-t);
    case MTL_EASE_OUT_CUBIC:    return 1.0f - (1.0f-t)*(1.0f-t)*(1.0f-t);
    case MTL_EASE_IN_OUT_CUBIC: {
      float v = t < 0.5f ? 4*t*t*t : 1.0f - powf(-2*t+2,3)/2.0f;
      return v;
    }
    default: return 1.0f - (1.0f-t)*(1.0f-t); /* default OutQuad */
  }
}

/* Sequence tracing for present-flow debugging (MTL_LOG_SEQ=1). */
static BOOL
mtl_log_seq_p (void)
{
  static int on = -1;
  if (on < 0) on = getenv ("MTL_LOG_SEQ") != NULL;
  return on > 0;
}

#define MTL_SEQ(fmt, ...)                                               \
  do { if (mtl_log_seq_p ())                                            \
         fprintf (stderr, "[mtlseq %.3f] " fmt "\n",                    \
                  CACurrentMediaTime (), ##__VA_ARGS__); } while (0)

/* -----------------------------------------------------------------------
   @implementation MtlAnimator
   ----------------------------------------------------------------------- */

@implementation MtlAnimator

- (instancetype)initWithFrame:(struct frame *)f
{
  self = [super init];
  if (!self) return nil;
  self.emacsFrame    = f;
  self.cursorMode    = g_mtl_cursor_mode;
  self.scrollEasing  = g_mtl_scroll_easing;
  self.nParticles    = 0;
  self.trailHead     = 0;
  self.trailCount    = 0;
  return self;
}

- (void)startAnimating
{
  /* -[NSScreen displayLinkWithTarget:selector:] is macOS 14+.  On older
     systems this is a no-op: the continuous animation is driven by the
     Lisp 30fps timer (gpu-anim-tick / gpu-video-tick) anyway, which is
     also what keeps things moving when the event loop starves the display
     link while idle.  See the tickWithDt: comment.  */
  if (@available (macOS 14.0, *))
    {
      if (self.displayLink) return;
      self.displayLink = [NSScreen.mainScreen
        displayLinkWithTarget:self selector:@selector(animationTick:)];
      [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                             forMode:NSRunLoopCommonModes];
    }
}

- (void)stopAnimating
{
  if (@available (macOS 14.0, *))
    {
      [self.displayLink invalidate];
      self.displayLink = nil;
    }
}

- (void)dealloc
{
  [self stopAnimating];
  [super dealloc];
}

- (void)setCursorX:(int)x y:(int)y width:(int)w height:(int)h
{
  float fx = (float)x, fy = (float)y;

  /* On first placement, snap immediately */
  if (self.curTargetX == 0 && self.curTargetY == 0)
    {
      self.springX = (MtlSpring1D){fx, 0};
      self.springY = (MtlSpring1D){fy, 0};
    }

  /* Spawn particles when cursor jumps significantly, unless this redisplay
     was caused by a typing/editing command (Lisp sets the suppress flag). */
  float dx = fx - self.curTargetX, dy = fy - self.curTargetY;
  if (!g_mtl_cursor_suppress_effects
      && (fabsf(dx) > (float)w * 1.5f || fabsf(dy) > (float)h * 1.5f)
      && (self.cursorMode == MTL_CURSOR_PIXIEDUST
          || self.cursorMode == MTL_CURSOR_SONICBOOM
          || self.cursorMode == MTL_CURSOR_RIPPLE))
    [self spawnParticlesAtX:self.curTargetX + w/2 y:self.curTargetY + h/2];

  /* Add to trail history (skipped while typing). */
  if (!g_mtl_cursor_suppress_effects
      && self.cursorMode == MTL_CURSOR_TORPEDO
      && (fabsf(dx) > 1 || fabsf(dy) > 1))
    {
      NSUInteger slot = (self.trailHead + self.trailCount) % MTL_TRAIL_LEN;
      trailX[slot]   = self.curTargetX;
      trailY[slot]   = self.curTargetY;
      trailAge[slot] = 0.0f;            /* fresh sample, fully opaque */
      if (self.trailCount < g_mtl_trail_len)
        self.trailCount++;
      else
        self.trailHead = (self.trailHead + 1) % MTL_TRAIL_LEN;
    }

  self.curTargetX = fx;
  self.curTargetY = fy;
  self.curTargetW = (float)w;
  self.curTargetH = (float)h;
  self.cursorDirty = YES;
}

- (void)beginScrollBy:(float)pixels
{
  self.scrollOffset   += pixels;   /* accumulate */
  self.scrollTarget    = 0.0f;     /* want to return to 0 */
  self.scrollStartTime = CACurrentMediaTime();
  self.scrollDuration  = g_mtl_scroll_duration;
}

- (void)spawnParticlesAtX:(float)px y:(float)py
{
  NSUInteger count = (self.cursorMode == MTL_CURSOR_PIXIEDUST) ? 12 : 3;
  for (NSUInteger i = 0; i < count && self.nParticles < MTL_MAX_PARTICLES; i++)
    {
      float angle;
      if (self.cursorMode == MTL_CURSOR_PIXIEDUST)
        angle = (float)i * 2.399f; /* golden angle ≈ 137.5° */
      else
        angle = (float)i * (2.0f * M_PI / (float)count);

      float speed = (self.cursorMode == MTL_CURSOR_SONICBOOM) ? 60.0f : 40.0f;
      MtlParticle *p = &particles[self.nParticles++];
      p->x     = px;
      p->y     = py;
      p->vx    = cosf(angle) * speed;
      p->vy    = sinf(angle) * speed;
      p->age   = 0.0f;
      p->size  = (self.cursorMode == MTL_CURSOR_SONICBOOM) ? 6.0f : 3.0f;
      /* Real cursor color: a hardcoded pale tint was invisible on light
         backgrounds. */
      p->color = self.cursorColor ? self.cursorColor : 0x88C0D0;
    }
}

- (void)animationTick:(CADisplayLink *)link
{
  [self tickWithDt:(float) link.duration];
}

/* One animation step + composite.  Factored out of the CADisplayLink
   callback so a Lisp-level timer can drive it too: Emacs's event loop
   starves the display link while idle (it stops firing after a couple of
   ticks), so timer-driven cursor movements would spawn rings/trails that
   never animate.  Same medicine as video playback (mtl-video-tick). */
- (void)tickWithDt:(float)dt
{
  struct frame *f = self.emacsFrame;
  if (!f) return;
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.metalLayer) return;

  BOOL needsComposite = NO;

  /* Mirror the engine's cursor visibility (blink-cursor-mode toggles it
     via internal-show-cursor -> erase_phys_cursor, which never reaches
     the rif: it just repaints the glyph, invisible to an overlay
     cursor).  Poll it here so the animated cursor blinks too.  */
  if (WINDOWP (f->selected_window))
    {
      struct window *w = XWINDOW (f->selected_window);
      /* cursor_off_p is the blink phase itself (set by
         internal-show-cursor); phys_cursor_on_p alone can stay set when
         the erase path is optimized away.  */
      BOOL hidden = w->cursor_off_p;
      if (hidden != self.cursorHidden)
        {
          self.cursorHidden = hidden;
          needsComposite = YES;
        }
    }

  /* Update spring cursor (spring mode only; torpedo snaps instantly) */
  if (self.cursorMode == MTL_CURSOR_SPRING)
    {
      MtlSpring1D sx = self.springX, sy = self.springY;
      spring_update (&sx, self.curTargetX, dt);
      spring_update (&sy, self.curTargetY, dt);
      float dx = fabsf (sx.pos - self.curTargetX);
      float dy = fabsf (sy.pos - self.curTargetY);
      self.springX = sx;
      self.springY = sy;
      if (dx > 0.5f || dy > 0.5f) needsComposite = YES;
    }

  /* Age the torpedo trail so it fades out smoothly on its own.  Samples are
     pushed oldest-first at trailHead, so the head always holds the oldest one;
     retire it once it outlives MTL_TRAIL_LIFETIME. */
  if (self.cursorMode == MTL_CURSOR_TORPEDO && self.trailCount > 0)
    {
      for (NSUInteger i = 0; i < self.trailCount; i++)
        {
          NSUInteger slot = (self.trailHead + i) % MTL_TRAIL_LEN;
          trailAge[slot] += dt;
        }
      while (self.trailCount > 0
             && trailAge[self.trailHead] >= MTL_TRAIL_LIFETIME)
        {
          self.trailHead = (self.trailHead + 1) % MTL_TRAIL_LEN;
          self.trailCount--;
        }
      if (self.trailCount > 0) needsComposite = YES;
    }

  /* Update particles */
  if (self.nParticles > 0)
    {
      needsComposite = YES;
      NSUInteger alive = 0;
      for (NSUInteger i = 0; i < self.nParticles; i++)
        {
          MtlParticle *p = &particles[i];
          p->age += dt / 0.6f; /* 600ms lifetime */
          if (p->age >= 1.0f) continue;
          p->x  += p->vx * dt;
          p->y  += p->vy * dt;
          p->vx *= 0.92f;
          p->vy *= 0.92f;
          particles[alive++] = *p;
        }
      self.nParticles = alive;
    }

  /* Update scroll animation */
  if (fabsf (self.scrollOffset) > 0.5f)
    {
      CFTimeInterval now = CACurrentMediaTime();
      float t = (float)((now - self.scrollStartTime) / self.scrollDuration);
      float eased = easing_apply (self.scrollEasing, t);
      self.scrollOffset = self.scrollOffset * (1.0f - eased);
      if (fabsf (self.scrollOffset) < 0.5f) self.scrollOffset = 0.0f;
      needsComposite = YES;
    }

  /* While a video plays, every tick presents so the compositor
     samples the freshest decoded frame. */
  if (fd.videoPlayer && [fd.videoPlayer isPlaying])
    needsComposite = YES;

  /* Same while a buffer-switch crossfade is in flight. */
  if (fd.transitionTexture)
    needsComposite = YES;

  if (needsComposite || self.cursorDirty || [fd borderOverlaysNeedPump]
      || [fd decorationsNeedPump])
    {
      self.cursorDirty = NO;
      [fd presentCoalesced];
    }
}

/* Whether a cursor or scroll effect still has frames to show.  Blinking is
   not counted: it changes rarely, so the pump only polls for it.  */
- (BOOL)isAnimating
{
  return self.cursorDirty
    || self.trailCount > 0 || self.nParticles > 0
    || fabsf (self.scrollOffset) > 0.5f
    || (self.cursorMode == MTL_CURSOR_SPRING
        && (fabsf (self.springX.pos - self.curTargetX) > 0.5f
            || fabsf (self.springY.pos - self.curTargetY) > 0.5f));
}

@end

/* -----------------------------------------------------------------------
   @implementation MtlVideoPlayer (inline video)
   ----------------------------------------------------------------------- */

@implementation MtlVideoPlayer

/* NOTE: this file is compiled without ARC; always go through the property
   setters (retain semantics), never raw ivar assignment, or the AVPlayer
   graph gets autoreleased under us. */
- (instancetype)initWithURL:(NSURL *)url rect:(NSRect)rect loop:(BOOL)loop
{
  self = [super init];
  if (!self) return nil;

  AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
  NSDictionary *attrs = @{
    (id) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id) kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  self.output = [[[AVPlayerItemVideoOutput alloc]
                   initWithPixelBufferAttributes:attrs] autorelease];
  [item addOutput:self.output];

  self.player = [AVPlayer playerWithPlayerItem:item];
  self.player.actionAtItemEnd = loop ? AVPlayerActionAtItemEndNone
                                     : AVPlayerActionAtItemEndPause;
  if (loop)
    self.endObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                  object:item
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                (void) note;
                [item seekToTime:kCMTimeZero completionHandler:nil];
              }];

  CVMetalTextureCacheRef cache = NULL;
  CVMetalTextureCacheCreate (NULL, NULL, g_device, NULL, &cache);
  self.textureCache = cache;
  self.rect = rect;
  self.clipRect = NSZeroRect;
  self.loop = loop;
  [self.player play];
  return self;
}

- (BOOL)isPlaying
{
  return self.player != nil && self.player.rate != 0.0f;
}

/* Wrap the newest decoded pixel buffer as a Metal texture (zero copy via
   CVMetalTextureCache).  Falls back to the previous frame's texture when the
   output has nothing new, so redraws between video frames keep the picture. */
- (id<MTLTexture>)textureForNow
{
  if (!self.output || !self.textureCache) return self.currentTexture;

  CMTime t = [self.output itemTimeForHostTime:CACurrentMediaTime ()];
  if ([self.output hasNewPixelBufferForItemTime:t])
    {
      CVPixelBufferRef pb = [self.output copyPixelBufferForItemTime:t
                                                  itemTimeForDisplay:NULL];
      if (pb)
        {
          size_t w = CVPixelBufferGetWidth (pb);
          size_t h = CVPixelBufferGetHeight (pb);
          CVMetalTextureRef cvtex = NULL;
          if (CVMetalTextureCacheCreateTextureFromImage (
                NULL, self.textureCache, pb, NULL,
                MTLPixelFormatBGRA8Unorm, w, h, 0, &cvtex)
              == kCVReturnSuccess && cvtex)
            {
              /* The MTLTexture is only valid while its CV wrapper lives;
                 release the previous wrapper now that it is replaced. */
              if (self.currentCVTexture)
                CFRelease (self.currentCVTexture);
              self.currentCVTexture = cvtex;
              self.currentTexture = CVMetalTextureGetTexture (cvtex);
            }
          CVPixelBufferRelease (pb);
        }
    }
  return self.currentTexture;
}

- (void)shutdown
{
  [self.player pause];
  if (self.endObserver)
    {
      [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
      self.endObserver = nil;
    }
  self.player = nil;
  self.output = nil;
  self.currentTexture = nil;
  if (self.currentCVTexture)
    {
      CFRelease (self.currentCVTexture);
      self.currentCVTexture = NULL;
    }
  if (self.textureCache)
    {
      CVMetalTextureCacheFlush (self.textureCache, 0);
      CFRelease (self.textureCache);
      self.textureCache = NULL;
    }
}

- (void)dealloc
{
  [self shutdown];
  [super dealloc];
}

@end

/* -----------------------------------------------------------------------
   MtlFrameData
   ----------------------------------------------------------------------- */

static void
mtl_decoration_sample_track (MtlDecorationTrack *track, float *values, int count,
                             CFTimeInterval now, BOOL retire)
{
  if (!track->active) return;
  double elapsed = MAX (0.0, (now - track->start) / track->duration);
  float t = track->repeat ? (float) (elapsed - floor (elapsed)) : MIN (elapsed, 1.0);
  if (track->easing == 1) t = 1.0f - (1.0f - t) * (1.0f - t);
  else if (track->easing == 2) t = t * t * (3.0f - 2.0f * t);
  for (int i = 0; i < count; i++)
    values[i] = track->from[i] + (track->to[i] - track->from[i]) * t;
  if (retire && !track->repeat && elapsed >= 1.0) track->active = NO;
}

static void
mtl_decoration_sample (MtlDecorationRecord *record, CFTimeInterval now, BOOL retire)
{
  float rect[] = { record->value.rect.origin.x, record->value.rect.origin.y,
                   record->value.rect.size.width, record->value.rect.size.height };
  mtl_decoration_sample_track (&record->geometry, rect, 4, now, retire);
  record->value.rect = NSMakeRect (rect[0], rect[1], rect[2], rect[3]);
  mtl_decoration_sample_track (&record->opacity, &record->value.opacity, 1, now, retire);
  mtl_decoration_sample_track (&record->rotation, &record->value.startAngle, 1, now, retire);
}

@interface MtlFrameData ()
- (void)shutdown;
- (void)compositeToScreen;
- (void)openRenderEncoderClear:(BOOL)clear;
- (void)scrollRunFrom:(int)fromY to:(int)toY x:(int)x width:(int)w height:(int)h;
- (void)shiftGlyphsX:(int)x y:(int)y width:(int)w height:(int)h by:(int)shift;
- (void)drawFringeBits:(unsigned short *)bits dh:(int)dh bw:(int)bw
                    wd:(int)wd h:(int)h
                   atX:(int)x y:(int)y color:(unsigned long)color;
@property (nonatomic, strong) NSMutableDictionary *decorationRecords;
- (void)syncDecorationLayer:(unsigned long long)identifier;
- (void)syncTextLayer:(CALayer *)holder record:(MtlDecorationRecord *)record
           identifier:(unsigned long long)identifier;
- (void)applyMotion:(CALayer *)layer identifier:(unsigned long long)identifier
          transform:(CGAffineTransform)path_transform;
- (CALayer *)decorationContent:(NSNumber *)key class:(Class)class;
- (void)presentDrawable:(id<CAMetalDrawable>)drawable afterCommitting:(id<MTLCommandBuffer>)cmd;
- (void)drawDecorationsOnEncoder:(id<MTLRenderCommandEncoder>)encoder
                       texture:(id<MTLTexture>)texture;
@property (nonatomic, strong) NSMutableDictionary *borderRecords;
- (void)drawBorderOverlaysOnEncoder:(id<MTLRenderCommandEncoder>)encoder
                           texture:(id<MTLTexture>)texture;
- (void)requestBorderPresent;
- (void)requestDecorationPresent;
- (void)schedulePresent;
- (void)applyClipRect:(NSRect)r;
- (void)clearClipRect;
- (void)applyScissorNow;
@end

@implementation MtlFrameData

/* Stop callbacks and release frame-owned resources before the NS view closes.
   A queued present can retain this object until the main queue drains.  */
- (void)shutdown
{
  self.emacsFrame = NULL;
  self.animator.emacsFrame = NULL;
  [self.animator stopAnimating];
  self.animator = nil;
  [self.videoPlayer shutdown];
  self.videoPlayer = nil;
  self.needsPresent = NO;
  self.borderRecords = nil;
  self.decorationRecords = nil;
  [self.decorationLayer removeFromSuperlayer];
  self.decorationLayer = nil;
  self.decorationLayers = nil;
  self.decorationTexts = nil;
  self.decorationExtras = nil;
  self.decorationKeyframes = nil;

  if (g_batch_fd == self)
    {
      g_batch_fd = nil;
      g_batch_verts = 0;
      g_clip_on = NO;
    }
  [self.encoder endEncoding];
  self.encoder = nil;
  self.cmdBuf = nil;
  self.drawable = nil;
  self.staticTexture = nil;
  self.scratchTexture = nil;
  self.transitionTexture = nil;
  self.blitPipeline = nil;
  self.uniformBuffer = nil;
  [self.metalLayer removeFromSuperlayer];
  self.metalLayer = nil;
}

- (void)dealloc
{
  [self shutdown];
  [super dealloc];
}

- (BOOL)getDecoration:(unsigned long long)identifier record:(MtlDecorationRecord *)record
{
  NSValue *stored = [self.decorationRecords objectForKey:@(identifier)];
  if (!stored) return NO;
  [stored getValue:record];
  mtl_decoration_sample (record, CACurrentMediaTime (), NO);
  return YES;
}

- (BOOL)setDecoration:(MtlDecoration)value identifier:(unsigned long long)identifier
               cancel:(int)cancel
{
  if (!g_decoration_pipeline) return NO;
  MtlDecorationRecord record = { .value = value }, previous;
  if ([self getDecoration:identifier record:&previous])
    {
      if (!(cancel & 1)) { record.geometry = previous.geometry; record.value.rect = previous.value.rect; }
      if (!(cancel & 2)) { record.opacity = previous.opacity; record.value.opacity = previous.value.opacity; }
      if (!(cancel & 4)) { record.rotation = previous.rotation; record.value.startAngle = previous.value.startAngle; }
      /* Shape changes must not inherit a track with incompatible dimensions. */
      if (value.shape != previous.value.shape)
        record.geometry.active = record.rotation.active = NO;
    }
  if (!self.decorationRecords) self.decorationRecords = [NSMutableDictionary dictionary];
  [self.decorationRecords setObject:[NSValue valueWithBytes:&record objCType:@encode(MtlDecorationRecord)]
                            forKey:@(identifier)];
  [self syncDecorationLayer:identifier];
  [self requestDecorationPresent];
  return YES;
}

- (BOOL)removeDecoration:(unsigned long long)identifier
{
  if (![self.decorationRecords objectForKey:@(identifier)]) return NO;
  [self.decorationRecords removeObjectForKey:@(identifier)];
  [self.decorationTexts removeObjectForKey:@(identifier)];
  [self.decorationExtras removeObjectForKey:@(identifier)];
  [self.decorationKeyframes removeObjectForKey:@(identifier)];
  [self syncDecorationLayer:identifier];
  [self requestDecorationPresent];
  return YES;
}

- (BOOL)animateDecoration:(unsigned long long)identifier property:(int)property
                  target:(float *)target duration:(double)duration
                  easing:(int)easing repeat:(BOOL)repeat
{
  MtlDecorationRecord record;
  if (![self getDecoration:identifier record:&record]) return NO;
  MtlDecorationTrack *track = property == 1 ? &record.geometry
    : property == 3 ? &record.rotation : &record.opacity;
  *track = (MtlDecorationTrack) { .active = YES, .repeat = repeat,
    .start = CACurrentMediaTime (), .duration = duration, .easing = easing };
  float rect[] = { record.value.rect.origin.x, record.value.rect.origin.y,
                   record.value.rect.size.width, record.value.rect.size.height };
  for (int i = 0; i < (property == 1 ? 4 : 1); i++)
    { track->from[i] = property == 1 ? rect[i]
        : property == 3 ? record.value.startAngle : record.value.opacity;
      track->to[i] = target[i]; }
  [self.decorationRecords setObject:[NSValue valueWithBytes:&record objCType:@encode(MtlDecorationRecord)]
                            forKey:@(identifier)];
  [self syncDecorationLayer:identifier];
  [self requestDecorationPresent];
  return YES;
}

- (BOOL)decorationsNeedPump
{
  struct frame *f = self.emacsFrame;
  if (self.decorationLayer) return NO;   /* Core Animation runs their tracks */
  if (!f || !FRAME_LIVE_P (f) || !FRAME_VISIBLE_P (f) || !self.decorationRecords.count)
    return NO;
  NSSize size = self.metalLayer.frame.size;
  NSRect bounds = NSMakeRect (0, 0, size.width, size.height);
  for (NSNumber *key in self.decorationRecords)
    {
      MtlDecorationRecord record;
      [self getDecoration:key.unsignedLongLongValue record:&record];
      if (!NSIntersectsRect (record.value.clip, bounds)) continue;
      if (!record.value.hasFill && !record.value.hasStroke) continue;
      BOOL canShow = record.value.opacity > 0 || (record.opacity.active
        && (record.opacity.from[0] > 0 || record.opacity.to[0] > 0));
      if (!canShow) continue;
      NSRect rect = record.value.rect;
      if (record.geometry.active)
        {
          float *a = record.geometry.from, *b = record.geometry.to;
          float left = MIN (MIN (a[0], a[0] + a[2]), MIN (b[0], b[0] + b[2]));
          float top = MIN (MIN (a[1], a[1] + a[3]), MIN (b[1], b[1] + b[3]));
          float right = MAX (MAX (a[0], a[0] + a[2]), MAX (b[0], b[0] + b[2]));
          float bottom = MAX (MAX (a[1], a[1] + a[3]), MAX (b[1], b[1] + b[3]));
          rect = NSMakeRect (left, top, right - left, bottom - top);
        }
      /* Signed line deltas require normalized bounds for visibility checks. */
      if (record.value.shape == MTL_DECORATION_LINE)
        rect = NSMakeRect (MIN (rect.origin.x, rect.origin.x + rect.size.width),
                           MIN (rect.origin.y, rect.origin.y + rect.size.height),
                           fabs (rect.size.width), fabs (rect.size.height));
      CGFloat extent = record.value.strokeWidth * 0.5 + 1;
      if (!NSIntersectsRect (NSInsetRect (rect, -extent, -extent),
                             NSIntersectionRect (record.value.clip, bounds))) continue;
      if (record.geometry.active || record.opacity.active || record.rotation.active)
        return YES;
    }
  return NO;
}

- (void)drawDecorationsOnEncoder:(id<MTLRenderCommandEncoder>)enc
                       texture:(id<MTLTexture>)texture
{
  if (self.decorationLayer) return;   /* drawn by Core Animation instead */
  if (!self.decorationRecords.count || !g_decoration_pipeline) return;
  NSSize screen = self.metalLayer.frame.size;
  if (screen.width <= 0 || screen.height <= 0) return;
  NSArray *keys = [[self.decorationRecords allKeys]
    sortedArrayUsingComparator:^NSComparisonResult (NSNumber *a, NSNumber *b) {
      MtlDecorationRecord left, right;
      [[self.decorationRecords objectForKey:a] getValue:&left];
      [[self.decorationRecords objectForKey:b] getValue:&right];
      if (left.value.z != right.value.z)
        return left.value.z < right.value.z ? NSOrderedAscending : NSOrderedDescending;
      return [a compare:b];
    }];
  typedef struct {
    float width, height, radius, strokeWidth;
    float opacity, shape, startAngle, sweepAngle;
    float fill[4], stroke[4];
  } Params;
  CGFloat sx = texture.width / screen.width;
  CGFloat sy = texture.height / screen.height;
  NSRect bounds = NSMakeRect (0, 0, screen.width, screen.height);
  [enc setRenderPipelineState:g_decoration_pipeline];
  for (NSNumber *key in keys)
    {
      MtlDecorationRecord record;
      [[self.decorationRecords objectForKey:key] getValue:&record];
      NSRect clip = NSIntersectionRect (record.value.clip, bounds);
      if (NSIsEmptyRect (clip)) continue;
      BOOL visible = self.emacsFrame && FRAME_VISIBLE_P (self.emacsFrame);
      mtl_decoration_sample (&record, CACurrentMediaTime (), visible);
      [self.decorationRecords setObject:[NSValue valueWithBytes:&record objCType:@encode(MtlDecorationRecord)] forKey:key];
      MtlDecoration v = record.value;
      if (v.shape == MTL_DECORATION_TEXT) continue;   /* layers only */
      if (v.opacity == 0 || (!v.hasFill && !v.hasStroke)) continue;
      NSUInteger x0 = MIN ((NSUInteger) floor (NSMinX (clip) * sx), texture.width);
      NSUInteger y0 = MIN ((NSUInteger) floor (NSMinY (clip) * sy), texture.height);
      NSUInteger x1 = MIN ((NSUInteger) ceil (NSMaxX (clip) * sx), texture.width);
      NSUInteger y1 = MIN ((NSUInteger) ceil (NSMaxY (clip) * sy), texture.height);
      if (x1 <= x0 || y1 <= y0) continue;
      [enc setScissorRect:(MTLScissorRect) { x0, y0, x1 - x0, y1 - y0 }];
      float w = v.rect.size.width, h = v.rect.size.height;
      float extent = v.hasStroke ? v.strokeWidth * 0.5f + 1.0f : 1.0f;
      float x = v.rect.origin.x, y = v.rect.origin.y;
      float l = MIN (0, w) - extent, r = MAX (0, w) + extent;
      float t = MIN (0, h) - extent, b = MAX (0, h) + extent;
      MtlBorderVertex vertices[6] = {
        {x+l,y+t,l,t}, {x+r,y+t,r,t}, {x+l,y+b,l,b},
        {x+r,y+t,r,t}, {x+r,y+b,r,b}, {x+l,y+b,l,b} };
      Params params = { .width = w, .height = h,
        .radius = MIN (v.radius, MIN (w, h) * 0.5f), .strokeWidth = v.strokeWidth,
        .opacity = v.opacity, .shape = v.shape,
        .startAngle = v.startAngle, .sweepAngle = v.sweepAngle };
      unpack_color (v.fill, &params.fill[0], &params.fill[1], &params.fill[2]);
      unpack_color (v.stroke, &params.stroke[0], &params.stroke[1], &params.stroke[2]);
      params.fill[3] = v.hasFill; params.stroke[3] = v.hasStroke;
      [enc setVertexBytes:vertices length:sizeof vertices atIndex:0];
      [enc setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
      [enc setFragmentBytes:&params length:sizeof params atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
  [enc setScissorRect:(MTLScissorRect) { 0, 0, texture.width, texture.height }];
}

- (BOOL)setBorderWithID:(unsigned long long)identifier
                   rect:(NSRect)rect
                   clip:(NSRect)clip
                  state:(MtlBorderState)state
                  color:(unsigned long)color
                  style:(MtlBorderStyle)style
{
  if (!self.borderRecords)
    self.borderRecords = [NSMutableDictionary dictionary];
  if (NSIsEmptyRect (clip))
    {
      [self removeBorderWithID:identifier];
      return YES;
    }

  NSNumber *key = [NSNumber numberWithUnsignedLongLong:identifier];
  NSValue *oldValue = [self.borderRecords objectForKey:key];
  MtlBorderRecord record = { .rect = rect, .clip = clip, .state = state,
                             .color = color, .style = style };
  if (oldValue)
    {
      MtlBorderRecord previous;
      [oldValue getValue:&previous];
      if (previous.state == state)
        {
          /* Geometry and style updates must not restart the animation. */
          record.startTime = previous.startTime;
          record.cleanupPresented = previous.cleanupPresented;
        }
      else
        record.startTime = CACurrentMediaTime ();

      if (NSEqualRects (previous.rect, rect)
          && NSEqualRects (previous.clip, clip)
          && previous.state == state && previous.color == color
          && previous.style.cornerRadius == style.cornerRadius
          && previous.style.strokeWidth == style.strokeWidth
          && previous.style.opacity == style.opacity
          && previous.style.cycleDuration == style.cycleDuration
          && previous.style.runnerFraction == style.runnerFraction
          && previous.style.glowOpacity == style.glowOpacity)
        return YES;
    }
  else
    record.startTime = CACurrentMediaTime ();

  [self.borderRecords setObject:[NSValue valueWithBytes:&record
                                               objCType:@encode(MtlBorderRecord)]
                         forKey:key];
  [self requestBorderPresent];
  return YES;
}

- (BOOL)removeBorderWithID:(unsigned long long)identifier
{
  NSNumber *key = [NSNumber numberWithUnsignedLongLong:identifier];
  if (![self.borderRecords objectForKey:key])
    return NO;
  [self.borderRecords removeObjectForKey:key];
  [self requestBorderPresent];
  return YES;
}

- (BOOL)borderOverlaysNeedPump
{
  struct frame *f = self.emacsFrame;
  if (!self.borderRecords.count || !g_border_pipeline || !f
      || !FRAME_LIVE_P (f) || !FRAME_VISIBLE_P (f))
    return NO;

  NSSize size = self.metalLayer.frame.size;
  NSRect bounds = NSMakeRect (0, 0, size.width, size.height);
  CFTimeInterval now = CACurrentMediaTime ();
  for (NSNumber *key in self.borderRecords)
    {
      MtlBorderRecord record;
      [[self.borderRecords objectForKey:key] getValue:&record];
      if (!NSIntersectsRect (record.clip, bounds) || record.style.opacity == 0)
        continue;
      if (record.state == MTL_BORDER_RUNNING && record.style.runnerFraction > 0)
        return YES;
      if (record.state == MTL_BORDER_COMPLETE
          && (now - record.startTime < MTL_BORDER_COMPLETE_DURATION
              || !record.cleanupPresented))
        return YES;
    }
  return NO;
}

/* Clip subsequent draws to R (logical pixels), like the NS backend's
   ns_focus clipping with get_glyph_string_clip_rect.  This is what keeps
   a filled-box cursor on a tall row (e.g. an image line) at the size of
   the character cell instead of the whole row, and stops overhangs from
   bleeding outside the window area.  Only records state: batched quads
   are clamped against it on the CPU at queue time (mtl_batch_append),
   and the non-batched primitives apply it as a real scissor right
   before their draw (applyScissorNow).  */
- (void)applyClipRect:(NSRect)r
{
  g_clip_on = YES;
  g_clip_rect = r;
}

- (void)clearClipRect
{
  g_clip_on = NO;
}

/* Apply the recorded clip as the encoder's scissor, in physical pixels.
   Called by the non-batched primitives (images, fringe bitmaps, color
   glyphs) right before they draw.  */
- (void)applyScissorNow
{
  if (!self.encoder || !self.staticTexture) return;
  long tw = (long) self.staticTexture.width;
  long th = (long) self.staticTexture.height;
  if (!g_clip_on)
    {
      MTLScissorRect sc = { 0, 0, (NSUInteger) tw, (NSUInteger) th };
      [self.encoder setScissorRect:sc];
      return;
    }
  NSRect r = g_clip_rect;
  CGSize dsz = self.metalLayer.drawableSize;
  NSSize lsz = self.metalLayer.frame.size;
  double scx = lsz.width  > 0 ? dsz.width  / lsz.width  : 1.0;
  double scy = lsz.height > 0 ? dsz.height / lsz.height : 1.0;
  long x0 = lround (NSMinX (r) * scx), y0 = lround (NSMinY (r) * scy);
  long x1 = lround (NSMaxX (r) * scx), y1 = lround (NSMaxY (r) * scy);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > tw) x1 = tw;
  if (y1 > th) y1 = th;
  if (x1 <= x0 || y1 <= y0)
    { x0 = tw - 1; y0 = th - 1; x1 = tw; y1 = th; }  /* effectively clip out */
  MTLScissorRect sc = { (NSUInteger) x0, (NSUInteger) y0,
                        (NSUInteger) (x1 - x0), (NSUInteger) (y1 - y0) };
  [self.encoder setScissorRect:sc];
}

/* Open a render command encoder targeting the static texture.  CLEAR wipes it to
   the frame background (only for a fresh/resized texture); otherwise LOAD
   preserves the previous content (Emacs redraws just the dirty regions).
   Factored out so beginFrame and scrollRunFrom: can both reopen the encoder. */
- (void)openRenderEncoderClear:(BOOL)clear
{
  struct frame *f = self.emacsFrame;
  unsigned long bg = f ? ns_color_to_pixel (FRAME_BACKGROUND_COLOR (f)) : 0xFFFFFF;
  float r, g, b;
  unpack_color (bg, &r, &g, &b);

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture     = self.staticTexture;
  rpd.colorAttachments[0].loadAction  = clear ? MTLLoadActionClear : MTLLoadActionLoad;
  rpd.colorAttachments[0].clearColor  = MTLClearColorMake (r, g, b, 1.0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  self.encoder = [self.cmdBuf renderCommandEncoderWithDescriptor:rpd];
  [self.encoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [self.encoder setFragmentBuffer:self.uniformBuffer offset:0 atIndex:1];
}

/* RIF scroll_run: move a block of already-rendered pixels inside the static
   texture (from y -> to y, full width of the run).  Coordinates come in as
   Emacs logical pixels; the texture is physical, so scale by the backing factor.
   A single GPU copy can't have overlapping source/destination, so bounce the
   region through scratchTexture. */
- (void)scrollRunFrom:(int)fromY to:(int)toY x:(int)x width:(int)w height:(int)h
{
  if (!self.staticTexture || !self.scratchTexture || w <= 0 || h <= 0) return;

  CGSize dsz = self.metalLayer.drawableSize;
  NSSize lsz = self.metalLayer.frame.size;
  double scx = lsz.width  > 0 ? dsz.width  / lsz.width  : 1.0;
  double scy = lsz.height > 0 ? dsz.height / lsz.height : 1.0;

  long px = lround (x * scx), pw = lround (w * scx);
  long pfrom = lround (fromY * scy), pto = lround (toY * scy), ph = lround (h * scy);
  long tw = (long) self.staticTexture.width, tht = (long) self.staticTexture.height;

  if (px < 0) px = 0;
  if (pfrom < 0 || pto < 0) return;
  if (px >= tw || pfrom >= tht || pto >= tht) return;
  if (px + pw > tw)  pw = tw - px;
  if (pfrom + ph > tht) ph = tht - pfrom;
  if (pto + ph > tht)   ph = tht - pto;
  if (pw <= 0 || ph <= 0) return;

  /* The copy must run after the draws already recorded this frame.  Flush
     the queued quads, end the render encoder, do the blit on the same
     command buffer (Metal's hazard tracking orders it after the render
     writes), then reopen the encoder with LOAD so subsequent
     draw_glyph_string calls land on top of the moved pixels. */
  mtl_flush_batch ();
  BOOL hadEncoder = (self.encoder != nil);
  if (self.encoder) { [self.encoder endEncoding]; self.encoder = nil; }
  if (!self.cmdBuf) self.cmdBuf = [g_queue commandBuffer];

  id<MTLBlitCommandEncoder> blit = [self.cmdBuf blitCommandEncoder];
  if (pto >= pfrom + ph || pfrom >= pto + ph)
    /* Disjoint regions (page scrolls, large jumps): one direct copy is
       legal -- only OVERLAPPING copies are undefined -- and halves the
       bandwidth.  */
    [blit copyFromTexture:self.staticTexture sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake ((NSUInteger) px, (NSUInteger) pfrom, 0)
               sourceSize:MTLSizeMake ((NSUInteger) pw, (NSUInteger) ph, 1)
                toTexture:self.staticTexture destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake ((NSUInteger) px, (NSUInteger) pto, 0)];
  else
    {
      /* Overlapping move (single-line scrolls): bounce through scratch.  */
      [blit copyFromTexture:self.staticTexture sourceSlice:0 sourceLevel:0
               sourceOrigin:MTLOriginMake ((NSUInteger) px, (NSUInteger) pfrom, 0)
                 sourceSize:MTLSizeMake ((NSUInteger) pw, (NSUInteger) ph, 1)
                  toTexture:self.scratchTexture destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake (0, 0, 0)];
      [blit copyFromTexture:self.scratchTexture sourceSlice:0 sourceLevel:0
               sourceOrigin:MTLOriginMake (0, 0, 0)
                 sourceSize:MTLSizeMake ((NSUInteger) pw, (NSUInteger) ph, 1)
                  toTexture:self.staticTexture destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake ((NSUInteger) px, (NSUInteger) pto, 0)];
    }
  [blit endEncoding];

  if (hadEncoder)
    [self openRenderEncoderClear:NO];
  else
    { [self.cmdBuf commit]; self.cmdBuf = nil; }
}

/* E3 / RIF shift_glyphs_for_insert: move an area horizontally by SHIFT logical
   pixels (insert/delete-char optimization: shift the rest of the line instead
   of redrawing it).  Mirrors ns_shift_glyphs_for_insert; same scratch-texture
   bounce and encoder handling as scrollRunFrom: since src and dst overlap. */
- (void)shiftGlyphsX:(int)x y:(int)y width:(int)w height:(int)h by:(int)shift
{
  if (!self.staticTexture || !self.scratchTexture
      || w <= 0 || h <= 0 || shift == 0)
    return;

  CGSize dsz = self.metalLayer.drawableSize;
  NSSize lsz = self.metalLayer.frame.size;
  double scx = lsz.width  > 0 ? dsz.width  / lsz.width  : 1.0;
  double scy = lsz.height > 0 ? dsz.height / lsz.height : 1.0;

  long px  = lround (x * scx), pw = lround (w * scx);
  long py  = lround (y * scy), ph = lround (h * scy);
  long pto = lround ((x + shift) * scx);
  long tw  = (long) self.staticTexture.width;
  long tht = (long) self.staticTexture.height;

  if (px < 0 || py < 0 || pto < 0) return;
  if (px >= tw || py >= tht || pto >= tw) return;
  if (px + pw > tw)  pw = tw - px;
  if (pto + pw > tw) pw = tw - pto;
  if (py + ph > tht) ph = tht - py;
  if (pw <= 0 || ph <= 0) return;

  mtl_flush_batch ();          /* queued quads draw before the move */
  BOOL hadEncoder = (self.encoder != nil);
  if (self.encoder) { [self.encoder endEncoding]; self.encoder = nil; }
  if (!self.cmdBuf) self.cmdBuf = [g_queue commandBuffer];

  id<MTLBlitCommandEncoder> blit = [self.cmdBuf blitCommandEncoder];
  [blit copyFromTexture:self.staticTexture sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake ((NSUInteger) px, (NSUInteger) py, 0)
             sourceSize:MTLSizeMake ((NSUInteger) pw, (NSUInteger) ph, 1)
              toTexture:self.scratchTexture destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (0, 0, 0)];
  [blit copyFromTexture:self.scratchTexture sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (0, 0, 0)
             sourceSize:MTLSizeMake ((NSUInteger) pw, (NSUInteger) ph, 1)
              toTexture:self.staticTexture destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake ((NSUInteger) pto, (NSUInteger) py, 0)];
  [blit endEncoding];

  if (hadEncoder)
    [self openRenderEncoderClear:NO];
  else
    { [self.cmdBuf commit]; self.cmdBuf = nil; }
}

- (void)beginFrame
{
  CGSize dsz = self.metalLayer.drawableSize;

  /* Start the cycle with an empty batch (endFrame drains it; this is the
     defensive reset, mirroring gl_drv_begin_frame).  */
  g_batch_verts = 0;
  g_batch_fd = nil;
  g_clip_on = NO;

  /* Track the backing scale so the glyph atlas is baked at physical resolution.
     If it changes (window moved to a different-DPI monitor), drop the atlas so
     glyphs re-rasterize at the new scale. */
  NSSize fsz = self.metalLayer.frame.size;
  CGFloat scale = fsz.width > 0 ? dsz.width / fsz.width : 1.0;
  if (scale > 0 && fabs (scale - g_atlas_scale) > 0.01)
    {
      g_atlas_scale  = scale;
      mtl_atlas_reset ();
      mtl_color_glyph_cache_clear ();   /* color glyphs are scale-baked too */
      /* Inline image textures are baked at the backing scale too.  */
      if (g_image_texture_cache)
        CFDictionaryRemoveAllValues (g_image_texture_cache);
      if (g_image_hash_cache)
        CFDictionaryRemoveAllValues (g_image_hash_cache);
    }

  /* Ensure staticTexture exists and matches drawable size.
     Bug fix: multiple update_begin/end cycles happen per Emacs redisplay pass
     (cursor blink, modeline, etc.). Using MTLLoadActionClear on every beginFrame
     wiped out the drawing from the PREVIOUS cycle, leaving only the background.
     Fix: only clear when the texture is (re)created; preserve content otherwise.
     Emacs's draw_glyph_string already fills backgrounds for updated regions. */
  NSUInteger tw = (NSUInteger)dsz.width, th = (NSUInteger)dsz.height;
  BOOL needsClear = NO;
  if (!self.staticTexture
      || self.staticTexture.width != tw
      || self.staticTexture.height != th)
    {
      MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:tw height:th mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModePrivate;
      self.staticTexture = [[g_device newTextureWithDescriptor:td] autorelease];
      self.scratchTexture = [[g_device newTextureWithDescriptor:td] autorelease];
      needsClear = YES;  /* New or resized texture: clear to background color */
    }

  NSSize sz = self.metalLayer.frame.size;
  MtlUniforms *u = (MtlUniforms *)[self.uniformBuffer contents];
  u->screen_width  = (float)sz.width;
  u->screen_height = (float)sz.height;

  self.cmdBuf = [g_queue commandBuffer];
  [self openRenderEncoderClear:needsClear];
}

/* Emit the queued quads (see g_batch) as a single draw call.  The quads
   were clipped on the CPU when queued, so the draw runs under a
   full-frame scissor; the non-batched primitives re-apply the recorded
   clip themselves (applyScissorNow).  Small batches ride in the command
   buffer via setVertexBytes; larger ones get a one-shot shared buffer
   the encoder keeps alive until execution.  */
static void
mtl_flush_batch (void)
{
  MtlFrameData *fd = g_batch_fd;
  if (g_batch_verts == 0 || !fd) return;
  if (!fd.encoder || !g_glyph_pipeline) { g_batch_verts = 0; return; }
  MTLScissorRect sc = { 0, 0, fd.staticTexture.width,
                        fd.staticTexture.height };
  [fd.encoder setScissorRect:sc];
  [fd.encoder setRenderPipelineState:g_glyph_pipeline];
  NSUInteger len = (NSUInteger) g_batch_verts * sizeof (MtlGlyphVertex);
  if (len <= 4096)              /* Metal's setVertexBytes ceiling */
    [fd.encoder setVertexBytes:g_batch length:len atIndex:0];
  else
    {
      id<MTLBuffer> vb =
        [g_device newBufferWithBytes:g_batch length:len
                             options:MTLResourceStorageModeShared];
      [fd.encoder setVertexBuffer:vb offset:0 atIndex:0];
      [vb release];             /* the encoder retains it until execution */
    }
  [fd.encoder setVertexBuffer:fd.uniformBuffer offset:0 atIndex:1];
  [fd.encoder setFragmentTexture:g_atlas atIndex:0];
  [fd.encoder setFragmentSamplerState:g_sampler atIndex:0];
  [fd.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                 vertexCount:(NSUInteger) g_batch_verts];
  g_batch_verts = 0;
}

/* Queue one textured quad (logical pixel coords) into the shared batch,
   clamping it on the CPU against FD's recorded clip rect (the same
   logical bounds the scissor would have used) with the texture
   coordinates adjusted proportionally.  Clipping at queue time is what
   lets the batch survive clip changes and cross glyph strings.  */
static void
mtl_batch_append (MtlFrameData *fd, float x0, float y0, float x1, float y1,
                  float u0, float v0, float u1, float v1,
                  float r, float g, float b)
{
  if (x0 >= x1 || y0 >= y1)
    return;                     /* degenerate quad: nothing to draw */

  if (g_batch_fd && g_batch_fd != fd)
    mtl_flush_batch ();
  g_batch_fd = fd;

  if (g_clip_on)
    {
      NSRect c = g_clip_rect;
      float cx0 = (float) NSMinX (c), cy0 = (float) NSMinY (c);
      float cx1 = (float) NSMaxX (c), cy1 = (float) NSMaxY (c);
      if (cx1 <= cx0 || cy1 <= cy0)
        return;                 /* clipped out entirely */
      if (x0 >= cx1 || x1 <= cx0 || y0 >= cy1 || y1 <= cy0)
        return;
      float du = (u1 - u0) / (x1 - x0), dv = (v1 - v0) / (y1 - y0);
      if (x0 < cx0) { u0 += du * (cx0 - x0); x0 = cx0; }
      if (x1 > cx1) { u1 -= du * (x1 - cx1); x1 = cx1; }
      if (y0 < cy0) { v0 += dv * (cy0 - y0); y0 = cy0; }
      if (y1 > cy1) { v1 -= dv * (y1 - cy1); y1 = cy1; }
    }

  if (g_batch_verts + 6 > g_batch_cap)
    {
      int cap = g_batch_cap ? g_batch_cap * 2 : 4096;
      MtlGlyphVertex *p =
        realloc (g_batch, (size_t) cap * sizeof (MtlGlyphVertex));
      if (!p) { mtl_flush_batch (); return; }
      g_batch = p;
      g_batch_cap = cap;
    }

  MtlGlyphVertex quad[6] = {
    {x0,y0, u0,v0, r,g,b,1}, {x1,y0, u1,v0, r,g,b,1},
    {x0,y1, u0,v1, r,g,b,1}, {x1,y0, u1,v0, r,g,b,1},
    {x1,y1, u1,v1, r,g,b,1}, {x0,y1, u0,v1, r,g,b,1},
  };
  memcpy (g_batch + g_batch_verts, quad, sizeof quad);
  g_batch_verts += 6;
}

- (void)fillRect:(NSRect)rect color:(unsigned long)color
{
  if (!self.encoder || !g_glyph_pipeline) return;
  /* A solid rect is a quad sampling the atlas' white block: coverage 1.0
     passes the gamma curve unchanged, so it joins the glyph batch with
     no pipeline switch and no flush.  */
  float r, g, b;
  unpack_color (color, &r, &g, &b);
  mtl_batch_append (self,
                    (float) NSMinX (rect), (float) NSMinY (rect),
                    (float) NSMaxX (rect), (float) NSMaxY (rect),
                    MTL_WHITE_U, MTL_WHITE_V, MTL_WHITE_U, MTL_WHITE_V,
                    r, g, b);
}

- (void)drawGlyph:(MtlGlyphCacheEntry *)ge
               at:(CGPoint)origin
            color:(unsigned long)fgcolor
{
  if (!self.encoder || !g_glyph_pipeline || !ge || ge->width == 0) return;

  float fr, fg, fb;
  unpack_color (fgcolor, &fr, &fg, &fb);

  /* The atlas glyph is baked at physical resolution (g_atlas_scale); the draw
     site works in logical pixels, so divide the physical metrics back down.  The
     quad ends up logical-sized but textured from a high-res glyph, which maps
     ~1:1 onto the physical static texture and stays crisp on Retina. */
  CGFloat s = g_atlas_scale;
  float x0 = (float)(origin.x - ge->bearing_x / s);
  float y0 = (float)(origin.y - ge->bearing_y / s);

  mtl_batch_append (self, x0, y0,
                    (float) (x0 + ge->width / s),
                    (float) (y0 + ge->height / s),
                    (float) ge->atlas_x / MTL_ATLAS_WIDTH,
                    (float) ge->atlas_y / MTL_ATLAS_HEIGHT,
                    (float) (ge->atlas_x + ge->width) / MTL_ATLAS_WIDTH,
                    (float) (ge->atlas_y + ge->height) / MTL_ATLAS_HEIGHT,
                    fr, fg, fb);
}

/* Rasterize a fringe bitmap (rows of bits, MSB-first like the X backend's
   XCreatePixmapFromBitmapData) into an R8 coverage texture and draw it as
   a colored quad.  Reuses the glyph pipeline (coverage * color).
   bits[dh+r] is row r; the visible window is [dh, dh+h).  The textures
   are cached by an FNV-1a hash of the visible rows plus the box size: a
   fringe indicator redraws with the same handful of patterns over and
   over, the coverage is color-independent (the color rides on the
   vertices), and a cached texture is immutable after creation so reusing
   it across queued draws is safe (only mutation would be a hazard).  */
- (void)drawFringeBits:(unsigned short *)bits dh:(int)dh bw:(int)bw
                    wd:(int)wd h:(int)h
                   atX:(int)x y:(int)y color:(unsigned long)color
{
  if (!self.encoder || !g_glyph_pipeline || !bits || wd <= 0 || h <= 0) return;
  if (wd > 32) wd = 32;
  if (bw < wd) bw = wd;

  mtl_flush_batch ();          /* binds its own texture; drain quads first */
  [self applyScissorNow];      /* non-batched: needs the real scissor */

  unsigned long long hash = 1469598103934665603ULL;
  for (int r = 0; r < h; r++)
    {
      hash ^= (unsigned long long) bits[dh + r];
      hash *= 1099511628211ULL;
    }
  hash ^= ((unsigned long long) bw << 40)
    ^ ((unsigned long long) wd << 20) ^ (unsigned long long) h;

#define MTL_BITMAP_CAP 64
  static struct { unsigned long long hash; id<MTLTexture> tex; }
    cache[MTL_BITMAP_CAP];
  static int cache_next;
  id<MTLTexture> tex = nil;
  for (int i = 0; i < MTL_BITMAP_CAP; i++)
    if (cache[i].tex && cache[i].hash == hash)
      { tex = cache[i].tex; break; }
  if (!tex)
    {
      MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:(NSUInteger) wd
                                                          height:(NSUInteger) h mipmapped:NO];
      td.usage = MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModeShared;
      tex = [g_device newTextureWithDescriptor:td];

      uint8_t *buf = (uint8_t *) calloc ((size_t) wd * (size_t) h, 1);
      for (int r = 0; r < h; r++)
        {
          unsigned short row = bits[dh + r];
          for (int c = 0; c < wd; c++)
            /* MSB-first within the bitmap's TRUE width: when the fringe is
               narrower than the bitmap, this shows its left-aligned part
               (the native backends clip the full bitmap the same way). */
            if ((row >> (bw - 1 - c)) & 1)
              buf[r * wd + c] = 0xFF;
        }
      [tex replaceRegion:MTLRegionMake2D (0, 0, (NSUInteger) wd, (NSUInteger) h)
             mipmapLevel:0 withBytes:buf bytesPerRow:(NSUInteger) wd];
      free (buf);

      /* MRC: the cache owns one reference (from newTexture...); evicting
         releases it (any in-flight command buffer holds its own).  */
      if (cache[cache_next].tex)
        [cache[cache_next].tex release];
      cache[cache_next].hash = hash;
      cache[cache_next].tex = tex;
      cache_next = (cache_next + 1) % MTL_BITMAP_CAP;
    }

  float fr, fg, fb;
  unpack_color (color, &fr, &fg, &fb);
  float x0 = x, y0 = y, x1 = x + wd, y1 = y + h;
  MtlGlyphVertex v[6] = {
    {x0,y0, 0,0, fr,fg,fb,1}, {x1,y0, 1,0, fr,fg,fb,1}, {x0,y1, 0,1, fr,fg,fb,1},
    {x1,y0, 1,0, fr,fg,fb,1}, {x1,y1, 1,1, fr,fg,fb,1}, {x0,y1, 0,1, fr,fg,fb,1},
  };
  [self.encoder setRenderPipelineState:g_glyph_pipeline];
  [self.encoder setVertexBytes:v length:sizeof(v) atIndex:0];
  [self.encoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [self.encoder setFragmentTexture:tex atIndex:0];
  [self.encoder setFragmentSamplerState:g_nearest_sampler atIndex:0];
  [self.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

- (void)endFrame
{
  [self endFramePresent:YES];
}

/* How close two presents may be before the second one is deferred:
   redisplay runs several update cycles back-to-back (buffer window +
   echo area) and, with display sync on, every present blocks on a
   drawable -- two blocking presents per keystroke halved typing
   throughput.  Half a 60 Hz frame keeps coalescing inside one refresh
   while never delaying a visible update by more than ~8 ms.
   Animation, video and cursor-only updates must use the same coalescer:
   otherwise display-link callbacks can stay continuously ready while
   waiting for drawables, starving Emacs input and process handling.  */
#define MTL_PRESENT_COALESCE 0.008

/* Schedule the deferred present: a one-shot main-queue block flushes it
   shortly after, unless an earlier present already absorbed it.  */
- (void)schedulePresent
{
  if (self.presentScheduled) return;
  self.presentScheduled = YES;
  dispatch_after (dispatch_time (DISPATCH_TIME_NOW,
                                 (int64_t) (MTL_PRESENT_COALESCE * NSEC_PER_SEC)),
                  dispatch_get_main_queue (), ^{
    self.presentScheduled = NO;
    if (self.needsPresent)
      [self presentCoalesced];
  });
}

- (void)presentCoalesced
{
  /* Layout hooks can mutate decorations before update_begin opens an encoder.
     Do not combine those records with text from the previous redisplay.  The
     deferred flush retries through this gate if redisplay is still active.  */
  if (redisplaying_p || self.encoder
      || CACurrentMediaTime () - self.lastPresentTime < MTL_PRESENT_COALESCE)
    {
      self.needsPresent = YES;
      [self schedulePresent];
    }
  else
    [self compositeToScreen];
}

- (void)requestDecorationPresent
{
  struct frame *f = self.emacsFrame;
  /* Hidden frames retain elapsed tracks but do not ask AppKit for drawables. */
  if (self.decorationLayer) return;   /* Core Animation shows layer changes */
  if (f && FRAME_LIVE_P (f) && FRAME_VISIBLE_P (f)) [self requestBorderPresent];
}

- (void)requestBorderPresent
{
  if (self.encoder)
    {
      self.needsPresent = YES;
      [self schedulePresent];
    }
  else
    [self presentCoalesced];
}

/* Commit the static-texture draws.  When PRESENT is NO, only the static texture
   is updated and the on-screen present is deferred (needsPresent), so a sequence
   of immediate draws (clear_mouse_face + show_mouse_face) is shown in a single
   composite by flush_display instead of flickering through each step.
   When presenting, the composite pass is encoded on the SAME command
   buffer as the cycle's draws (one commit instead of two).  */
- (void)endFramePresent:(BOOL)present
{
  if (!self.encoder) return;
  mtl_flush_batch ();          /* drain any quads left from the last string */
  g_batch_fd = nil;            /* the batch no longer targets this frame */
  [self.encoder endEncoding];
  self.encoder = nil;
  self.drawable = nil;

  if (present
      && CACurrentMediaTime () - self.lastPresentTime >= MTL_PRESENT_COALESCE
      && self.staticTexture && g_blit_pipeline)
    {
      id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
      if (drawable)
        {
          [self encodeCompositeOn:self.cmdBuf drawable:drawable];
          [self presentDrawable:drawable afterCommitting:self.cmdBuf];
          self.cmdBuf = nil;
          return;
        }
    }

  [self.cmdBuf commit];
  self.cmdBuf  = nil;
  if (present)
    {
      /* Too soon after the previous present: defer (the next cycle's
         present or the scheduled block makes it visible).  */
      self.needsPresent = YES;
      [self schedulePresent];
    }
  else
    self.needsPresent = YES;
}

- (void)compositeToScreen
{
  if (!self.staticTexture || !g_blit_pipeline) return;

  id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
  if (!drawable) return;

  id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
  [self encodeCompositeOn:cmd drawable:drawable];
  [self presentDrawable:drawable afterCommitting:cmd];
}


/* Present DRAWABLE after CMD is committed.  With decoration layers, the frame
   joins the current Core Animation transaction, so layer changes made for
   this redisplay appear in the same screen update as its text.  */
- (void)presentDrawable:(id<CAMetalDrawable>)drawable afterCommitting:(id<MTLCommandBuffer>)cmd
{
  if (self.metalLayer.presentsWithTransaction)
    {
      [cmd commit];
      [cmd waitUntilScheduled];
      [drawable present];
    }
  else
    {
      [cmd presentDrawable:drawable];
      [cmd commit];
    }
}

/* SVG path data: every command in absolute and relative form, including
   elliptical arcs, which become relative arcs of a transformed unit circle.  */
static const char *
mtl_svg_skip (const char *p)
{
  while (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  return p;
}

static bool
mtl_svg_number (const char **p, double *value)
{
  const char *start = mtl_svg_skip (*p);
  char *end;
  *value = strtod (start, &end);
  if (end == start) return false;
  *p = end;
  return true;
}

static bool
mtl_svg_flag (const char **p, int *flag)
{
  const char *q = mtl_svg_skip (*p);
  if (*q != '0' && *q != '1') return false;
  *flag = *q - '0';
  *p = q + 1;
  return true;
}

static void
mtl_svg_arc (CGMutablePathRef path, double x1, double y1, double rx, double ry,
             double degrees, int large, int sweep, double x2, double y2)
{
  if (rx == 0 || ry == 0) { CGPathAddLineToPoint (path, NULL, x2, y2); return; }
  rx = fabs (rx); ry = fabs (ry);
  double phi = degrees * M_PI / 180, c = cos (phi), s = sin (phi);
  double dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
  double x1p = c * dx + s * dy, y1p = -s * dx + c * dy;
  double lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
  if (lambda > 1) { rx *= sqrt (lambda); ry *= sqrt (lambda); }
  double num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  double den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  double coef = (den > 0 ? sqrt (MAX (0, num / den)) : 0) * (large == sweep ? -1 : 1);
  double cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx;
  double cx = c * cxp - s * cyp + (x1 + x2) / 2, cy = s * cxp + c * cyp + (y1 + y2) / 2;
  double ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
  double vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
  double theta = atan2 (uy, ux);
  double delta = atan2 (ux * vy - uy * vx, ux * vx + uy * vy);
  if (!sweep && delta > 0) delta -= 2 * M_PI;
  else if (sweep && delta < 0) delta += 2 * M_PI;
  CGAffineTransform t = CGAffineTransformMakeTranslation (cx, cy);
  t = CGAffineTransformRotate (t, phi);
  t = CGAffineTransformScale (t, rx, ry);
  CGPathAddRelativeArc (path, &t, 0, 0, 1, theta, delta);
}

CGPathRef
mtl_svg_path_create (const char *data)
{
  CGMutablePathRef path = CGPathCreateMutable ();
  const char *p = data;
  char command = 0;
  double x = 0, y = 0, start_x = 0, start_y = 0, control_x = 0, control_y = 0;
  char previous = 0;
  for (;;)
    {
      p = mtl_svg_skip (p);
      if (!*p) break;
      if (isalpha ((unsigned char) *p)) command = *p++;
      else if (!command) goto fail;
      bool relative = islower ((unsigned char) command);
      double ox = relative ? x : 0, oy = relative ? y : 0;
      double a[7];
      char upper = toupper ((unsigned char) command);
      if (upper != 'M' && upper != 'Z' && CGPathIsEmpty (path)) goto fail;
      switch (upper)
        {
        case 'M':
          if (!mtl_svg_number (&p, &a[0]) || !mtl_svg_number (&p, &a[1])) goto fail;
          x = start_x = ox + a[0]; y = start_y = oy + a[1];
          CGPathMoveToPoint (path, NULL, x, y);
          /* Further pairs after a move are lines.  */
          command = relative ? 'l' : 'L';
          break;
        case 'L':
          if (!mtl_svg_number (&p, &a[0]) || !mtl_svg_number (&p, &a[1])) goto fail;
          x = ox + a[0]; y = oy + a[1];
          CGPathAddLineToPoint (path, NULL, x, y);
          break;
        case 'H':
          if (!mtl_svg_number (&p, &a[0])) goto fail;
          x = ox + a[0];
          CGPathAddLineToPoint (path, NULL, x, y);
          break;
        case 'V':
          if (!mtl_svg_number (&p, &a[0])) goto fail;
          y = oy + a[0];
          CGPathAddLineToPoint (path, NULL, x, y);
          break;
        case 'C':
          for (int i = 0; i < 6; i++) if (!mtl_svg_number (&p, &a[i])) goto fail;
          CGPathAddCurveToPoint (path, NULL, ox + a[0], oy + a[1], ox + a[2], oy + a[3],
                                 ox + a[4], oy + a[5]);
          control_x = ox + a[2]; control_y = oy + a[3];
          x = ox + a[4]; y = oy + a[5];
          break;
        case 'S':
          for (int i = 0; i < 4; i++) if (!mtl_svg_number (&p, &a[i])) goto fail;
          {
            bool smooth = previous == 'C' || previous == 'S';
            double c1x = smooth ? 2 * x - control_x : x, c1y = smooth ? 2 * y - control_y : y;
            CGPathAddCurveToPoint (path, NULL, c1x, c1y, ox + a[0], oy + a[1],
                                   ox + a[2], oy + a[3]);
          }
          control_x = ox + a[0]; control_y = oy + a[1];
          x = ox + a[2]; y = oy + a[3];
          break;
        case 'Q':
          for (int i = 0; i < 4; i++) if (!mtl_svg_number (&p, &a[i])) goto fail;
          CGPathAddQuadCurveToPoint (path, NULL, ox + a[0], oy + a[1], ox + a[2], oy + a[3]);
          control_x = ox + a[0]; control_y = oy + a[1];
          x = ox + a[2]; y = oy + a[3];
          break;
        case 'T':
          if (!mtl_svg_number (&p, &a[0]) || !mtl_svg_number (&p, &a[1])) goto fail;
          {
            bool smooth = previous == 'Q' || previous == 'T';
            control_x = smooth ? 2 * x - control_x : x;
            control_y = smooth ? 2 * y - control_y : y;
          }
          CGPathAddQuadCurveToPoint (path, NULL, control_x, control_y, ox + a[0], oy + a[1]);
          x = ox + a[0]; y = oy + a[1];
          break;
        case 'A':
          {
            int large, sweep;
            if (!mtl_svg_number (&p, &a[0]) || !mtl_svg_number (&p, &a[1])
                || !mtl_svg_number (&p, &a[2]) || !mtl_svg_flag (&p, &large)
                || !mtl_svg_flag (&p, &sweep) || !mtl_svg_number (&p, &a[3])
                || !mtl_svg_number (&p, &a[4]))
              goto fail;
            mtl_svg_arc (path, x, y, a[0], a[1], a[2], large, sweep, ox + a[3], oy + a[4]);
            x = ox + a[3]; y = oy + a[4];
          }
          break;
        case 'Z':
          CGPathCloseSubpath (path);
          x = start_x; y = start_y;
          /* Z takes no numbers; a number next is an error, a command is fine.  */
          command = 0;
          break;
        default:
          goto fail;
        }
      previous = upper;
    }
  if (CGPathIsEmpty (path)) goto fail;
  return path;
 fail:
  CGPathRelease (path);
  return NULL;
}

/* Decoration paths are in frame coordinates.  A path shape's SVG data maps
   its :view-box onto its :rect, or sits at the rect's origin without one.  */
static CGAffineTransform
mtl_decoration_path_transform (MtlDecoration v, NSDictionary *extras)
{
  CGRect r = CGRectStandardize (NSRectToCGRect (v.rect));
  CGAffineTransform t = CGAffineTransformMakeTranslation (r.origin.x, r.origin.y);
  NSValue *box = extras[@"viewBox"];
  if (box)
    {
      NSRect b = box.rectValue;
      t = CGAffineTransformScale (t, r.size.width / b.size.width, r.size.height / b.size.height);
      t = CGAffineTransformTranslate (t, -b.origin.x, -b.origin.y);
    }
  return t;
}

/* Build the outline of decoration V, in frame coordinates.  */
static CGPathRef
mtl_decoration_path (MtlDecoration v, NSDictionary *extras)
{
  if (v.shape == MTL_DECORATION_PATH && extras[@"path"])
    {
      CGAffineTransform t = mtl_decoration_path_transform (v, extras);
      return CGPathCreateCopyByTransformingPath ((CGPathRef) extras[@"path"], &t);
    }
  CGMutablePathRef path = CGPathCreateMutable ();
  CGRect r = CGRectStandardize (NSRectToCGRect (v.rect));
  switch (v.shape)
    {
    case MTL_DECORATION_LINE:
      /* A line's rect is (X1 Y1 DX DY).  */
      CGPathMoveToPoint (path, NULL, v.rect.origin.x, v.rect.origin.y);
      CGPathAddLineToPoint (path, NULL, v.rect.origin.x + v.rect.size.width,
                            v.rect.origin.y + v.rect.size.height);
      break;
    case MTL_DECORATION_CIRCLE:
      CGPathAddEllipseInRect (path, NULL, r);
      break;
    case MTL_DECORATION_ARC:
      /* Zero is at the right and positive angles turn clockwise on screen,
         which frame coordinates (y down) give for increasing angles.  */
      CGPathAddArc (path, NULL, CGRectGetMidX (r), CGRectGetMidY (r),
                    r.size.width / 2, v.startAngle, v.startAngle + v.sweepAngle,
                    v.sweepAngle < 0);
      break;
    default:
      {
        CGFloat radius = MIN (v.radius, MIN (r.size.width, r.size.height) / 2);
        CGPathAddRoundedRect (path, NULL, r, MAX (radius, 0), MAX (radius, 0));
      }
    }
  return path;
}

static CGColorRef
mtl_decoration_color (unsigned long rgb)
{
  return CGColorCreateSRGB (((rgb >> 16) & 0xff) / 255.0, ((rgb >> 8) & 0xff) / 255.0,
                            (rgb & 0xff) / 255.0, 1.0);
}

static CAMediaTimingFunction *
mtl_decoration_timing (NSString *name)
{
  return [CAMediaTimingFunction functionWithName:
            ([name isEqualToString:@"ease-in"] ? kCAMediaTimingFunctionEaseIn
             : [name isEqualToString:@"ease-out"] ? kCAMediaTimingFunctionEaseOut
             : [name isEqualToString:@"ease-in-out"] ? kCAMediaTimingFunctionEaseInEaseOut
             : kCAMediaTimingFunctionLinear)];
}

/* Replay TRACK as a Core Animation animation of KEY on LAYER.  FROM and TO
   are the animated values; the track's start keeps a retargeted or restored
   animation in phase.  */
static void
mtl_decoration_animate_layer (CALayer *layer, NSString *key, MtlDecorationTrack *track,
                              id from, id to)
{
  if (!track->active)
    {
      [layer removeAnimationForKey:key];
      return;
    }
  CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:key];
  animation.fromValue = from;
  animation.toValue = to;
  animation.duration = track->duration;
  animation.beginTime = [layer convertTime:track->start fromLayer:nil];
  animation.timingFunction = mtl_decoration_timing (track->easing == 1 ? @"ease-out"
                                                    : track->easing == 2 ? @"ease-in-out"
                                                    : @"linear");
  if (track->repeat)
    animation.repeatCount = HUGE_VALF;
  else
    {
      animation.fillMode = kCAFillModeBoth;
      animation.removedOnCompletion = NO;
    }
  [layer addAnimation:animation forKey:key];
}

/* Add keyframe SPEC to LAYER unless it already runs.  Path values map from
   SVG space through TRANSFORM.  The spec's start time keeps a layer rebuilt
   later in phase.  */
static void
mtl_decoration_keyframes_apply (CALayer *layer, NSDictionary *spec, CGAffineTransform transform)
{
  NSString *key = spec[@"keyPath"];
  NSString *marker = [@"mtlSpec." stringByAppendingString:key];
  if ([layer animationForKey:key] && [layer valueForKey:marker] == spec)
    return;
  NSArray *values = spec[@"values"];
  if ([key isEqualToString:@"path"])
    {
      NSMutableArray *paths = [NSMutableArray arrayWithCapacity:values.count];
      for (id value in values)
        {
          CGPathRef path = CGPathCreateCopyByTransformingPath ((CGPathRef) value, &transform);
          [paths addObject:(id) path];
          CGPathRelease (path);
        }
      values = paths;
    }
  NSArray *easings = spec[@"easings"];
  CAPropertyAnimation *animation;
  if ([spec[@"spring"] boolValue] && values.count == 2)
    {
      CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:key];
      spring.fromValue = values[0];
      spring.toValue = values[1];
      spring.damping = 12;
      spring.stiffness = 180;
      spring.duration = spring.settlingDuration;
      animation = spring;
    }
  else
    {
      CAKeyframeAnimation *frames = [CAKeyframeAnimation animationWithKeyPath:key];
      frames.values = values;
      if (spec[@"times"]) frames.keyTimes = spec[@"times"];
      if (easings.count == 1)
        frames.timingFunction = mtl_decoration_timing (easings[0]);
      else if (easings.count > 1)
        {
          NSMutableArray *functions = [NSMutableArray array];
          for (NSString *name in easings)
            [functions addObject:mtl_decoration_timing (name)];
          frames.timingFunctions = functions;
        }
      frames.duration = [spec[@"duration"] doubleValue];
      animation = frames;
    }
  double repeat = [spec[@"repeat"] doubleValue];
  animation.repeatCount = repeat < 0 ? HUGE_VALF : repeat;
  animation.autoreverses = [spec[@"autoreverse"] boolValue];
  animation.beginTime = [layer convertTime:[spec[@"start"] doubleValue]
                                             + [spec[@"delay"] doubleValue]
                                 fromLayer:nil];
  animation.fillMode = kCAFillModeBoth;
  animation.removedOnCompletion = NO;
  [layer addAnimation:animation forKey:key];
  [layer setValue:spec forKey:marker];
}

/* Apply EXTRAS' static transform and IDENTIFIER's keyframes to LAYER, whose
   anchor is already the decoration's center.  */
- (void)applyMotion:(CALayer *)layer identifier:(unsigned long long)identifier
          transform:(CGAffineTransform)path_transform
{
  NSDictionary *extras = [self.decorationExtras objectForKey:@(identifier)];
  CATransform3D t = CATransform3DIdentity;
  NSValue *translate = extras[@"translate"];
  if (translate)
    t = CATransform3DTranslate (t, translate.pointValue.x, translate.pointValue.y, 0);
  if (extras[@"rotation"])
    t = CATransform3DRotate (t, [extras[@"rotation"] doubleValue], 0, 0, 1);
  if (extras[@"scale"])
    t = CATransform3DScale (t, [extras[@"scale"] doubleValue], [extras[@"scale"] doubleValue], 1);
  layer.transform = t;
  NSDictionary *keyframes = [self.decorationKeyframes objectForKey:@(identifier)];
  for (NSString *key in keyframes)
    mtl_decoration_keyframes_apply (layer, keyframes[key], path_transform);
}

/* Return the content layer of decoration KEY's clip, recreating both when
   the content must be of class CLASS.  */
- (CALayer *)decorationContent:(NSNumber *)key class:(Class)class
{
  CALayer *clip = [self.decorationLayers objectForKey:key];
  CALayer *content = clip.sublayers.firstObject;
  if (clip && [content class] == class)
    return content;
  [clip removeFromSuperlayer];
  clip = [CALayer layer];
  clip.masksToBounds = YES;
  content = [class layer];
  [clip addSublayer:content];
  [self.decorationLayer addSublayer:clip];
  if (!self.decorationLayers)
    self.decorationLayers = [NSMutableDictionary dictionary];
  [self.decorationLayers setObject:clip forKey:key];
  return content;
}

/* Show text decoration IDENTIFIER as a highlight band that sweeps through its
   label.  HOLDER covers the label and is masked by a text layer that draws
   the label in the same font, so only the letters show the band sliding
   inside it, over the text Emacs already drew.  */
- (void)syncTextLayer:(CALayer *)holder record:(MtlDecorationRecord *)record
           identifier:(unsigned long long)identifier
{
  NSDictionary *text = [self.decorationTexts objectForKey:@(identifier)];
  MtlDecoration v = record->value;
  CALayer *clip = holder.superlayer;
  if (![holder.mask isKindOfClass:[CATextLayer class]])
    {
      holder.masksToBounds = YES;
      holder.mask = [CATextLayer layer];
      CAGradientLayer *band = [CAGradientLayer layer];
      band.startPoint = CGPointMake (0, 0.5);
      band.endPoint = CGPointMake (1, 0.5);
      [holder addSublayer:band];
    }
  CAGradientLayer *band = (CAGradientLayer *) holder.sublayers.firstObject;
  CGFloat scale = self.metalLayer.contentsScale;
  clip.contentsScale = scale;
  holder.contentsScale = scale;
  band.contentsScale = scale;
  clip.zPosition = (CGFloat) v.z;
  clip.frame = NSRectToCGRect (v.clip);
  holder.frame = CGRectMake (v.rect.origin.x - v.clip.origin.x,
                             v.rect.origin.y - v.clip.origin.y,
                             v.rect.size.width, v.rect.size.height);
  holder.opacity = v.opacity;

  NSString *string = text[@"text"] ?: @"";
  CGFloat size = [text[@"size"] doubleValue];
  double advance = [text[@"advance"] doubleValue];
  CTFontRef font = CTFontCreateWithName ((__bridge CFStringRef) (text[@"font"] ?: @"Menlo"),
                                         size, NULL);
  /* Emacs puts each character on its cell grid.  Kern the font's natural
     advance to the cell width, or the mask drifts from the letters.  */
  UniChar m_char = 'M';
  CGGlyph m_glyph;
  CGSize natural = CGSizeZero;
  if (CTFontGetGlyphsForCharacters (font, &m_char, &m_glyph, 1))
    CTFontGetAdvancesForGlyphs (font, kCTFontOrientationHorizontal, &m_glyph, &natural, 1);
  NSDictionary *attributes = @{
    (__bridge NSString *) kCTFontAttributeName: (__bridge id) font,
    (__bridge NSString *) kCTKernAttributeName: @(advance > 0 ? advance - natural.width : 0),
    (__bridge NSString *) kCTForegroundColorAttributeName:
      (__bridge id) CGColorGetConstantColor (kCGColorBlack) };
  CATextLayer *mask = (CATextLayer *) holder.mask;
  mask.frame = holder.bounds;
  mask.contentsScale = scale;
  mask.string = [[[NSAttributedString alloc] initWithString:string
                                                 attributes:attributes] autorelease];
  CFRelease (font);

  /* The band spans about ten cells and enters and leaves the label fully,
     like Mentat's own shimmer.  */
  CGFloat width = 10 * (advance > 0 ? advance : natural.width);
  CGColorRef highlight = mtl_decoration_color (v.fill);
  CGColorRef clear = CGColorCreateCopyWithAlpha (highlight, 0);
  band.colors = @[(__bridge id) clear, (__bridge id) highlight, (__bridge id) clear];
  CGColorRelease (highlight);
  CGColorRelease (clear);
  band.bounds = CGRectMake (0, 0, width, v.rect.size.height);
  band.position = CGPointMake (-width / 2, v.rect.size.height / 2);
  double period = [text[@"period"] doubleValue];
  CABasicAnimation *sweep = (CABasicAnimation *) [band animationForKey:@"sweep"];
  if (period > 0
      && (!sweep || fabs (sweep.duration - period) > 0.001
          || fabs ([sweep.toValue doubleValue] - (v.rect.size.width + width / 2)) > 0.5))
    {
      sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
      sweep.fromValue = @(-width / 2);
      sweep.toValue = @(v.rect.size.width + width / 2);
      sweep.duration = period;
      sweep.repeatCount = HUGE_VALF;
      [band addAnimation:sweep forKey:@"sweep"];
    }
  else if (period <= 0)
    [band removeAnimationForKey:@"sweep"];
}

- (BOOL)setDecorationText:(NSDictionary *)text identifier:(unsigned long long)identifier
{
  if (!self.decorationLayer || ![self.decorationRecords objectForKey:@(identifier)])
    return NO;
  if (!self.decorationTexts) self.decorationTexts = [NSMutableDictionary dictionary];
  [self.decorationTexts setObject:text forKey:@(identifier)];
  [self syncDecorationLayer:identifier];
  return YES;
}

- (BOOL)setDecorationExtras:(NSDictionary *)extras identifier:(unsigned long long)identifier
{
  if (!self.decorationExtras) self.decorationExtras = [NSMutableDictionary dictionary];
  if (extras.count)
    [self.decorationExtras setObject:extras forKey:@(identifier)];
  else
    [self.decorationExtras removeObjectForKey:@(identifier)];
  return YES;
}

- (BOOL)setDecorationKeyframes:(NSDictionary *)spec identifier:(unsigned long long)identifier
{
  if (!self.decorationLayer || ![self.decorationRecords objectForKey:@(identifier)])
    return NO;
  if (!self.decorationKeyframes) self.decorationKeyframes = [NSMutableDictionary dictionary];
  NSMutableDictionary *keyframes = [self.decorationKeyframes objectForKey:@(identifier)];
  if (!keyframes)
    {
      keyframes = [NSMutableDictionary dictionary];
      [self.decorationKeyframes setObject:keyframes forKey:@(identifier)];
    }
  NSMutableDictionary *started = [[spec mutableCopy] autorelease];
  started[@"start"] = @(CACurrentMediaTime ());
  [keyframes setObject:started forKey:spec[@"keyPath"]];
  [self syncDecorationLayer:identifier];
  return YES;
}

/* Show decoration IDENTIFIER's current record as a clipped layer, or remove
   its layer when the record is gone.  */
- (void)syncDecorationLayer:(unsigned long long)identifier
{
  if (!self.decorationLayer) return;
  NSNumber *key = @(identifier);
  NSValue *stored = [self.decorationRecords objectForKey:key];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (!stored)
    {
      [[self.decorationLayers objectForKey:key] removeFromSuperlayer];
      [self.decorationLayers removeObjectForKey:key];
      [CATransaction commit];
      return;
    }
  MtlDecorationRecord record;
  [stored getValue:&record];
  MtlDecoration v = record.value;
  NSDictionary *extras = [self.decorationExtras objectForKey:key];
  CGAffineTransform path_transform = mtl_decoration_path_transform (v, extras);
  CGFloat scale = self.metalLayer.contentsScale;
  CGRect r = CGRectStandardize (NSRectToCGRect (v.rect));

  if (v.shape == MTL_DECORATION_TEXT)
    {
      CALayer *holder = [self decorationContent:key class:[CALayer class]];
      [self syncTextLayer:holder record:&record identifier:identifier];
      [self applyMotion:holder identifier:identifier transform:path_transform];
      [CATransaction commit];
      return;
    }

  CALayer *content;
  if (v.shape == MTL_DECORATION_IMAGE)
    {
      content = [self decorationContent:key class:[CALayer class]];
      content.contents = extras[@"image"];
      content.contentsGravity = kCAGravityResize;
      content.frame = CGRectOffset (r, -v.clip.origin.x, -v.clip.origin.y);
    }
  else
    {
      CAShapeLayer *shape = (CAShapeLayer *) [self decorationContent:key
                                                               class:[CAShapeLayer class]];
      content = shape;
      /* The shape spans frame coordinates, anchored at the decoration's
         center so rotation and scale turn about it.  */
      CGSize size = CGSizeMake (MAX (1, self.decorationLayer.bounds.size.width + v.clip.origin.x),
                                MAX (1, self.decorationLayer.bounds.size.height + v.clip.origin.y));
      shape.bounds = CGRectMake (0, 0, size.width, size.height);
      shape.anchorPoint = CGPointMake (CGRectGetMidX (r) / size.width,
                                       CGRectGetMidY (r) / size.height);
      shape.position = CGPointMake (CGRectGetMidX (r) - v.clip.origin.x,
                                    CGRectGetMidY (r) - v.clip.origin.y);
      MtlDecoration resting = v;
      if (record.rotation.active)
        resting.startAngle = record.rotation.repeat ? record.rotation.from[0]
                                                    : record.rotation.to[0];
      CGPathRef path = mtl_decoration_path (resting, extras);
      shape.path = path;
      CGPathRelease (path);
      BOOL fills = v.hasFill && v.shape != MTL_DECORATION_ARC && v.shape != MTL_DECORATION_LINE;
      CGColorRef fill = fills ? mtl_decoration_color (v.fill) : NULL;
      CGColorRef stroke = v.hasStroke ? mtl_decoration_color (v.stroke) : NULL;
      shape.fillColor = fill;
      shape.strokeColor = stroke;
      if (fill) CGColorRelease (fill);
      if (stroke) CGColorRelease (stroke);
      shape.lineWidth = v.hasStroke ? v.strokeWidth : 0;
      NSString *cap = extras[@"lineCap"];
      shape.lineCap = [cap isEqualToString:@"round"] ? kCALineCapRound
        : [cap isEqualToString:@"square"] ? kCALineCapSquare
        : cap ? kCALineCapButt
        : (v.shape == MTL_DECORATION_LINE || v.shape == MTL_DECORATION_ARC)
        ? kCALineCapRound : kCALineCapButt;
      NSString *join = extras[@"lineJoin"];
      shape.lineJoin = [join isEqualToString:@"round"] ? kCALineJoinRound
        : [join isEqualToString:@"bevel"] ? kCALineJoinBevel : kCALineJoinMiter;
      shape.lineDashPattern = extras[@"dash"];
      shape.strokeStart = extras[@"strokeStart"] ? [extras[@"strokeStart"] doubleValue] : 0;
      shape.strokeEnd = extras[@"strokeEnd"] ? [extras[@"strokeEnd"] doubleValue] : 1;
      if (record.geometry.active)
        {
          MtlDecoration from = v, to = v;
          from.rect = NSMakeRect (record.geometry.from[0], record.geometry.from[1],
                                  record.geometry.from[2], record.geometry.from[3]);
          to.rect = NSMakeRect (record.geometry.to[0], record.geometry.to[1],
                                record.geometry.to[2], record.geometry.to[3]);
          CGPathRef from_path = mtl_decoration_path (from, extras);
          CGPathRef to_path = mtl_decoration_path (to, extras);
          if (!record.geometry.repeat)
            shape.path = to_path;
          mtl_decoration_animate_layer (shape, @"path", &record.geometry,
                                        (id) from_path, (id) to_path);
          CGPathRelease (from_path);
          CGPathRelease (to_path);
        }
      else
        [shape removeAnimationForKey:@"path"];
      /* An arc's start-angle track turns the whole shape about its center.  */
      if (record.rotation.active)
        {
          float from = record.rotation.from[0], to = record.rotation.to[0];
          MtlDecorationTrack track = record.rotation;
          mtl_decoration_animate_layer (shape, @"transform.rotation.z", &track,
                                        @(track.repeat ? 0 : from - to),
                                        @(track.repeat ? to - from : 0));
        }
    }
  CALayer *clip = content.superlayer;
  clip.contentsScale = scale;
  content.contentsScale = scale;
  clip.zPosition = (CGFloat) v.z;
  clip.frame = NSRectToCGRect (v.clip);
  content.opacity = record.opacity.active && !record.opacity.repeat
    ? record.opacity.to[0] : v.opacity;
  mtl_decoration_animate_layer (content, @"opacity", &record.opacity,
                                @(record.opacity.from[0]), @(record.opacity.to[0]));
  [self applyMotion:content identifier:identifier transform:path_transform];
  [CATransaction commit];
}

/* Encode the full composite (static blit + video + animation overlays)
   targeting DRAWABLE on CMD, and queue its present.  Shared by the
   standalone present (compositeToScreen) and the single-commit path in
   endFramePresent:.  */
- (void)drawBorderOverlaysOnEncoder:(id<MTLRenderCommandEncoder>)enc
                           texture:(id<MTLTexture>)texture
{
  if (!self.borderRecords.count || !g_border_pipeline || !self.metalLayer)
    return;
  NSSize screen = self.metalLayer.frame.size;
  if (screen.width <= 0 || screen.height <= 0)
    return;

  CGFloat scale_x = texture.width / screen.width;
  CGFloat scale_y = texture.height / screen.height;
  NSRect bounds = NSMakeRect (0, 0, screen.width, screen.height);
  /* Static outlines sit below their activity accents. */
  NSArray *keys = [[self.borderRecords allKeys]
    sortedArrayUsingComparator:^NSComparisonResult (NSNumber *a, NSNumber *b) {
      MtlBorderRecord left, right;
      [[self.borderRecords objectForKey:a] getValue:&left];
      [[self.borderRecords objectForKey:b] getValue:&right];
      if ((left.state == MTL_BORDER_IDLE) != (right.state == MTL_BORDER_IDLE))
        return left.state == MTL_BORDER_IDLE ? NSOrderedAscending : NSOrderedDescending;
      return [a compare:b];
    }];
  CFTimeInterval now = CACurrentMediaTime ();
  MTLScissorRect full = { 0, 0, texture.width,
                          texture.height };

  [enc setRenderPipelineState:g_border_pipeline];
  for (NSNumber *key in keys)
    {
      MtlBorderRecord record;
      [[self.borderRecords objectForKey:key] getValue:&record];
      NSRect clip = NSIntersectionRect (record.clip, bounds);
      if (NSIsEmptyRect (clip) || record.style.opacity == 0)
        continue;
      if (record.state == MTL_BORDER_COMPLETE
          && now - record.startTime >= MTL_BORDER_COMPLETE_DURATION)
        {
          if (!record.cleanupPresented)
            {
              record.cleanupPresented = YES;
              [self.borderRecords setObject:[NSValue valueWithBytes:&record
                                                           objCType:@encode(MtlBorderRecord)]
                                     forKey:key];
            }
          /* The static blit clears the last visible border.  Do not shade an
             invisible completed rectangle on subsequent redisplays. */
          continue;
        }

      NSUInteger x0 = (NSUInteger) floor (NSMinX (clip) * scale_x);
      NSUInteger y0 = (NSUInteger) floor (NSMinY (clip) * scale_y);
      NSUInteger x1 = (NSUInteger) ceil (NSMaxX (clip) * scale_x);
      NSUInteger y1 = (NSUInteger) ceil (NSMaxY (clip) * scale_y);
      x0 = MIN (x0, texture.width);
      y0 = MIN (y0, texture.height);
      x1 = MIN (x1, texture.width);
      y1 = MIN (y1, texture.height);
      if (x1 <= x0 || y1 <= y0)
        continue;
      MTLScissorRect scissor = { x0, y0, x1 - x0, y1 - y0 };
      [enc setScissorRect:scissor];

      float width = (float) record.rect.size.width - 2.0f;
      float height = (float) record.rect.size.height - 2.0f;
      if (width <= 0 || height <= 0)
        continue;
      float radius = MIN (record.style.cornerRadius, MIN (width, height) * 0.5f);
      float extent = MAX (record.style.strokeWidth * 0.5f + 1.0f,
                          record.state == MTL_BORDER_RUNNING ? 9.0f : 2.0f);
      float left = (float) NSMinX (record.rect) + 1.0f;
      float top = (float) NSMinY (record.rect) + 1.0f;
      float right = left + width;
      float bottom = top + height;
      MtlBorderVertex vertices[6] = {
        {left - extent, top - extent, -extent, -extent},
        {right + extent, top - extent, width + extent, -extent},
        {left - extent, bottom + extent, -extent, height + extent},
        {right + extent, top - extent, width + extent, -extent},
        {right + extent, bottom + extent, width + extent, height + extent},
        {left - extent, bottom + extent, -extent, height + extent},
      };

      MtlBorderUniforms params = { 0 };
      params.width = width;
      params.height = height;
      params.radius = radius;
      params.stroke = record.style.strokeWidth;
      params.elapsed = (float) (now - record.startTime);
      params.opacity = record.style.opacity;
      params.cycleDuration = record.style.cycleDuration;
      params.runnerFraction = record.style.runnerFraction;
      params.glowOpacity = record.style.glowOpacity;
      params.state = (float) record.state;
      float red, green, blue;
      unpack_color (record.color, &red, &green, &blue);
      params.color[0] = red;
      params.color[1] = green;
      params.color[2] = blue;
      params.color[3] = 1.0f;
      if (record.state == MTL_BORDER_COMPLETE)
        {
          float progress = (params.elapsed / MTL_BORDER_COMPLETE_DURATION - 0.18f)
            / 0.82f;
          progress = MAX (0.0f, MIN (progress, 1.0f));
          params.opacity *= (1.0f - progress) * (1.0f - progress);
        }

      [enc setVertexBytes:vertices length:sizeof (vertices) atIndex:0];
      [enc setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
      [enc setFragmentBytes:&params length:sizeof (params) atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

    }
  [enc setScissorRect:full];
}

- (void)encodeCompositeOn:(id<MTLCommandBuffer>)cmd
                 drawable:(id<CAMetalDrawable>)drawable
{
  MTL_SEQ ("PRESENT layer=%.0fx%.0f drawable=%lux%lu static=%lux%lu",
           self.metalLayer.frame.size.width, self.metalLayer.frame.size.height,
           (unsigned long) drawable.texture.width,
           (unsigned long) drawable.texture.height,
           (unsigned long) self.staticTexture.width,
           (unsigned long) self.staticTexture.height);

  self.needsPresent = NO;   /* about to present whatever is in the static texture */
  self.lastPresentTime = CACurrentMediaTime ();

  [self encodeCompositeTextureOn:cmd texture:drawable.texture];
}

- (void)encodeCompositeTextureOn:(id<MTLCommandBuffer>)cmd
                          texture:(id<MTLTexture>)texture
{
  NSSize sz = self.metalLayer.frame.size;
  MtlAnimator *anim = self.animator;

  /* Update uniforms for compositor pass */
  MtlUniforms *u = (MtlUniforms *)[self.uniformBuffer contents];
  u->screen_width  = (float)sz.width;
  u->screen_height = (float)sz.height;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture    = texture;
  rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
  [enc setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [enc setFragmentBuffer:self.uniformBuffer offset:0 atIndex:1];

  /* 1. Blit static Emacs content */
  {
    typedef struct { float x, y, u, v; } BlitVert;
    BlitVert verts[6] = {
      {-1,-1,0,1},{1,-1,1,1},{-1,1,0,0},
      {1,-1,1,1},{1,1,1,0},{-1,1,0,0},
    };
    /* Use nearest sampler for pixel-perfect blit (no blur on text) */
    [enc setRenderPipelineState:g_blit_pipeline];
    [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [enc setFragmentTexture:self.staticTexture atIndex:0];
    [enc setFragmentSamplerState:g_nearest_sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }

  /* Inline video overlay.  Drawn over the static texture so the
     redisplay engine can keep treating the placeholder area as ordinary
     buffer background. */
  MtlVideoPlayer *vp = self.videoPlayer;
  if (vp)
    {
      id<MTLTexture> vtex = [vp textureForNow];
      if (vtex && g_image_pipeline)
        {
          /* Clip to the window interior so a half-scrolled video does not
             bleed over the mode line or a neighboring window. */
          NSRect cr = vp.clipRect;
          BOOL clipped = !NSIsEmptyRect (cr);
          if (clipped)
            {
              CGSize dsz = self.metalLayer.drawableSize;
              double scx = sz.width  > 0 ? dsz.width  / sz.width  : 1.0;
              double scy = sz.height > 0 ? dsz.height / sz.height : 1.0;
              long tw = (long) texture.width;
              long th = (long) texture.height;
              long cx0 = lround (NSMinX (cr) * scx);
              long cy0 = lround (NSMinY (cr) * scy);
              long cx1 = lround (NSMaxX (cr) * scx);
              long cy1 = lround (NSMaxY (cr) * scy);
              cx0 = MAX (0, MIN (cx0, tw)); cy0 = MAX (0, MIN (cy0, th));
              cx1 = MAX (cx0, MIN (cx1, tw)); cy1 = MAX (cy0, MIN (cy1, th));
              MTLScissorRect sc = { (NSUInteger) cx0, (NSUInteger) cy0,
                                    (NSUInteger) (cx1 - cx0),
                                    (NSUInteger) (cy1 - cy0) };
              if (sc.width == 0 || sc.height == 0)
                sc = (MTLScissorRect) {0, 0, 1, 1};
              [enc setScissorRect:sc];
            }

          typedef struct { float x, y, u, v, a; } ImgVert;
          NSRect vr = vp.rect;
          float x0 = NSMinX (vr), y0 = NSMinY (vr);
          float x1 = NSMaxX (vr), y1 = NSMaxY (vr);
          ImgVert verts[6] = {
            {x0,y0, 0,0,1}, {x1,y0, 1,0,1}, {x0,y1, 0,1,1},
            {x1,y0, 1,0,1}, {x1,y1, 1,1,1}, {x0,y1, 0,1,1},
          };
          [enc setRenderPipelineState:g_image_pipeline];
          [enc setVertexBytes:verts length:sizeof (verts) atIndex:0];
          [enc setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
          [enc setFragmentTexture:vtex atIndex:0];
          [enc setFragmentSamplerState:g_sampler atIndex:0];
          [enc drawPrimitives:MTLPrimitiveTypeTriangle
                  vertexStart:0 vertexCount:6];

          if (clipped)
            {
              MTLScissorRect full = { 0, 0, texture.width,
                                      texture.height };
              [enc setScissorRect:full];
            }
        }
    }

  /* Buffer-switch crossfade: the old content fades out over the new.  */
  if (self.transitionTexture && self.transitionDuration > 0)
    {
      float p = (float) ((CACurrentMediaTime () - self.transitionStart)
                         / self.transitionDuration);
      if (p >= 1.0f)
        self.transitionTexture = nil;   /* done */
      else
        {
          float a = 1.0f - p;
          a = a * a * (3.0f - 2.0f * a);   /* smoothstep del fade-out */
          typedef struct { float x, y, u, v, al; } ImgVert;
          float x1 = (float) sz.width, y1 = (float) sz.height;
          ImgVert verts[6] = {
            {0,0, 0,0,a}, {x1,0, 1,0,a}, {0,y1, 0,1,a},
            {x1,0, 1,0,a}, {x1,y1, 1,1,a}, {0,y1, 0,1,a},
          };
          [enc setRenderPipelineState:g_image_pipeline];
          [enc setVertexBytes:verts length:sizeof (verts) atIndex:0];
          [enc setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
          [enc setFragmentTexture:self.transitionTexture atIndex:0];
          [enc setFragmentSamplerState:g_nearest_sampler atIndex:0];
          [enc drawPrimitives:MTLPrimitiveTypeTriangle
                  vertexStart:0 vertexCount:6];
        }
    }

  /* Draw tool-card borders over the text and crossfade, but behind the cursor. */
  [self drawBorderOverlaysOnEncoder:enc texture:texture];
  [self drawDecorationsOnEncoder:enc texture:texture];

  /* Animation overlay (cursor effects, trail, particles) is opt-in.  When off,
     the cursor lives in the static texture (drawn by mtl_draw_window_cursor),
     so the compositor only blits and presents.  This is what kills the stray
     cyan cursor box drawn on top of text. */
  if (anim && g_mtl_animations_enabled)
    {
      float cx = anim.cursorMode == MTL_CURSOR_SPRING ? anim.springX.pos : anim.curTargetX;
      float cy = anim.cursorMode == MTL_CURSOR_SPRING ? anim.springY.pos : anim.curTargetY;
      float cw = anim.curTargetW, ch = anim.curTargetH;

      /* Real frame cursor color (fed by note_cursor); before the first
         cursor draw, fall back to the frame's cursor color, not cyan. */
      float ccr, ccg, ccb;
      unsigned long cc = anim.cursorColor;
      if (!cc && self.emacsFrame)
        cc = ns_color_to_pixel (FRAME_CURSOR_COLOR (self.emacsFrame));
      unpack_color (cc ? cc : 0x88C0D0, &ccr, &ccg, &ccb);

      /* 2. Torpedo trail (hidden together with the cursor body) */
      if (anim.cursorMode == MTL_CURSOR_TORPEDO && anim.trailCount > 0
          && !anim.cursorHidden)
        {
          NSUInteger tlen = MIN(anim.trailCount, g_mtl_trail_len);
          for (NSUInteger i = 0; i < tlen; i++)
            {
              NSUInteger slot = (anim.trailHead + i) % MTL_TRAIL_LEN;
              /* Two combined falloffs so the head stays a sharp instant cursor
                 and the rest reads as a temporary comet tail:
                 - spatial: samples nearer the cursor (higher i) are brighter,
                   so even while moving the tail tapers instead of forming a
                   uniform bright bar that looks like the cursor sliding;
                 - temporal: every sample fades with age, so the whole tail
                   dissipates on its own shortly after the cursor stops. */
              float pos  = (float)(i + 1) / (float)tlen;        /* 0=tail .. 1=head */
              float frac = anim->trailAge[slot] / MTL_TRAIL_LIFETIME;
              if (frac > 1.0f) frac = 1.0f;
              float life  = 1.0f - frac;
              float alpha = pos * life * life * 0.5f;  /* spatial x temporal */
              float scale = 0.35f + 0.55f * pos;       /* narrow toward the tail */
              float tx = anim->trailX[slot], ty = anim->trailY[slot];
              float iw = cw * scale, ih = ch * scale;
              float ox = tx + (cw - iw) * 0.5f, oy = ty + (ch - ih) * 0.5f;
              float x0=ox, y0=oy, x1=ox+iw, y1=oy+ih;
              typedef struct { float x,y,r,g,b,a; } RV;
              float r2=ccr,g2=ccg,b2=ccb;
              RV v[6] = {
                {x0,y0,r2,g2,b2,alpha},{x1,y0,r2,g2,b2,alpha},{x0,y1,r2,g2,b2,alpha},
                {x1,y0,r2,g2,b2,alpha},{x1,y1,r2,g2,b2,alpha},{x0,y1,r2,g2,b2,alpha},
              };
              [enc setRenderPipelineState:g_particle_pipeline];
              [enc setVertexBytes:v length:sizeof(v) atIndex:0];
              [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }

      /* 3. Cursor (spring-interpolated position).  Hidden during the
         blink-off phase; effects in flight keep animating.  Only the
         body-animated modes draw it here: the burst modes rely on the
         static (inverted glyph) cursor in the texture.  */
      if (!anim.cursorHidden
          && (anim.cursorMode == MTL_CURSOR_SPRING
              || anim.cursorMode == MTL_CURSOR_TORPEDO
              || anim.cursorMode == MTL_CURSOR_HOLLOW
              || anim.cursorMode == MTL_CURSOR_BEAM))
      {
        float x0=cx, y0=cy, x1=cx+cw, y1=cy+ch;
        float fr=ccr,fg=ccg,fb=ccb;
        typedef struct { float x,y,r,g,b,a; } RV;
        RV v[6] = {
          {x0,y0,fr,fg,fb,1},{x1,y0,fr,fg,fb,1},{x0,y1,fr,fg,fb,1},
          {x1,y0,fr,fg,fb,1},{x1,y1,fr,fg,fb,1},{x0,y1,fr,fg,fb,1},
        };
        [enc setRenderPipelineState:g_particle_pipeline];
        [enc setVertexBytes:v length:sizeof(v) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
      }

      /* 4. Particles (pixiedust / sonicboom / ripple) */
      if (anim.nParticles > 0)
        {
          typedef struct { float x, y, r, g, b, a; } PV;
          for (NSUInteger i = 0; i < anim.nParticles; i++)
            {
              MtlParticle *p = &anim->particles[i];
              float a = (1.0f - p->age) * (1.0f - p->age);
              float s = p->size * (1.0f - p->age * 0.5f);
              float pr, pg, pb;
              unpack_color (p->color, &pr, &pg, &pb);
              PV v[6];
              float x0=p->x-s/2, y0=p->y-s/2, x1=x0+s, y1=y0+s;
              PV vv = {0, 0, pr, pg, pb, a};
              v[0]=(PV){x0,y0,pr,pg,pb,a}; v[1]=(PV){x1,y0,pr,pg,pb,a};
              v[2]=(PV){x0,y1,pr,pg,pb,a}; v[3]=(PV){x1,y0,pr,pg,pb,a};
              v[4]=(PV){x1,y1,pr,pg,pb,a}; v[5]=(PV){x0,y1,pr,pg,pb,a};
              (void)vv;
              [enc setRenderPipelineState:g_particle_pipeline];
              [enc setVertexBytes:v length:sizeof(v) atIndex:0];
              [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }
    }

  [enc endEncoding];

}

@end

/* -----------------------------------------------------------------------
   @implementation MtlView (standalone test window only)
   ----------------------------------------------------------------------- */

@implementation MtlView

- (instancetype)initWithFrame:(NSRect)frame emacsFrame:(struct frame *)f
{
  self = [super initWithFrame:frame];
  if (!self) return nil;
  emacsframe = f;
  self.wantsLayer = YES;
  [self setupMetal];
  return self;
}

- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)isFlipped             { return YES; }

- (void)setupMetal
{
  if (!mtl_global_setup ()) return;

  self.metalLayer = (CAMetalLayer *)self.layer;
  if (![self.metalLayer isKindOfClass:[CAMetalLayer class]])
    {
      self.metalLayer = [CAMetalLayer layer];
      self.layer = self.metalLayer;
    }
  self.metalLayer.device        = g_device;
  self.metalLayer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
  self.metalLayer.framebufferOnly = YES;

  CGFloat scale = [[NSScreen mainScreen] backingScaleFactor];
  self.metalLayer.contentsScale = scale;

  self.uniformBuffer = [g_device newBufferWithLength:sizeof (MtlUniforms)
                                             options:MTLResourceStorageModeShared];
}

- (void)beginFrame
{
  self.frameDrawable = [self.metalLayer nextDrawable];
  if (!self.frameDrawable) return;

  NSSize sz = [self bounds].size;
  MtlUniforms *u = (MtlUniforms *)[self.uniformBuffer contents];
  u->screen_width  = (float)sz.width;
  u->screen_height = (float)sz.height;

  unsigned long bg = emacsframe ? ns_color_to_pixel (FRAME_BACKGROUND_COLOR (emacsframe)) : 0x2E3440;
  float r, g, b;
  unpack_color (bg, &r, &g, &b);

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture    = self.frameDrawable.texture;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake (r, g, b, 1.0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  self.frameCommandBuffer = [g_queue commandBuffer];
  self.frameEncoder = [self.frameCommandBuffer renderCommandEncoderWithDescriptor:rpd];
  [self.frameEncoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [self.frameEncoder setFragmentBuffer:self.uniformBuffer offset:0 atIndex:1];
}

- (void)endFrameAndPresent
{
  if (!self.frameEncoder) return;
  [self.frameEncoder endEncoding];
  [self.frameCommandBuffer presentDrawable:self.frameDrawable];
  [self.frameCommandBuffer commit];
  self.frameEncoder = nil;
  self.frameCommandBuffer = nil;
  self.frameDrawable = nil;
}

- (void)fillRect:(NSRect)rect withColor:(unsigned long)color
{
  if (!self.frameEncoder || !g_rect_pipeline) return;

  float r, g, b;
  unpack_color (color, &r, &g, &b);
  float x0=(float)NSMinX(rect), y0=(float)NSMinY(rect);
  float x1=(float)NSMaxX(rect), y1=(float)NSMaxY(rect);
  MtlRectVertex v[6] = {
    {x0,y0,r,g,b,1},{x1,y0,r,g,b,1},{x0,y1,r,g,b,1},
    {x1,y0,r,g,b,1},{x1,y1,r,g,b,1},{x0,y1,r,g,b,1}
  };
  [self.frameEncoder setRenderPipelineState:g_rect_pipeline];
  [self.frameEncoder setVertexBytes:v length:sizeof(v) atIndex:0];
  [self.frameEncoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [self.frameEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

- (void)drawText:(NSString *)text
              at:(NSPoint)pt
        ctfont:(CTFontRef)font
           color:(unsigned long)color
{
  if (!font) return;

  float fr, fg, fb;
  unpack_color (color, &fr, &fg, &fb);

  float px = pt.x;
  for (NSUInteger i = 0; i < text.length; i++)
    {
      unichar uc = [text characterAtIndex:i];
      MtlGlyphCacheEntry *ge = mtl_cache_glyph (font, uc);
      if (!ge) { px += (float)CTFontGetSize (font); continue; }

      if (ge->width > 0)
        {
          float x0 = px - ge->bearing_x;
          float y0 = pt.y - ge->bearing_y;
          float x1 = x0 + ge->width, y1 = y0 + ge->height;
          float u0 = (float)ge->atlas_x / MTL_ATLAS_WIDTH;
          float v0 = (float)ge->atlas_y / MTL_ATLAS_HEIGHT;
          float u1 = (float)(ge->atlas_x + ge->width)  / MTL_ATLAS_WIDTH;
          float v1 = (float)(ge->atlas_y + ge->height) / MTL_ATLAS_HEIGHT;

          MtlGlyphVertex vx[6] = {
            {x0,y0,u0,v0,fr,fg,fb,1},{x1,y0,u1,v0,fr,fg,fb,1},
            {x0,y1,u0,v1,fr,fg,fb,1},{x1,y0,u1,v0,fr,fg,fb,1},
            {x1,y1,u1,v1,fr,fg,fb,1},{x0,y1,u0,v1,fr,fg,fb,1}
          };
          [self.frameEncoder setRenderPipelineState:g_glyph_pipeline];
          [self.frameEncoder setVertexBytes:vx length:sizeof(vx) atIndex:0];
          [self.frameEncoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
          [self.frameEncoder setFragmentTexture:g_atlas atIndex:0];
          [self.frameEncoder setFragmentSamplerState:g_sampler atIndex:0];
          [self.frameEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0 vertexCount:6];
        }
      px += ge->advance_x;
    }
}

- (void)setFrameSize:(NSSize)s
{
  [super setFrameSize:s];
  if (self.metalLayer)
    {
      CGFloat scale = self.window
        ? self.window.backingScaleFactor
        : [[NSScreen mainScreen] backingScaleFactor];
      self.metalLayer.contentsScale = scale;
      self.metalLayer.drawableSize  = CGSizeMake (s.width*scale, s.height*scale);
    }
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder  { return YES; }

/* -----------------------------------------------------------------------
   Phase 3: keyboard events for the standalone MtlView test window.
   For NS frames with Metal overlay, events are handled by ns_read_socket.
   ----------------------------------------------------------------------- */

static unsigned int
mtl_modifier_flags (NSUInteger mods)
{
  unsigned int emods = 0;
  if (mods & NSEventModifierFlagShift)   emods |= shift_modifier;
  if (mods & NSEventModifierFlagControl) emods |= ctrl_modifier;
  if (mods & NSEventModifierFlagOption)  emods |= meta_modifier;
  if (mods & NSEventModifierFlagCommand) emods |= super_modifier;
  return emods;
}

- (void)keyDown:(NSEvent *)event
{
  if (!emacsframe) return;

  NSString *chars = [event characters];
  NSString *nomod = [event charactersIgnoringModifiers];
  unsigned int mods = mtl_modifier_flags ([event modifierFlags]);

  if (!chars || !chars.length) return;

  unichar uc = [chars characterAtIndex:0];
  unichar nomoduc = nomod.length ? [nomod characterAtIndex:0] : uc;

  /* Build an Emacs input_event */
  struct input_event ev;
  EVENT_INIT (ev);
  ev.kind = ASCII_KEYSTROKE_EVENT;

  /* Handle control characters and special keys */
  if ((mods & ctrl_modifier) && nomoduc >= '@' && nomoduc <= '_')
    {
      ev.code = nomoduc - '@';
      ev.modifiers = mods & ~ctrl_modifier;
    }
  else if (uc < 0x80)
    {
      ev.code = uc;
      ev.modifiers = mods;
    }
  else
    {
      ev.kind = NON_ASCII_KEYSTROKE_EVENT;
      ev.code = uc;
      ev.modifiers = mods;
    }

  XSETFRAME (ev.frame_or_window, emacsframe);
  ev.timestamp = (unsigned long)([event timestamp] * 1000);

  kbd_buffer_store_event (&ev);
}

- (void)mouseDown:(NSEvent *)event
{
  if (!emacsframe) return;
  NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];

  struct input_event ev;
  EVENT_INIT (ev);
  ev.kind = MOUSE_CLICK_EVENT;
  ev.code = [event buttonNumber];
  ev.modifiers = mtl_modifier_flags ([event modifierFlags]) | down_modifier;
  XSETINT (ev.x, (int)pt.x);
  XSETINT (ev.y, (int)pt.y);
  XSETFRAME (ev.frame_or_window, emacsframe);
  ev.timestamp = (unsigned long)([event timestamp] * 1000);

  kbd_buffer_store_event (&ev);
}

- (void)mouseUp:(NSEvent *)event
{
  if (!emacsframe) return;
  NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];

  struct input_event ev;
  EVENT_INIT (ev);
  ev.kind = MOUSE_CLICK_EVENT;
  ev.code = [event buttonNumber];
  ev.modifiers = mtl_modifier_flags ([event modifierFlags]) | up_modifier;
  XSETINT (ev.x, (int)pt.x);
  XSETINT (ev.y, (int)pt.y);
  XSETFRAME (ev.frame_or_window, emacsframe);
  ev.timestamp = (unsigned long)([event timestamp] * 1000);

  kbd_buffer_store_event (&ev);
}

- (void)scrollWheel:(NSEvent *)event
{
  if (!emacsframe) return;
  NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];

  /* Convert scroll delta to Emacs wheel event */
  CGFloat dy = [event scrollingDeltaY];
  if (fabs (dy) < 0.5) return;

  struct input_event ev;
  EVENT_INIT (ev);
  ev.kind = WHEEL_EVENT;
  ev.code = dy > 0 ? 0 : 1; /* 0 = up, 1 = down */
  ev.modifiers = mtl_modifier_flags ([event modifierFlags]);
  XSETINT (ev.x, (int)pt.x);
  XSETINT (ev.y, (int)pt.y);
  XSETFRAME (ev.frame_or_window, emacsframe);
  ev.timestamp = (unsigned long)([event timestamp] * 1000);

  kbd_buffer_store_event (&ev);
}

/* Window delegate callbacks for the standalone test window */
- (void)windowDidBecomeKey:(NSNotification *)notif
{
  (void)notif;
  if (emacsframe) SET_FRAME_GARBAGED (emacsframe);
}

- (void)windowDidResignKey:(NSNotification *)notif
{
  (void)notif;
  if (emacsframe) SET_FRAME_GARBAGED (emacsframe);
}

- (void)windowDidResize:(NSNotification *)notif
{
  (void)notif;
  NSSize sz = [[notif object] contentView].bounds.size;
  [self setFrameSize:sz];
  if (emacsframe)
    {
      /* Notify Emacs that the frame pixel size changed */
      FRAME_PIXEL_WIDTH  (emacsframe) = (int)sz.width;
      FRAME_PIXEL_HEIGHT (emacsframe) = (int)sz.height;
      SET_FRAME_GARBAGED (emacsframe);
    }
}

@end

/* -----------------------------------------------------------------------
   @implementation MtlWindow
   ----------------------------------------------------------------------- */

@implementation MtlWindow
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

/* -----------------------------------------------------------------------
   Helper: get CTFont from Emacs font object
   macfont_get_nsctfont returns (CTFontRef) as void*
   ----------------------------------------------------------------------- */

static CTFontRef
mtl_ctfont_for_face (struct face *face)
{
  if (!face || !face->font) return NULL;
  void *ptr = macfont_get_nsctfont (face->font);
  return (CTFontRef)ptr;
}

/* Pre-rasterize the printable ASCII range for FRAME's default face into the
   glyph atlas.  Called from mtl-enable-for-frame so the first full redraw of
   new content (e.g. the first tab switch) does not pay the whole rasterization
   cost at once, which showed up as a visible blink. */
/* Driver op: pre-rasterize printable ASCII of F's default face (atlas
   warm-up; kills the rasterization burst on the first full redraw).  */
void
mtl_warm_glyph_cache (struct frame *f)
{
  struct face *face = FACE_FROM_ID_OR_NULL (f, DEFAULT_FACE_ID);
  CTFontRef ctfont = mtl_ctfont_for_face (face);
  if (!ctfont) return;
  for (uint32_t c = 32; c < 127; c++)
    mtl_cache_glyph (ctfont, c);
}

/* -----------------------------------------------------------------------
   Phase 5: inline image support — NSImage (EmacsImage) → MTLTexture
   ----------------------------------------------------------------------- */

static id<MTLTexture>
mtl_texture_for_image (struct image *img)
{
  if (!img || !g_device || !g_image_texture_cache) return nil;

  /* Get NSImage from Emacs image (NS backend stores EmacsImage* in pixmap) */
  if (!img->pixmap) return nil;
  NSImage *nsimg = (__bridge NSImage *)img->pixmap;
  if (![nsimg isKindOfClass:[NSImage class]]) return nil;

  NSSize sz = [nsimg size];
  if (sz.width < 1 || sz.height < 1) return nil;

  /* Target size: the engine's display size (img->width/height) accounts for
     :scale / :rotation transforms; fall back to the natural size. */
  NSUInteger w = img->width  > 0 ? (NSUInteger)img->width  : (NSUInteger)ceil (sz.width);
  NSUInteger h = img->height > 0 ? (NSUInteger)img->height : (NSUInteger)ceil (sz.height);

  /* Rasterize at the backing scale, as glyphs are: the frame's static
     texture is physical, and the quad is drawn at the logical size.  An
     SVG is already loaded at the backing scale and drawn down to the
     display size by its transform, so this keeps its resolution.  */
  CGFloat s = g_atlas_scale;
  NSUInteger pw = (NSUInteger) ceil (w * s);
  NSUInteger ph = (NSUInteger) ceil (h * s);

  /* Cache lookup: key is the struct image* pointer directly.
     CFDictionary with NULL key callbacks uses pointer equality — correct and
     fast.  Re-rasterize if the display size changed (reload / new transform). */
  id<MTLTexture> tex = (__bridge id<MTLTexture>)
    CFDictionaryGetValue (g_image_texture_cache, (const void *)img);
  EMACS_UINT cached_hash = (EMACS_UINT) (uintptr_t)
    CFDictionaryGetValue (g_image_hash_cache, (const void *)img);
  if (tex && cached_hash == img->hash
      && tex.width == pw && tex.height == ph)
    return tex;

  /* Render NSImage to a BGRA8 bitmap via CGContext */
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB ();
  size_t bpr    = pw * 4;
  uint8_t *px   = (uint8_t *)calloc (1, bpr * ph);
  CGContextRef ctx = CGBitmapContextCreate (px, pw, ph, 8, bpr, cs,
    (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
  CGColorSpaceRelease (cs);
  if (!ctx) { free (px); return nil; }

  /* Mirror ns_dumpglyphs_image: EmacsImage carries an NSAffineTransform
     (rotation/scale from image.c) meant for the flipped EmacsView coordinate
     system, plus a smoothing flag.  Reproduce that environment: flip the CTM
     and use a flipped NSGraphicsContext, concat the transform, then draw with
     respectFlipped:YES.  The two flips cancel for the memory layout, so row 0
     of the bitmap is still the visual top (what Metal's V=0 expects). */
  BOOL is_emacs_image = [nsimg isKindOfClass:[EmacsImage class]];
  NSAffineTransform *xform =
    is_emacs_image ? ((EmacsImage *)nsimg)->transform : nil;
  BOOL smoothing = is_emacs_image ? ((EmacsImage *)nsimg)->smoothing : YES;

  CGContextTranslateCTM (ctx, 0, (CGFloat)ph);
  CGContextScaleCTM (ctx, 1.0, -1.0);
  CGContextScaleCTM (ctx, s, s);
  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx
                                                                  flipped:YES];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:gc];
  if (xform)
    [xform concat];
  if (!smoothing)
    [gc setImageInterpolation:NSImageInterpolationNone];
  NSRect ir = NSMakeRect (0, 0, sz.width, sz.height);
  if (xform)
    [nsimg drawInRect:ir fromRect:ir
            operation:NSCompositingOperationSourceOver
             fraction:1.0 respectFlipped:YES hints:nil];
  else
    /* No transform: scale the natural image to the display size. */
    [nsimg drawInRect:NSMakeRect (0, 0, (CGFloat)w, (CGFloat)h) fromRect:ir
            operation:NSCompositingOperationSourceOver
             fraction:1.0 respectFlipped:YES hints:nil];
  [NSGraphicsContext restoreGraphicsState];
  CGContextRelease (ctx);

  /* Upload pixels to MTLTexture (BGRA8Unorm — byte order already correct) */
  MTLTextureDescriptor *td =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                       width:pw height:ph mipmapped:NO];
  td.usage       = MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  tex = [g_device newTextureWithDescriptor:td];
  [tex replaceRegion:MTLRegionMake2D (0, 0, pw, ph)
         mipmapLevel:0
           withBytes:px bytesPerRow:bpr];
  free (px);

  /* Store in cache: key = raw struct image* pointer, value = MTLTexture
     (CF-retained), plus the spec hash that validates the entry.  */
  CFDictionarySetValue (g_image_texture_cache, (const void *)img,
                        (__bridge CFTypeRef)tex);
  CFDictionarySetValue (g_image_hash_cache, (const void *)img,
                        (const void *) (uintptr_t) img->hash);
  return tex;
}

/* Invalidate cached texture for an image before Emacs reloads or frees it. */
static void
mtl_invalidate_image_texture (struct image *img)
{
  if (img && g_image_texture_cache)
    CFDictionaryRemoveValue (g_image_texture_cache, (const void *)img);
  if (img && g_image_hash_cache)
    CFDictionaryRemoveValue (g_image_hash_cache, (const void *)img);
}

/* Render the (U0,V0)-(U1,V1) subrect of a Metal RGBA texture as a quad at
   (x,y,w,h) into fd.encoder.  Used for image slices (insert-sliced-image). */
static void
mtl_draw_image_texture_uv (MtlFrameData *fd, id<MTLTexture> tex,
                           float x, float y, float w, float h,
                           float u0, float v0, float u1, float v1, float alpha)
{
  if (!fd.encoder || !g_image_pipeline || !tex) return;
  mtl_flush_batch ();          /* keep submission order vs queued quads */
  [fd applyScissorNow];        /* non-batched: needs the real scissor */

  typedef struct { float x, y, u, v, a; } ImgVert;
  float x1 = x+w, y1 = y+h;
  ImgVert verts[6] = {
    {x, y,  u0,v0,alpha}, {x1,y,  u1,v0,alpha}, {x, y1, u0,v1,alpha},
    {x1,y,  u1,v0,alpha}, {x1,y1, u1,v1,alpha}, {x, y1, u0,v1,alpha},
  };
  [fd.encoder setRenderPipelineState:g_image_pipeline];
  [fd.encoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
  [fd.encoder setVertexBuffer:fd.uniformBuffer offset:0 atIndex:1];
  [fd.encoder setFragmentTexture:tex atIndex:0];
  [fd.encoder setFragmentSamplerState:g_sampler atIndex:0];
  [fd.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

/* Render a full Metal RGBA texture as a quad at (x,y,w,h) into fd.encoder */
static void
mtl_draw_image_texture (MtlFrameData *fd, id<MTLTexture> tex,
                         float x, float y, float w, float h, float alpha)
{
  mtl_draw_image_texture_uv (fd, tex, x, y, w, h, 0, 0, 1, 1, alpha);
}

/* -----------------------------------------------------------------------
   Color glyphs (Apple Color Emoji).  The main atlas is R8 grayscale
   coverage, which renders emoji as dark silhouettes; color-font glyphs are
   rasterized into small BGRA textures instead and drawn with the image
   pipeline.  Cached per (font, glyph) like the grayscale atlas.
   ----------------------------------------------------------------------- */

@interface MtlColorGlyph : NSObject
@property (nonatomic, strong) id<MTLTexture> tex;
@property (nonatomic, assign) int w, h;          /* physical pixels */
@property (nonatomic, assign) int bearing_x, bearing_y;
@property (nonatomic, assign) float advance_x;   /* logical pixels */
@end
@implementation MtlColorGlyph
@end

static NSMutableDictionary<NSNumber *, MtlColorGlyph *> *g_color_glyph_cache;

/* Called when g_atlas_scale changes: color glyphs are baked at physical
   resolution too, so they must re-rasterize at the new scale. */
static void
mtl_color_glyph_cache_clear (void)
{
  [g_color_glyph_cache removeAllObjects];
}

static MtlColorGlyph *
mtl_color_glyph (CTFontRef font, CGGlyph g)
{
  if (!g_device || !font || g == 0) return nil;
  uint64_t key = ((uint64_t)(uintptr_t)font * 6364136223846793005ULL) ^ (uint64_t)g;
  if (!g_color_glyph_cache)
    g_color_glyph_cache = [NSMutableDictionary new];
  NSNumber *k = @(key);
  MtlColorGlyph *cg = g_color_glyph_cache[k];
  if (cg) return cg;

  /* Same conventions as mtl_rasterize_glyph_id: physical resolution via a
     scaled font copy, +2px padding, origin at floor(-bbox)+1, bearing_y =
     bh - raster_oy. */
  CGFloat s = g_atlas_scale;
  CTFontRef rfont = (s != 1.0)
    ? CTFontCreateCopyWithAttributes (font, CTFontGetSize (font) * s, NULL, NULL)
    : (CTFontRef) CFRetain (font);

  CGRect bbox = CTFontGetBoundingRectsForGlyphs (rfont,
                  kCTFontOrientationDefault, &g, NULL, 1);
  CGSize adv;
  CTFontGetAdvancesForGlyphs (rfont, kCTFontOrientationDefault, &g, &adv, 1);
  int bw = (int)ceil (bbox.size.width)  + 2;
  int bh = (int)ceil (bbox.size.height) + 2;
  if (bw <= 2 || bh <= 2) { CFRelease (rfont); return nil; }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB ();
  size_t bpr  = (size_t)bw * 4;
  uint8_t *px = (uint8_t *)calloc (1, bpr * (size_t)bh);
  CGContextRef ctx = CGBitmapContextCreate (px, (size_t)bw, (size_t)bh, 8, bpr, cs,
    (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
  CGColorSpaceRelease (cs);
  if (!ctx) { free (px); CFRelease (rfont); return nil; }

  CGPoint origin = CGPointMake (floor (-bbox.origin.x) + 1,
                                 floor (-bbox.origin.y) + 1);
  CTFontDrawGlyphs (rfont, &g, &origin, 1, ctx);   /* renders color for sbix fonts */
  CGContextRelease (ctx);
  CFRelease (rfont);

  MTLTextureDescriptor *td =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                       width:(NSUInteger)bw
                                                      height:(NSUInteger)bh
                                                   mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [g_device newTextureWithDescriptor:td];
  [tex replaceRegion:MTLRegionMake2D (0, 0, (NSUInteger)bw, (NSUInteger)bh)
         mipmapLevel:0 withBytes:px bytesPerRow:bpr];
  free (px);

  int raster_oy = (int)(floor (-bbox.origin.y) + 1);
  cg = [MtlColorGlyph new];
  cg.tex       = tex;
  cg.w         = bw;
  cg.h         = bh;
  cg.bearing_x = (int)(floor (-bbox.origin.x) + 1);
  cg.bearing_y = bh - raster_oy;
  cg.advance_x = (float)(adv.width / s);
  g_color_glyph_cache[k] = cg;
  return cg;
}

/* Draw color glyph G of FONT with its origin (pen) at X and baseline at Y,
   exactly like drawGlyph: does for grayscale atlas entries. */
static void
mtl_draw_color_glyph (MtlFrameData *fd, CTFontRef font, CGGlyph g,
                      float x, float y)
{
  MtlColorGlyph *cg = mtl_color_glyph (font, g);
  if (!cg) return;
  CGFloat s = g_atlas_scale;
  mtl_draw_image_texture (fd, cg.tex,
                          x - cg.bearing_x / s, y - cg.bearing_y / s,
                          cg.w / s, cg.h / s, 1.0f);
}

/* -----------------------------------------------------------------------
   gfx driver: the small vtable the platform-neutral drawing
   policy in gfxterm.c renders through.  Each op is a thin wrapper over
   MtlFrameData / the atlas; the policy never touches ObjC.
   ----------------------------------------------------------------------- */

static bool
mtl_drv_frame_ready (struct frame *f)
{
  return mtl_get_frame_data (f) != nil;
}

static void
mtl_drv_begin_frame (struct frame *f)
{
  [mtl_get_frame_data (f) beginFrame];
}

static void
mtl_drv_end_frame (struct frame *f, bool present_p)
{
  [mtl_get_frame_data (f) endFramePresent:present_p];
}

static void
mtl_drv_present (struct frame *f)
{
  [mtl_get_frame_data (f) presentCoalesced];
}

static bool
mtl_drv_in_cycle (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  return fd && fd.encoder != nil;
}

static bool
mtl_drv_pending_present (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  return fd && fd.needsPresent;
}

static void
mtl_drv_clip_to_glyph_string (struct glyph_string *s)
{
  MtlFrameData *fd = mtl_get_frame_data (s->f);
  if (!fd) return;
  NSRect clip;
  get_glyph_string_clip_rect (s, &clip);
  if (getenv ("MTL_LOG_SEQ")) fprintf (stderr, "[mtlclip] %g %g %g %g\n", clip.origin.x, clip.origin.y, clip.size.width, clip.size.height);
  [fd applyClipRect:clip];
}

static void
mtl_drv_clear_clip (struct frame *f)
{
  [mtl_get_frame_data (f) clearClipRect];
}

static void
mtl_drv_fill_rect (struct frame *f, int x, int y, int w, int h,
                   unsigned long color)
{
  if (getenv ("MTL_LOG_SEQ")) fprintf (stderr, "[mtlfill] %d %d %d %d %lx\n", x, y, w, h, color);
  [mtl_get_frame_data (f) fillRect:NSMakeRect (x, y, w, h) color:color];
}

static void
mtl_drv_copy_region (struct frame *f, int x, int y, int w, int h,
                     int dst_x, int dst_y)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  /* Vertical move (scroll_run) and horizontal move (shift-for-insert) map
     to the two scratch-bounced blits MtlFrameData implements.  */
  if (dst_x == x)
    [fd scrollRunFrom:y to:dst_y x:x width:w height:h];
  else if (dst_y == y)
    [fd shiftGlyphsX:x y:y width:w height:h by:dst_x - x];
  else
    [fd scrollRunFrom:y to:dst_y x:x width:w height:h];
}

static CTFontRef
mtl_drv_ctfont (struct font *font)
{
  return font ? (CTFontRef) macfont_get_nsctfont (font) : NULL;
}

static bool
mtl_drv_font_ready_p (struct font *font)
{
  return mtl_drv_ctfont (font) != NULL;
}

static struct gfx_glyph *
mtl_drv_get_glyph (struct font *font, unsigned int glyph_id)
{
  CTFontRef ct = mtl_drv_ctfont (font);
  if (!ct) return NULL;
  return mtl_cache_glyph_id (ct, (CGGlyph) glyph_id);
}

static void
mtl_drv_draw_glyph (struct frame *f, struct gfx_glyph *g,
                    float x, float ybase, unsigned long color)
{
  [mtl_get_frame_data (f) drawGlyph:(MtlGlyphCacheEntry *) g
                                 at:CGPointMake (x, ybase)
                              color:color];
}

static bool
mtl_drv_color_font_p (struct font *font)
{
  CTFontRef ct = mtl_drv_ctfont (font);
  return ct && (CTFontGetSymbolicTraits (ct) & kCTFontTraitColorGlyphs) != 0;
}

static float
mtl_drv_draw_color_glyph (struct frame *f, struct font *font,
                          unsigned int glyph_id, float x, float ybase)
{
  CTFontRef ct = mtl_drv_ctfont (font);
  if (!ct) return 0.0f;
  MtlColorGlyph *cg = mtl_color_glyph (ct, (CGGlyph) glyph_id);
  if (!cg) return 0.0f;
  mtl_draw_color_glyph (mtl_get_frame_data (f), ct, (CGGlyph) glyph_id,
                        x, ybase);
  return cg.advance_x;
}

static void *
mtl_drv_image_texture (struct frame *f, struct image *img, int *w, int *h)
{
  (void) f;
  id<MTLTexture> tex = mtl_texture_for_image (img);
  if (!tex) return NULL;
  /* The texture holds physical pixels; callers compute slice UVs in the
     image's logical display size.  */
  if (w) *w = img->width  > 0 ? img->width  : (int) lround (tex.width  / g_atlas_scale);
  if (h) *h = img->height > 0 ? img->height : (int) lround (tex.height / g_atlas_scale);
  return (void *) tex;
}

static void
mtl_drv_draw_texture (struct frame *f, void *texture,
                      float x, float y, float w, float h,
                      float u0, float v0, float u1, float v1, float alpha)
{
  mtl_draw_image_texture_uv (mtl_get_frame_data (f),
                             (id<MTLTexture>) texture,
                             x, y, w, h, u0, v0, u1, v1, alpha);
}

static void
mtl_drv_draw_bitmap (struct frame *f, unsigned short *bits, int dh,
                     int bw, int wd, int h, int x, int y,
                     unsigned long color)
{
  [mtl_get_frame_data (f) drawFringeBits:bits dh:dh bw:bw wd:wd h:h
                                     atX:x y:y color:color];
}

/* Fallback shade if NSColor refuses (grayscale-less colorspaces).  */
static unsigned long
mtl_shade_color (unsigned long c, double level, bool lighten)
{
  double r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
  if (lighten) { r += (255 - r) * level; g += (255 - g) * level; b += (255 - b) * level; }
  else         { r *= (1.0 - level);     g *= (1.0 - level);     b *= (1.0 - level); }
  return ((unsigned long) r << 16) | ((unsigned long) g << 8) | (unsigned long) b;
}

/* Relief colors via NSColor highlightWithLevel:/shadowWithLevel:, the same
   colors ns_setup_relief_colors uses.  They are appearance-dynamic (dark
   mode shifts the highlight), so a plain blend toward pure white/black
   does not match what NS renders (e.g. the mode-line top edge: NS ~177 vs
   blend-to-white 211).  */
static void
mtl_drv_relief_colors (struct glyph_string *s, unsigned long *light,
                       unsigned long *dark)
{
  struct face *face = s->face;
  unsigned long base = face->use_box_color_for_shadows_p
                       ? face->box_color : face->background;
  if (s->hl == DRAW_CURSOR)
    base = ns_color_to_pixel (FRAME_CURSOR_COLOR (s->f));
  NSColor *bc = [NSColor colorWithUnsignedLong:base];
  NSColor *lc = [bc highlightWithLevel:0.4];
  NSColor *dc = [bc shadowWithLevel:0.4];
  *light = lc ? ns_color_to_pixel (lc) : mtl_shade_color (base, 0.4, true);
  *dark  = dc ? ns_color_to_pixel (dc) : mtl_shade_color (base, 0.4, false);
}

static unsigned long
mtl_drv_frame_foreground (struct frame *f)
{
  return ns_color_to_pixel (FRAME_FOREGROUND_COLOR (f));
}

static unsigned long
mtl_drv_frame_background (struct frame *f)
{
  return ns_color_to_pixel (FRAME_BACKGROUND_COLOR (f));
}

static unsigned long
mtl_drv_cursor_color (struct frame *f)
{
  return ns_color_to_pixel (FRAME_CURSOR_COLOR (f));
}

/* Feed the animator; report whether an animated overlay draws the cursor
   (the policy then skips the static one to avoid doubling).  */
static bool
mtl_drv_note_cursor (struct frame *f, int x, int y, int w, int h,
                     unsigned long color)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !g_mtl_animations_enabled || !fd.animator)
    return false;
  /* W/H <= 0: blink-off phase.  Hide the overlay cursor and show the
     change; effects in flight keep animating via the pump.  */
  if (w <= 0 || h <= 0)
    {
      if (!fd.animator.cursorHidden)
        {
          fd.animator.cursorHidden = YES;
          if (!fd.encoder)
            [fd presentCoalesced];
        }
      return true;
    }
  fd.animator.cursorHidden = NO;
  fd.animator.cursorColor = color;
  [fd.animator setCursorX:x y:y width:w height:h];
  /* Cursor-only motion takes redisplay's fast path: no render cycle gets
     opened, so nothing would present the moved overlay (the display link
     does not fire while Emacs idles).  Composite now so the cursor is
     never left painted at its old position. */
  if (!fd.encoder)
    [fd presentCoalesced];
  /* Only the modes that ANIMATE the cursor body draw it in the overlay;
     for the burst modes (sonicboom/ripple/pixiedust) the policy keeps
     drawing the proper static cursor (inverted glyph) and the overlay
     adds just the effects -- a solid overlay body would hide the
     character under the cursor.  */
  MtlCursorMode mode = fd.animator.cursorMode;
  return (mode == MTL_CURSOR_SPRING || mode == MTL_CURSOR_TORPEDO
          || mode == MTL_CURSOR_HOLLOW || mode == MTL_CURSOR_BEAM);
}

static struct gfx_driver mtl_gfx_driver =
{
  .name                 = "metal",
  .frame_ready          = mtl_drv_frame_ready,
  .begin_frame          = mtl_drv_begin_frame,
  .end_frame            = mtl_drv_end_frame,
  .present              = mtl_drv_present,
  .in_cycle             = mtl_drv_in_cycle,
  .pending_present      = mtl_drv_pending_present,
  .clip_to_glyph_string = mtl_drv_clip_to_glyph_string,
  .clear_clip           = mtl_drv_clear_clip,
  .fill_rect            = mtl_drv_fill_rect,
  .copy_region          = mtl_drv_copy_region,
  .font_ready_p         = mtl_drv_font_ready_p,
  .get_glyph            = mtl_drv_get_glyph,
  .draw_glyph           = mtl_drv_draw_glyph,
  .color_font_p         = mtl_drv_color_font_p,
  .draw_color_glyph     = mtl_drv_draw_color_glyph,
  .warm_glyph_cache     = mtl_warm_glyph_cache,
  .image_texture        = mtl_drv_image_texture,
  .invalidate_image     = mtl_invalidate_image_texture,
  .draw_texture         = mtl_drv_draw_texture,
  .draw_bitmap          = mtl_drv_draw_bitmap,
  .relief_colors        = mtl_drv_relief_colors,
  .frame_foreground     = mtl_drv_frame_foreground,
  .frame_background     = mtl_drv_frame_background,
  .cursor_color         = mtl_drv_cursor_color,
  .note_cursor          = mtl_drv_note_cursor,
};

/* -----------------------------------------------------------------------
   redisplay_interface — all file-static, called by xdisp.c engine
   ----------------------------------------------------------------------- */

/* D1: the NS scroll bars are transparent NSScroller overlays, so the gutter
   behind them shows whatever is in the static texture.  ns_set_*_scroll_bar
   clears that area with ns_clear_frame_area, which targets CoreGraphics, not the
   Metal texture, so on a window split the old text in the new gutter column
   bleeds through until the next full redraw.  Wrap the hooks to queue the scroll
   bar area for clearing.  The hooks run in redisplay's layout phase, before
   update_begin, so there is no active render encoder yet: we record the rect and
   flush it to background at the start of the next frame (see beginFrame).  Then
   delegate to NS to position the scroller.  Mirrors ns_set_*_scroll_bar. */
static void (*mtl_orig_set_vsb_hook) (struct window *, int, int, int) = NULL;
static void (*mtl_orig_set_hsb_hook) (struct window *, int, int, int) = NULL;

static void
mtl_set_vertical_scroll_bar (struct window *window,
                             int portion, int whole, int position)
{
  struct frame *f = XFRAME (WINDOW_FRAME (window));
  int window_y, window_height;
  window_box (window, ANY_AREA, 0, &window_y, 0, &window_height);
  gfx_queue_clear (f, WINDOW_SCROLL_BAR_AREA_X (window), window_y,
                   WINDOW_SCROLL_BAR_AREA_WIDTH (window), window_height);

  if (mtl_orig_set_vsb_hook)
    mtl_orig_set_vsb_hook (window, portion, whole, position);
}

static void
mtl_set_horizontal_scroll_bar (struct window *window,
                               int portion, int whole, int position)
{
  struct frame *f = XFRAME (WINDOW_FRAME (window));
  int window_x, window_width;
  window_box (window, ANY_AREA, &window_x, 0, &window_width, 0);
  gfx_queue_clear (f, window_x, WINDOW_SCROLL_BAR_AREA_Y (window),
                   window_width, WINDOW_SCROLL_BAR_AREA_HEIGHT (window));

  if (mtl_orig_set_hsb_hook)
    mtl_orig_set_hsb_hook (window, portion, whole, position);
}

/* ---------------------------------------------------------------------------
   Inline video API (called from mtlfns.m).
   --------------------------------------------------------------------------- */

bool
mtl_video_open (struct frame *f, const char *path, int x, int y,
                int w, int h, bool loop)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return false;

  if (fd.videoPlayer)
    {
      [fd.videoPlayer shutdown];
      fd.videoPlayer = nil;
    }

  NSString *ns_path = [NSString stringWithUTF8String:path];
  if (!ns_path) return false;
  NSURL *video_url;
  if ([ns_path hasPrefix:@"https://"] || [ns_path hasPrefix:@"http://"])
    video_url = [NSURL URLWithString:ns_path];
  else
    {
      if (![[NSFileManager defaultManager] fileExistsAtPath:ns_path])
        return false;
      video_url = [NSURL fileURLWithPath:ns_path];
    }

  MtlVideoPlayer *vp =
    [[MtlVideoPlayer alloc] initWithURL:video_url
                                   rect:NSMakeRect (x, y, w, h)
                                   loop:loop];
  if (!vp) return false;
  fd.videoPlayer = vp;
  [vp release];

  /* The animator's CADisplayLink drives presents during playback. */
  [fd.animator startAnimating];
  return true;
}

bool
mtl_video_close (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  [fd.videoPlayer shutdown];
  fd.videoPlayer = nil;
  if (!g_mtl_animations_enabled)
    [fd.animator stopAnimating];
  [fd presentCoalesced];   /* repaint without the overlay */
  return true;
}

bool
mtl_video_set_paused (struct frame *f, bool paused)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  if (paused)
    [fd.videoPlayer.player pause];
  else
    [fd.videoPlayer.player play];
  return true;
}

bool
mtl_video_set_rect (struct frame *f, int x, int y, int w, int h)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  fd.videoPlayer.rect = NSMakeRect (x, y, w, h);
  return true;
}

bool
mtl_video_set_clip (struct frame *f, int x, int y, int w, int h)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  fd.videoPlayer.clipRect = NSMakeRect (x, y, w, h);
  return true;
}

/* Total duration of the inline video in seconds, or -1 if there is no
   video or its duration is not known yet (the item is still loading). */
double
mtl_video_duration (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return -1.0;
  AVPlayerItem *item = fd.videoPlayer.player.currentItem;
  if (!item) return -1.0;
  CMTime d = item.duration;
  if (!CMTIME_IS_NUMERIC (d)) return -1.0;
  return CMTimeGetSeconds (d);
}

/* Current playback position of the inline video in seconds, or -1 if
   there is no video. */
double
mtl_video_position (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return -1.0;
  CMTime t = fd.videoPlayer.player.currentTime;
  if (!CMTIME_IS_NUMERIC (t)) return -1.0;
  return CMTimeGetSeconds (t);
}

/* Seek the inline video to SECS seconds.  Pulls a fresh frame so the
   picture updates even while paused.  Returns false if no video. */
bool
mtl_video_seek (struct frame *f, double secs)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  if (secs < 0) secs = 0;
  CMTime t = CMTimeMakeWithSeconds (secs, NSEC_PER_SEC);
  /* Half-frame tolerance: responsive scrubbing without forcing an exact
     (and expensive) frame-accurate seek on every drag step. */
  CMTime tol = CMTimeMakeWithSeconds (0.05, NSEC_PER_SEC);
  [fd.videoPlayer.player seekToTime:t toleranceBefore:tol toleranceAfter:tol];
  if (!fd.encoder)
    [fd presentCoalesced];   /* show the seeked frame */
  return true;
}

/* 1 if the inline video is playing, 0 if paused, -1 if there is none. */
int
mtl_video_playing (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return -1;
  return [fd.videoPlayer isPlaying] ? 1 : 0;
}

/* Natural (presentation) size of the inline video in pixels.  Returns
   false if there is no video or its size is not known yet. */
bool
mtl_video_size (struct frame *f, double *w, double *h)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  AVPlayerItem *item = fd.videoPlayer.player.currentItem;
  if (!item) return false;
  CGSize sz = item.presentationSize;
  if (sz.width <= 0 || sz.height <= 0) return false;
  *w = sz.width;
  *h = sz.height;
  return true;
}

/* Buffer-switch crossfade: copy the CURRENT static texture into the
   transition snapshot and arm the fade.  Called from Lisp just before
   redisplay paints the new buffer (pre-redisplay-functions), so the
   snapshot still holds the old content. */
bool
mtl_transition_start (struct frame *f, float duration)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.staticTexture || fd.encoder || duration <= 0)
    return false;

  id<MTLTexture> src = fd.staticTexture;
  id<MTLTexture> snap = fd.transitionTexture;
  if (!snap || snap.width != src.width || snap.height != src.height)
    {
      MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:src.pixelFormat
                                     width:src.width
                                    height:src.height
                                 mipmapped:NO];
      td.usage = MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModePrivate;
      snap = [g_device newTextureWithDescriptor:td];
      fd.transitionTexture = snap;
      [snap release];
    }

  id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
  [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (0, 0, 0)
             sourceSize:MTLSizeMake (src.width, src.height, 1)
              toTexture:snap destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (0, 0, 0)];
  [blit endEncoding];
  [cmd commit];

  fd.transitionStart = CACurrentMediaTime ();
  fd.transitionDuration = duration;
  return true;
}

/* Present a fresh composite if a video is active.  Called from a Lisp-level
   timer (mtl.el): Emacs's event loop starves the CADisplayLink while idle,
   so Lisp timers are what reliably drives playback presents. */
bool
mtl_video_tick (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.videoPlayer) return false;
  if ([fd.videoPlayer isPlaying] && !fd.encoder)
    [fd presentCoalesced];
  return true;
}

static void
mtl_define_frame_cursor (struct frame *f, Emacs_Cursor c)
{ (void)f; (void)c; }

static void
mtl_show_hourglass (struct frame *f)
{
  (void)f;
  dispatch_async (dispatch_get_main_queue (),
    ^{ [[NSCursor operationNotAllowedCursor] push]; });
}

static void
mtl_hide_hourglass (struct frame *f)
{
  (void)f;
  dispatch_async (dispatch_get_main_queue (), ^{ [NSCursor pop]; });
}

void
mtl_default_font_parameter (struct frame *f, Lisp_Object parms)
{ (void)f; (void)parms; }

static frame_parm_handler mtl_frame_parm_handlers[] =
{
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
};

static struct redisplay_interface mtl_redisplay_interface =
{
  mtl_frame_parm_handlers,
  gui_produce_glyphs,
  gui_write_glyphs,
  gui_insert_glyphs,
  gui_clear_end_of_line,
  gfx_scroll_run,
  gfx_after_update_window_line,
  NULL,    /* update_window_begin */
  NULL,    /* update_window_end   */
  gfx_flush_display,
  gui_clear_window_mouse_face,
  gui_get_glyph_overhangs,
  gui_fix_overlapping_area,
  gfx_draw_fringe_bitmap,
  gfx_define_fringe_bitmap,
  gfx_destroy_fringe_bitmap,
  gfx_compute_glyph_string_overhangs,
  gfx_draw_glyph_string,
  mtl_define_frame_cursor,
  gfx_clear_frame_area,
  gfx_clear_under_internal_border,
  gfx_draw_window_cursor,
  gfx_draw_vertical_window_border,
  gfx_draw_window_divider,
  gfx_shift_glyphs_for_insert,
  mtl_show_hourglass,
  mtl_hide_hourglass,
  mtl_default_font_parameter,
};

/* -----------------------------------------------------------------------
   Patch terminal rif — replace NS rendering with Metal for a frame's terminal.
   Called from mtl-enable-for-frame.
   ----------------------------------------------------------------------- */

/* Phase 3 resize handler: updates CAMetalLayer drawableSize when the
   EmacsView is resized.  Stored as an associated object on the EmacsView. */

static const char mtl_resize_obs_key;

@interface MtlResizeObserver : NSObject
@property (nonatomic, assign) CAMetalLayer *layer;   /* not weak: layer owned by MtlFrameData */
@property (nonatomic, assign) struct frame *emacsFrame;
@end

@implementation MtlResizeObserver

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)ctx
{
  (void)change; (void)ctx;
  NSView *view = (NSView *)object;
  NSSize sz = view.bounds.size;

  /* Handle 'window' KVO (monitor/DPI change): re-read backing scale factor */
  if ([keyPath isEqualToString:@"window"])
    {
      NSWindow *win = view.window;
      if (win && self.layer)
        {
          CGFloat scale = win.backingScaleFactor;
          self.layer.contentsScale = scale;
          self.layer.drawableSize  = CGSizeMake (sz.width * scale, sz.height * scale);
          self.layer.frame = view.bounds;
          if (self.emacsFrame) SET_FRAME_GARBAGED (self.emacsFrame);
        }
      return;
    }

  if (self.layer)
    {
      CGFloat scale = view.window
        ? view.window.backingScaleFactor
        : [[NSScreen mainScreen] backingScaleFactor];
      self.layer.contentsScale = scale;
      self.layer.drawableSize  = CGSizeMake (sz.width  * scale,
                                              sz.height * scale);
      self.layer.frame = view.bounds;
    }

  /* Only the layer geometry is ours to manage: the EmacsView's own
     resize path already drives Emacs's change_frame_size machinery.
     Writing FRAME_PIXEL_* directly here bypassed it and skewed window
     layout (a split landed one line off compared to the NS backend). */
  if (self.emacsFrame)
    SET_FRAME_GARBAGED (self.emacsFrame);
}

@end

/* One copy of the NS rif, patched with our Metal drawing functions.
   Allocated once when mtl_patch_terminal_rif is first called.
   CRITICAL: We must NOT replace the entire rif — the NS rif's
   frame_parm_handlers, produce_glyphs, and management functions are
   called by init_frame_faces / realize_basic_faces / Fx_create_frame.
   Replacing them all with NULLs causes SIGSEGV there.
   Solution: copy the NS rif, then override ONLY the drawing functions. */
static struct redisplay_interface *mtl_ns_rif_copy = NULL;

void
mtl_patch_terminal_rif (struct frame *f)
{
  struct terminal *term = FRAME_TERMINAL (f);
  if (!term || !term->rif) return;

  /* Build a patched copy of the NS rif (once per process lifetime).
     All NS management/frame functions are preserved; only pixel-drawing
     functions are replaced with Metal equivalents. */
  if (!mtl_ns_rif_copy)
    {
      /* Capture the ORIGINAL NS implementations first: the policy
         delegates to them for frames the GPU backend is not enabled on
         (tooltips, child frames, frames without mtl-enable).  */
      gfx_fallback.rif = term->rif;

      mtl_ns_rif_copy = xmalloc (sizeof (struct redisplay_interface));
      *mtl_ns_rif_copy = *term->rif;  /* copy all NS functions as baseline */

      /* Override only the functions that perform pixel drawing.
         Everything else (frame_parm_handlers, produce_glyphs, etc.)
         stays as the NS implementation — frame management must work. */
      mtl_ns_rif_copy->scroll_run_hook               = gfx_scroll_run;
      mtl_ns_rif_copy->after_update_window_line_hook  = gfx_after_update_window_line;
      mtl_ns_rif_copy->flush_display                 = gfx_flush_display;
      mtl_ns_rif_copy->draw_fringe_bitmap            = gfx_draw_fringe_bitmap;
      mtl_ns_rif_copy->define_fringe_bitmap          = gfx_define_fringe_bitmap;
      mtl_ns_rif_copy->destroy_fringe_bitmap         = gfx_destroy_fringe_bitmap;
      mtl_ns_rif_copy->compute_glyph_string_overhangs= gfx_compute_glyph_string_overhangs;
      mtl_ns_rif_copy->draw_glyph_string             = gfx_draw_glyph_string;
      mtl_ns_rif_copy->clear_frame_area              = gfx_clear_frame_area;
      mtl_ns_rif_copy->clear_under_internal_border   = gfx_clear_under_internal_border;
      mtl_ns_rif_copy->draw_window_cursor            = gfx_draw_window_cursor;
      mtl_ns_rif_copy->draw_vertical_window_border   = gfx_draw_vertical_window_border;
      mtl_ns_rif_copy->draw_window_divider           = gfx_draw_window_divider;
      mtl_ns_rif_copy->shift_glyphs_for_insert       = gfx_shift_glyphs_for_insert;
      /* show_hourglass, hide_hourglass, default_font_parameter: keep NS versions */
    }

  term->rif = mtl_ns_rif_copy;

  /* Patch render cycle hooks so Metal manages the frame pixel lifecycle.
     The NS backend's update_begin calls [view lockFocus] for CoreGraphics;
     we bypass that entirely and use Metal command buffers instead. */
  if (term->update_begin_hook != gfx_update_begin)
    {
      /* Same for the terminal hooks (guarded: this function runs again
         on every mtl-enable-for-frame).  */
      gfx_fallback.update_begin     = term->update_begin_hook;
      gfx_fallback.update_end       = term->update_end_hook;
      gfx_fallback.clear_frame      = term->clear_frame_hook;
      gfx_fallback.frame_up_to_date = term->frame_up_to_date_hook;
    }
  term->update_begin_hook     = gfx_update_begin;
  term->update_end_hook       = gfx_update_end;
  term->clear_frame_hook      = gfx_clear_frame;
  term->frame_up_to_date_hook = gfx_frame_up_to_date;

  /* D1: wrap the scroll bar hooks so the gutter is cleared in the Metal static
     texture (not just CoreGraphics) when windows are split or re-laid out. */
  if (term->set_vertical_scroll_bar_hook != mtl_set_vertical_scroll_bar)
    {
      mtl_orig_set_vsb_hook = term->set_vertical_scroll_bar_hook;
      term->set_vertical_scroll_bar_hook = mtl_set_vertical_scroll_bar;
    }
  if (term->set_horizontal_scroll_bar_hook != mtl_set_horizontal_scroll_bar)
    {
      mtl_orig_set_hsb_hook = term->set_horizontal_scroll_bar_hook;
      term->set_horizontal_scroll_bar_hook = mtl_set_horizontal_scroll_bar;
    }

  /* Install one KVO observer per view, including when GPU rendering is
     enabled repeatedly.  Remove it explicitly during frame teardown.  */
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (fd && !objc_getAssociatedObject (FRAME_NS_VIEW (f), &mtl_resize_obs_key))
    {
      NSView *view = FRAME_NS_VIEW (f);
      MtlResizeObserver *obs = [[MtlResizeObserver alloc] init];
      obs.layer      = fd.metalLayer;
      obs.emacsFrame = f;

      /* Observe 'frame' changes on the view (triggers on resize) */
      [view addObserver:obs forKeyPath:@"frame"
                 options:NSKeyValueObservingOptionNew context:NULL];

      /* Keep the observer alive until frame teardown removes it.  */
      objc_setAssociatedObject (view, &mtl_resize_obs_key,
                                 obs, OBJC_ASSOCIATION_RETAIN);

      /* Phase 6: multi-monitor support via KVO on 'window.screen'.
         Bug fix: NSWindowDidChangeScreenNotification with usingBlock: returns an
         observer TOKEN that MUST be stored; dropping it immediately removes the
         observer and in macOS 26.5 the token (an OS_dispatch_source internally)
         can corrupt adjacent static variables like g_image_texture_cache → crash.

         Safe alternative: observe 'window' on the view.  When the view moves to a
         new window (or the window's backing scale changes), update the Metal layer.
         This uses the same KVO mechanism as the resize observer — stable and safe. */
      [view addObserver:obs forKeyPath:@"window"
                 options:NSKeyValueObservingOptionNew context:NULL];
      [obs release];
    }
}

/* -----------------------------------------------------------------------
   Off-screen text rendering for verification
   ----------------------------------------------------------------------- */

/* Render text string into encoder using the glyph atlas.
   This is the same pipeline as mtl_draw_glyph_string but for off-screen use. */
static void
mtl_draw_string_enc (id<MTLRenderCommandEncoder> enc,
                      CTFontRef font,
                      const char *text,
                      float x, float y,
                      unsigned long color,
                      float sw, float sh)
{
  if (!g_glyph_pipeline || !g_atlas || !g_sampler) return;

  float fr, fg, fb;
  unpack_color (color, &fr, &fg, &fb);

  /* Uniform struct for NDC transform */
  MtlUniforms u = { sw, sh };
  [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
  [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];

  float pen_x = x;
  for (int i = 0; text[i]; i++)
    {
      MtlGlyphCacheEntry *ge = mtl_cache_glyph (font, (unsigned char)text[i]);
      if (!ge) continue;

      if (ge->width > 0)
        {
          /* In our coord system: y is baseline, bearing_y = dist from top to baseline */
          float x0 = pen_x - ge->bearing_x;
          float y0 = y - ge->bearing_y;
          float x1 = x0 + ge->width;
          float y1 = y0 + ge->height;

          float u0 = (float)ge->atlas_x / MTL_ATLAS_WIDTH;
          float v0 = (float)ge->atlas_y / MTL_ATLAS_HEIGHT;
          float u1 = (float)(ge->atlas_x + ge->width)  / MTL_ATLAS_WIDTH;
          float v1 = (float)(ge->atlas_y + ge->height) / MTL_ATLAS_HEIGHT;

          MtlGlyphVertex verts[6] = {
            {x0,y0,u0,v0,fr,fg,fb,1},{x1,y0,u1,v0,fr,fg,fb,1},
            {x0,y1,u0,v1,fr,fg,fb,1},{x1,y0,u1,v0,fr,fg,fb,1},
            {x1,y1,u1,v1,fr,fg,fb,1},{x0,y1,u0,v1,fr,fg,fb,1},
          };
          [enc setRenderPipelineState:g_glyph_pipeline];
          [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
          [enc setFragmentTexture:g_atlas atIndex:0];
          [enc setFragmentSamplerState:g_sampler atIndex:0];
          [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
      pen_x += ge->advance_x;
    }
}

static void
mtl_fill_rect_enc (id<MTLRenderCommandEncoder> enc,
                    float x, float y, float w, float h,
                    unsigned long color, float sw, float sh)
{
  if (!g_rect_pipeline) return;
  float r, g, b;
  unpack_color (color, &r, &g, &b);
  MtlUniforms u = { sw, sh };
  [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
  float x1=x+w, y1=y+h;
  MtlRectVertex v[6] = {
    {x,y,r,g,b,1},{x1,y,r,g,b,1},{x,y1,r,g,b,1},
    {x1,y,r,g,b,1},{x1,y1,r,g,b,1},{x,y1,r,g,b,1},
  };
  [enc setRenderPipelineState:g_rect_pipeline];
  [enc setVertexBytes:v length:sizeof(v) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

/* Public: render a Phase 2 test PNG with real text from CoreText atlas */
bool
mtl_render_text_png (const char *path)
{
  if (!mtl_global_setup ()) return false;

  int W = 800, H = 400;
  CTFontRef font14 = CTFontCreateWithName (CFSTR("Menlo"), 14.0, NULL);
  CTFontRef font12 = CTFontCreateWithName (CFSTR("Menlo"), 12.0, NULL);
  if (!font14 || !font12) return false;

  /* Pre-cache printable ASCII */
  for (int c = 32; c < 127; c++)
    {
      mtl_cache_glyph (font14, (uint32_t)c);
      mtl_cache_glyph (font12, (uint32_t)c);
    }

  float lh  = 20.0f;
  float top = 50.0f;
  float sw  = (float)W, sh = (float)H;

  /* Capture fonts and layout values into locals for block capture */
  CTFontRef bf14 = font14, bf12 = font12;

  bool ok = mtl_render_offscreen_png (path, W, H,
    ^(id<MTLRenderCommandEncoder> enc) {
      /* Header bar */
      mtl_fill_rect_enc (enc, 0, 0, sw, 30, 0x3B4252, sw, sh);
      mtl_draw_string_enc (enc, bf14, "emacs-gpu: Metal GPU Backend",
                            10, 20, 0xECEFF4, sw, sh);

      /* Body */
      mtl_draw_string_enc (enc, bf14, "GNU Emacs -- Metal GPU Backend",
                            16, top, 0xECEFF4, sw, sh);
      mtl_draw_string_enc (enc, bf12, "Phase 2: CoreText -> R8Unorm Atlas",
                            16, top+lh, 0xD8DEE9, sw, sh);
      mtl_draw_string_enc (enc, bf12, "(mtl-enable-for-frame (selected-frame))",
                            16, top+lh*3, 0x88C0D0, sw, sh);
      mtl_draw_string_enc (enc, bf12, "(mtl-device-name)  =>  \"Apple M1 Pro\"",
                            16, top+lh*4, 0xA3BE8C, sw, sh);
      mtl_draw_string_enc (enc, bf12, "(mtl-backend-p)    =>  t",
                            16, top+lh*5, 0xA3BE8C, sw, sh);
      mtl_draw_string_enc (enc, bf12, "Glyph atlas: 2048x2048 R8Unorm",
                            16, top+lh*7, 0x81A1C1, sw, sh);
      mtl_draw_string_enc (enc, bf12, "Pipeline: textured quads, alpha blend",
                            16, top+lh*8, 0x81A1C1, sw, sh);
      mtl_draw_string_enc (enc, bf12, "Shader: compiled at runtime from source",
                            16, top+lh*9, 0x81A1C1, sw, sh);

      /* Status bar */
      mtl_fill_rect_enc (enc, 0, sh-24, sw, 24, 0x3B4252, sw, sh);
      mtl_draw_string_enc (enc, bf12, "GPU: Apple M1 Pro | Metal | Nord theme",
                            10, sh-8, 0x88C0D0, sw, sh);
    });

  CFRelease (font14);
  CFRelease (font12);
  return ok;
}

/* -----------------------------------------------------------------------
   Terminal hooks (used when Metal is the primary terminal)
   ----------------------------------------------------------------------- */

static void mtl_ring_bell (struct frame *f) { (void)f; NSBeep (); }

static bool
mtl_defined_color (struct frame *f, const char *name,
                    Emacs_Color *def, bool alloc, bool makeIndex)
{
  (void)f; (void)alloc; (void)makeIndex;
  NSColor *c = nil;
  NSString *ns = [NSString stringWithUTF8String:name];
  if ([ns hasPrefix:@"#"] && ns.length == 7)
    {
      unsigned int hex = 0;
      [[NSScanner scannerWithString:[ns substringFromIndex:1]] scanHexInt:&hex];
      c = [NSColor colorWithRed:((hex>>16)&0xFF)/255.0
                          green:((hex>>8)&0xFF)/255.0
                           blue:(hex&0xFF)/255.0 alpha:1.0];
    }
  if (!c) return false;
  def->red   = (unsigned short)([c redComponent]   * 65535);
  def->green = (unsigned short)([c greenComponent] * 65535);
  def->blue  = (unsigned short)([c blueComponent]  * 65535);
  def->pixel = (((unsigned long)(def->red>>8)<<16)
               |((unsigned long)(def->green>>8)<<8)
               | (unsigned long)(def->blue>>8));
  return true;
}

static int
mtl_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  (void)terminal; (void)hold_quit;
  NSEvent *ev;
  int n = 0;
  while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                  untilDate:[NSDate distantPast]
                                     inMode:NSDefaultRunLoopMode
                                    dequeue:YES]) != nil)
    { [NSApp sendEvent:ev]; n++; }
  return n;
}

/* -----------------------------------------------------------------------
   Terminal creation and public API
   ----------------------------------------------------------------------- */

static struct terminal *
mtl_create_terminal (struct mtl_display_info *dpyinfo)
{
  struct terminal *t = create_terminal (output_ns, &mtl_redisplay_interface);
  t->display_info.ns       = (struct ns_display_info *)dpyinfo;
  dpyinfo->terminal        = t;
  t->clear_frame_hook      = gfx_clear_frame;
  t->ring_bell_hook        = mtl_ring_bell;
  t->update_begin_hook     = gfx_update_begin;
  t->update_end_hook       = gfx_update_end;
  t->read_socket_hook      = mtl_read_socket;
  t->frame_up_to_date_hook = gfx_frame_up_to_date;
  t->defined_color_hook    = mtl_defined_color;
  t->delete_frame_hook     = mtl_destroy_window;
  t->delete_terminal_hook  = mtl_term_shutdown;
  return t;
}

struct mtl_display_info *
mtl_term_init (Lisp_Object display_name)
{
  static int initialized = 0;
  if (initialized) return mtl_display_list;
  initialized = 1;

  block_input ();
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  mtl_global_setup ();
  glyph_cache_init ();

  struct mtl_display_info *dpyinfo = xzalloc (sizeof *dpyinfo);
  mtl_create_terminal (dpyinfo);
  mtl_display_list = dpyinfo;

  if (selfds[0] == -1)
    {
      if (emacs_pipe (selfds) != 0) emacs_abort ();
      fcntl (selfds[0], F_SETFL, O_NONBLOCK | fcntl (selfds[0], F_GETFL));
    }

  unblock_input ();
  (void)display_name;
  return dpyinfo;
}

void
mtl_term_shutdown (struct terminal *terminal)
{
  struct mtl_display_info *dpyinfo =
    (struct mtl_display_info *)terminal->display_info.ns;
  if (dpyinfo == mtl_display_list) mtl_display_list = dpyinfo->next;
  xfree (dpyinfo);
}

void
mtl_free_frame_resources (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (fd)
    {
      NSView *view = FRAME_NS_VIEW (f);
      MtlResizeObserver *obs = objc_getAssociatedObject (view,
                                                        &mtl_resize_obs_key);
      if (obs)
        {
          obs.emacsFrame = NULL;
          obs.layer = nil;
          [view removeObserver:obs forKeyPath:@"frame"];
          [view removeObserver:obs forKeyPath:@"window"];
          objc_setAssociatedObject (view, &mtl_resize_obs_key,
                                    nil, OBJC_ASSOCIATION_RETAIN);
        }
      [fd shutdown];
      objc_setAssociatedObject (view, &mtl_frame_key,
                                nil, OBJC_ASSOCIATION_RETAIN);
    }
  gfx_free_frame_state (f);
}

void
mtl_destroy_window (struct frame *f)
{
  mtl_free_frame_resources (f);
}

/* -----------------------------------------------------------------------
   Off-screen render (for testing without screen capture)
   ----------------------------------------------------------------------- */

bool
mtl_render_offscreen_png (const char *path, int width, int height,
                           void (^draw)(id<MTLRenderCommandEncoder>))
{
  if (!mtl_global_setup ()) return false;

  MTLTextureDescriptor *td =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                       width:(NSUInteger)width
                                                      height:(NSUInteger)height
                                                   mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [g_device newTextureWithDescriptor:td];
  if (!tex) return false;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture    = tex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake (0x2E/255.0, 0x34/255.0, 0x40/255.0, 1.0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];

  /* Upload uniforms */
  MtlUniforms u = { (float)width, (float)height };
  [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
  [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];

  if (draw) draw (enc);

  [enc endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];

  /* Read back BGRA, swap to RGBA */
  NSUInteger bpr   = (NSUInteger)(width * 4);
  NSUInteger total = bpr * (NSUInteger)height;
  uint8_t *px = (uint8_t *)malloc (total);
  if (!px) return false;

  [tex getBytes:px bytesPerRow:bpr
     fromRegion:MTLRegionMake2D(0,0,(NSUInteger)width,(NSUInteger)height)
      mipmapLevel:0];
  for (int i = 0; i < width * height; i++)
    { uint8_t t=px[i*4]; px[i*4]=px[i*4+2]; px[i*4+2]=t; }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB ();
  CGContextRef ctx = CGBitmapContextCreate (px, (size_t)width, (size_t)height,
                                             8, (size_t)bpr, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease (cs);
  CGImageRef img = CGBitmapContextCreateImage (ctx);
  CGContextRelease (ctx);

  NSString *nspath = [NSString stringWithUTF8String:path];
  NSURL *url = [NSURL fileURLWithPath:nspath];
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL (
    (__bridge CFURLRef)url, kUTTypePNG, 1, NULL);
  CGImageDestinationAddImage (dst, img, NULL);
  bool ok = CGImageDestinationFinalize (dst);
  CFRelease (dst);
  CGImageRelease (img);
  free (px);
  return ok;
}

#endif /* HAVE_MTL */
