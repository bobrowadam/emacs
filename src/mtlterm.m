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
  color.a *= in.alpha;
  return color;
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
  float screen_width, screen_height;
} MtlUniforms;

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

  /* Phase 5: image pipeline (RGBA textures, alpha blending) */
  {
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction  = [g_library newFunctionWithName:@"image_vertex"];
    pd.fragmentFunction = [g_library newFunctionWithName:@"image_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorSourceAlpha;
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
      /* Atlas full: reset and clear (simple strategy) */
      g_atlas_next_x = g_atlas_next_y = g_atlas_row_h = 0;
      glyph_cache_init ();
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
  fd.emacsFrame   = f;

  /* Phase 4: create animator.  Only start the 60fps loop when the animation
     layer is explicitly enabled (correctness first, animation opt-in). */
  MtlAnimator *anim = [[MtlAnimator alloc] initWithFrame:f];
  fd.animator = anim;

  /* Register the Metal implementation of the gfx driver vtable
     (the neutral policy in gfxterm.c draws through it).  */
  gfx_drv = &mtl_gfx_driver;
  if (g_mtl_animations_enabled)
    [anim startAnimating];

  objc_setAssociatedObject (view, &mtl_frame_key,
                             fd, OBJC_ASSOCIATION_RETAIN);
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
  MtlFrameData *fd = mtl_get_frame_data (self.emacsFrame);
  if (!fd || !fd.metalLayer) return;

  BOOL needsComposite = NO;

  /* Mirror the engine's cursor visibility (blink-cursor-mode toggles it
     via internal-show-cursor -> erase_phys_cursor, which never reaches
     the rif: it just repaints the glyph, invisible to an overlay
     cursor).  Poll it here so the animated cursor blinks too.  */
  struct frame *f = self.emacsFrame;
  if (f && WINDOWP (f->selected_window))
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

  if (needsComposite || self.cursorDirty)
    {
      self.cursorDirty = NO;
      [fd compositeToScreen];
    }
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
   @implementation MtlFrameData
   ----------------------------------------------------------------------- */

@interface MtlFrameData ()
- (void)openRenderEncoderClear:(BOOL)clear;
- (void)scrollRunFrom:(int)fromY to:(int)toY x:(int)x width:(int)w height:(int)h;
- (void)shiftGlyphsX:(int)x y:(int)y width:(int)w height:(int)h by:(int)shift;
- (void)drawFringeBits:(unsigned short *)bits dh:(int)dh bw:(int)bw
                    wd:(int)wd h:(int)h
                   atX:(int)x y:(int)y color:(unsigned long)color;
- (void)applyClipRect:(NSRect)r;
- (void)clearClipRect;
@end

@implementation MtlFrameData

/* Clip subsequent draws on the current encoder to R (logical pixels), like the
   NS backend's ns_focus clipping with get_glyph_string_clip_rect.  This is what
   keeps a filled-box cursor on a tall row (e.g. an image line) at the size of
   the character cell instead of the whole row, and stops overhangs from
   bleeding outside the window area. */
- (void)applyClipRect:(NSRect)r
{
  if (!self.encoder || !self.staticTexture) return;
  CGSize dsz = self.metalLayer.drawableSize;
  NSSize lsz = self.metalLayer.frame.size;
  double scx = lsz.width  > 0 ? dsz.width  / lsz.width  : 1.0;
  double scy = lsz.height > 0 ? dsz.height / lsz.height : 1.0;
  long tw = (long) self.staticTexture.width;
  long th = (long) self.staticTexture.height;
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

- (void)clearClipRect
{
  if (!self.encoder || !self.staticTexture) return;
  MTLScissorRect sc = { 0, 0, self.staticTexture.width,
                        self.staticTexture.height };
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

  /* The copy must run after the draws already recorded this frame.  End the
     render encoder, do the two blits on the same command buffer (Metal's hazard
     tracking orders them after the render writes), then reopen the encoder with
     LOAD so subsequent draw_glyph_string calls land on top of the moved pixels. */
  BOOL hadEncoder = (self.encoder != nil);
  if (self.encoder) { [self.encoder endEncoding]; self.encoder = nil; }
  if (!self.cmdBuf) self.cmdBuf = [g_queue commandBuffer];

  id<MTLBlitCommandEncoder> blit = [self.cmdBuf blitCommandEncoder];
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

  /* Track the backing scale so the glyph atlas is baked at physical resolution.
     If it changes (window moved to a different-DPI monitor), drop the atlas so
     glyphs re-rasterize at the new scale. */
  NSSize fsz = self.metalLayer.frame.size;
  CGFloat scale = fsz.width > 0 ? dsz.width / fsz.width : 1.0;
  if (scale > 0 && fabs (scale - g_atlas_scale) > 0.01)
    {
      g_atlas_scale  = scale;
      g_atlas_next_x = g_atlas_next_y = g_atlas_row_h = 0;
      glyph_cache_init ();
      mtl_color_glyph_cache_clear ();   /* color glyphs are scale-baked too */
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
      self.staticTexture = [g_device newTextureWithDescriptor:td];
      self.scratchTexture = [g_device newTextureWithDescriptor:td];
      needsClear = YES;  /* New or resized texture: clear to background color */
    }

  NSSize sz = self.metalLayer.frame.size;
  MtlUniforms *u = (MtlUniforms *)[self.uniformBuffer contents];
  u->screen_width  = (float)sz.width;
  u->screen_height = (float)sz.height;

  self.cmdBuf = [g_queue commandBuffer];
  [self openRenderEncoderClear:needsClear];
}

- (void)fillRect:(NSRect)rect color:(unsigned long)color
{
  if (!self.encoder || !g_rect_pipeline) return;

  float r, g, b;
  unpack_color (color, &r, &g, &b);

  float x0 = (float)NSMinX(rect), y0 = (float)NSMinY(rect);
  float x1 = (float)NSMaxX(rect), y1 = (float)NSMaxY(rect);

  MtlRectVertex v[6] = {
    {x0,y0,r,g,b,1}, {x1,y0,r,g,b,1}, {x0,y1,r,g,b,1},
    {x1,y0,r,g,b,1}, {x1,y1,r,g,b,1}, {x0,y1,r,g,b,1},
  };
  [self.encoder setRenderPipelineState:g_rect_pipeline];
  [self.encoder setVertexBytes:v length:sizeof(v) atIndex:0];
  [self.encoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [self.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
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
  float x1 = x0 + ge->width  / s;
  float y1 = y0 + ge->height / s;

  float u0 = (float)ge->atlas_x / MTL_ATLAS_WIDTH;
  float v0 = (float)ge->atlas_y / MTL_ATLAS_HEIGHT;
  float u1 = (float)(ge->atlas_x + ge->width)  / MTL_ATLAS_WIDTH;
  float v1 = (float)(ge->atlas_y + ge->height) / MTL_ATLAS_HEIGHT;

  MtlGlyphVertex v[6] = {
    {x0,y0, u0,v0, fr,fg,fb,1}, {x1,y0, u1,v0, fr,fg,fb,1},
    {x0,y1, u0,v1, fr,fg,fb,1}, {x1,y0, u1,v0, fr,fg,fb,1},
    {x1,y1, u1,v1, fr,fg,fb,1}, {x0,y1, u0,v1, fr,fg,fb,1},
  };
  [self.encoder setRenderPipelineState:g_glyph_pipeline];
  [self.encoder setVertexBytes:v length:sizeof(v) atIndex:0];
  [self.encoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
  [self.encoder setFragmentTexture:g_atlas atIndex:0];
  [self.encoder setFragmentSamplerState:g_sampler atIndex:0];
  [self.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

/* Rasterize a fringe bitmap (rows of bits, MSB-first like the X backend's
   XCreatePixmapFromBitmapData) into a one-shot R8 coverage texture and draw it
   as a colored quad.  Reuses the glyph pipeline (coverage * color).  bits[dh+r]
   is row r; the visible window is [dh, dh+h).  A fresh texture per call avoids
   the deferred-sampling hazard of reusing one texture across queued draws; the
   command buffer retains it until completion, and fringes are few per frame. */
- (void)drawFringeBits:(unsigned short *)bits dh:(int)dh bw:(int)bw
                    wd:(int)wd h:(int)h
                   atX:(int)x y:(int)y color:(unsigned long)color
{
  if (!self.encoder || !g_glyph_pipeline || !bits || wd <= 0 || h <= 0) return;
  if (wd > 32) wd = 32;
  if (bw < wd) bw = wd;

  MTLTextureDescriptor *td =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                       width:(NSUInteger) wd
                                                      height:(NSUInteger) h mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [g_device newTextureWithDescriptor:td];

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
   while never delaying a visible update by more than ~8 ms.  */
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
    if (self.needsPresent && !self.encoder)
      [self compositeToScreen];
  });
}

- (void)presentCoalesced
{
  if (CACurrentMediaTime () - self.lastPresentTime < MTL_PRESENT_COALESCE)
    {
      self.needsPresent = YES;
      [self schedulePresent];
    }
  else
    [self compositeToScreen];
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
          [self.cmdBuf commit];
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
  [cmd commit];
}

/* Encode the full composite (static blit + video + animation overlays)
   targeting DRAWABLE on CMD, and queue its present.  Shared by the
   standalone present (compositeToScreen) and the single-commit path in
   endFramePresent:.  */
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

  NSSize sz = self.metalLayer.frame.size;
  MtlAnimator *anim = self.animator;

  /* Update uniforms for compositor pass */
  MtlUniforms *u = (MtlUniforms *)[self.uniformBuffer contents];
  u->screen_width  = (float)sz.width;
  u->screen_height = (float)sz.height;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture    = drawable.texture;
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
              long tw = (long) drawable.texture.width;
              long th = (long) drawable.texture.height;
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
              MTLScissorRect full = { 0, 0, drawable.texture.width,
                                      drawable.texture.height };
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
  [cmd presentDrawable:drawable];
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

  /* Cache lookup: key is the struct image* pointer directly.
     CFDictionary with NULL key callbacks uses pointer equality — correct and
     fast.  Re-rasterize if the display size changed (reload / new transform). */
  id<MTLTexture> tex = (__bridge id<MTLTexture>)
    CFDictionaryGetValue (g_image_texture_cache, (const void *)img);
  if (tex && tex.width == w && tex.height == h) return tex;

  /* Render NSImage to a BGRA8 bitmap via CGContext */
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB ();
  size_t bpr    = w * 4;
  uint8_t *px   = (uint8_t *)calloc (1, bpr * h);
  CGContextRef ctx = CGBitmapContextCreate (px, w, h, 8, bpr, cs,
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

  CGContextTranslateCTM (ctx, 0, (CGFloat)h);
  CGContextScaleCTM (ctx, 1.0, -1.0);
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
                                                       width:w height:h mipmapped:NO];
  td.usage       = MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  tex = [g_device newTextureWithDescriptor:td];
  [tex replaceRegion:MTLRegionMake2D (0, 0, w, h)
         mipmapLevel:0
           withBytes:px bytesPerRow:bpr];
  free (px);

  /* Store in cache: key = raw struct image* pointer, value = MTLTexture (CF-retained) */
  CFDictionarySetValue (g_image_texture_cache, (const void *)img,
                        (__bridge CFTypeRef)tex);
  return tex;
}

/* Invalidate cached texture for an image (used when image is reloaded or freed) */
static void __attribute__((unused))
mtl_invalidate_image_texture (struct image *img)
{
  if (g_image_texture_cache && img)
    CFDictionaryRemoveValue (g_image_texture_cache, (const void *)img);
}

/* Render the (U0,V0)-(U1,V1) subrect of a Metal RGBA texture as a quad at
   (x,y,w,h) into fd.encoder.  Used for image slices (insert-sliced-image). */
static void
mtl_draw_image_texture_uv (MtlFrameData *fd, id<MTLTexture> tex,
                           float x, float y, float w, float h,
                           float u0, float v0, float u1, float v1, float alpha)
{
  if (!fd.encoder || !g_image_pipeline || !tex) return;

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
  if (w) *w = (int) tex.width;
  if (h) *h = (int) tex.height;
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
            [fd compositeToScreen];
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
    [fd compositeToScreen];
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
  if (!ns_path || ![[NSFileManager defaultManager] fileExistsAtPath:ns_path])
    return false;

  MtlVideoPlayer *vp =
    [[MtlVideoPlayer alloc] initWithURL:[NSURL fileURLWithPath:ns_path]
                                   rect:NSMakeRect (x, y, w, h)
                                   loop:loop];
  if (!vp) return false;
  fd.videoPlayer = vp;

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
  [fd compositeToScreen];   /* repaint without the overlay */
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
    [fd compositeToScreen];   /* show the seeked frame immediately */
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
    [fd compositeToScreen];
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

  /* Install a KVO observer so the Metal layer tracks EmacsView size changes.
     When the user resizes the window, the CAMetalLayer drawableSize updates
     automatically without requiring an explicit Emacs resize event. */
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (fd)
    {
      NSView *view = FRAME_NS_VIEW (f);
      MtlResizeObserver *obs = [[MtlResizeObserver alloc] init];
      obs.layer      = fd.metalLayer;
      obs.emacsFrame = f;

      /* Observe 'frame' changes on the view (triggers on resize) */
      [view addObserver:obs forKeyPath:@"frame"
                 options:NSKeyValueObservingOptionNew context:NULL];

      /* Store observer as associated object to keep it alive and
         automatically remove it when the view is deallocated */
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
  gfx_free_frame_state (f);
  /* Metal data is stored as an associated object on EmacsView;
     it will be released when EmacsView is deallocated. */
  (void)f;
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
