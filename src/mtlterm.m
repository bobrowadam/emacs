/* Metal (GPU) backend for GNU Emacs on macOS — Phase 2: Text rendering.
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
   monitor with a different DPI).  See TODO.org Fase C-bis. */
static CGFloat           g_atlas_scale   = 1.0;

/* Phase 4: global animation configuration (Lisp-configurable) */
MtlCursorMode   g_mtl_cursor_mode    = MTL_CURSOR_SPRING;
MtlScrollEasing g_mtl_scroll_easing  = MTL_EASE_OUT_QUAD;
float           g_mtl_scroll_duration = 0.15f;
NSUInteger      g_mtl_trail_len       = 20;

/* Master switch for the GPU animation layer (cursor effects, particles,
   CADisplayLink @60fps).  OFF by default: the goal is pixel-correct parity
   with the NS backend first.  When off, the cursor is drawn directly into the
   static texture (like NS) and no compositor overlay is drawn.  See TODO.org
   Fase A.  Toggle from Lisp with (mtl-animations t). */
BOOL            g_mtl_animations_enabled = NO;

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
     layer is explicitly enabled (Fase A: correctness first, animation opt-in). */
  MtlAnimator *anim = [[MtlAnimator alloc] initWithFrame:f];
  fd.animator = anim;
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
  if (self.displayLink) return;
  self.displayLink = [NSScreen.mainScreen
    displayLinkWithTarget:self selector:@selector(animationTick:)];
  [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                         forMode:NSRunLoopCommonModes];
}

- (void)stopAnimating
{
  [self.displayLink invalidate];
  self.displayLink = nil;
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

  /* Spawn particles when cursor jumps significantly */
  float dx = fx - self.curTargetX, dy = fy - self.curTargetY;
  if ((fabsf(dx) > (float)w * 1.5f || fabsf(dy) > (float)h * 1.5f)
      && (self.cursorMode == MTL_CURSOR_PIXIEDUST
          || self.cursorMode == MTL_CURSOR_SONICBOOM
          || self.cursorMode == MTL_CURSOR_RIPPLE))
    [self spawnParticlesAtX:self.curTargetX + w/2 y:self.curTargetY + h/2];

  /* Add to trail history */
  if (self.cursorMode == MTL_CURSOR_TORPEDO
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
      p->color = 0x88C0D0; /* Nord frost */
    }
}

- (void)animationTick:(CADisplayLink *)link
{
  float dt = (float)link.duration;
  MtlFrameData *fd = mtl_get_frame_data (self.emacsFrame);
  if (!fd || !fd.metalLayer) return;

  BOOL needsComposite = NO;

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

  if (needsComposite || self.cursorDirty)
    {
      self.cursorDirty = NO;
      [fd compositeToScreen];
    }
}

@end

/* -----------------------------------------------------------------------
   @implementation MtlFrameData
   ----------------------------------------------------------------------- */

@interface MtlFrameData ()
- (void)openRenderEncoderClear:(BOOL)clear;
- (void)scrollRunFrom:(int)fromY to:(int)toY x:(int)x width:(int)w height:(int)h;
- (void)shiftGlyphsX:(int)x y:(int)y width:(int)w height:(int)h by:(int)shift;
- (void)drawFringeBits:(unsigned short *)bits dh:(int)dh wd:(int)wd h:(int)h
                   atX:(int)x y:(int)y color:(unsigned long)color;
@end

@implementation MtlFrameData

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

  /* D1: flush any scroll bar gutter rects queued by the scroll bar hooks during
     the layout phase (no encoder was active then).  Clear them to the frame
     background so stale text behind the transparent NSScroller is wiped.  A full
     clear (needsClear) already covers everything, so skip in that case. */
  if (!needsClear && self.pendingClears.count)
    {
      struct frame *f = self.emacsFrame;
      unsigned long bg = f ? ns_color_to_pixel (FRAME_BACKGROUND_COLOR (f)) : 0xFFFFFF;
      for (NSValue *v in self.pendingClears)
        [self fillRect:[v rectValue] color:bg];
    }
  [self.pendingClears removeAllObjects];
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
- (void)drawFringeBits:(unsigned short *)bits dh:(int)dh wd:(int)wd h:(int)h
                   atX:(int)x y:(int)y color:(unsigned long)color
{
  if (!self.encoder || !g_glyph_pipeline || !bits || wd <= 0 || h <= 0) return;
  if (wd > 32) wd = 32;

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
        /* MSB-first: leftmost pixel is the high bit of the wd-wide row. */
        if ((row >> (wd - 1 - c)) & 1)
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

/* Commit the static-texture draws.  When PRESENT is NO, only the static texture
   is updated and the on-screen present is deferred (needsPresent), so a sequence
   of immediate draws (clear_mouse_face + show_mouse_face) is shown in a single
   composite by flush_display instead of flickering through each step. */
- (void)endFramePresent:(BOOL)present
{
  if (!self.encoder) return;
  [self.encoder endEncoding];
  [self.cmdBuf commit];
  self.encoder = nil;
  self.cmdBuf  = nil;
  self.drawable = nil;
  if (present)
    [self compositeToScreen];
  else
    self.needsPresent = YES;
}

- (void)compositeToScreen
{
  if (!self.staticTexture || !g_blit_pipeline) return;

  id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
  if (!drawable) return;

  self.needsPresent = NO;   /* about to present whatever is in the static texture */

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

  id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
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

  /* Animation overlay (cursor effects, trail, particles) is opt-in.  When off,
     the cursor lives in the static texture (drawn by mtl_draw_window_cursor),
     so the compositor only blits and presents.  This is what kills the stray
     cyan cursor box drawn on top of text. */
  if (anim && g_mtl_animations_enabled)
    {
      float cx = anim.cursorMode == MTL_CURSOR_SPRING ? anim.springX.pos : anim.curTargetX;
      float cy = anim.cursorMode == MTL_CURSOR_SPRING ? anim.springY.pos : anim.curTargetY;
      float cw = anim.curTargetW, ch = anim.curTargetH;

      /* Real frame cursor color (fed by mtl_draw_window_cursor), not cyan. */
      float ccr, ccg, ccb;
      unpack_color (anim.cursorColor ? anim.cursorColor : 0x88C0D0, &ccr, &ccg, &ccb);

      /* 2. Torpedo trail */
      if (anim.cursorMode == MTL_CURSOR_TORPEDO && anim.trailCount > 0)
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

      /* 3. Cursor (spring-interpolated position) */
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
  [cmd commit];
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

  /* Cache lookup: key is the struct image* pointer directly.
     CFDictionary with NULL key callbacks uses pointer equality — correct and fast.
     img->pixmap can change (image reload), so we also check img->id matches. */
  id<MTLTexture> tex = (__bridge id<MTLTexture>)
    CFDictionaryGetValue (g_image_texture_cache, (const void *)img);
  if (tex) return tex;

  /* Get NSImage from Emacs image (NS backend stores EmacsImage* in pixmap) */
  if (!img->pixmap) return nil;
  NSImage *nsimg = (__bridge NSImage *)img->pixmap;
  if (![nsimg isKindOfClass:[NSImage class]]) return nil;

  NSSize sz = [nsimg size];
  if (sz.width < 1 || sz.height < 1) return nil;

  NSUInteger w = (NSUInteger)ceil (sz.width);
  NSUInteger h = (NSUInteger)ceil (sz.height);

  /* Render NSImage to a BGRA8 bitmap via CGContext */
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB ();
  size_t bpr    = w * 4;
  uint8_t *px   = (uint8_t *)calloc (1, bpr * h);
  CGContextRef ctx = CGBitmapContextCreate (px, w, h, 8, bpr, cs,
    (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
  CGColorSpaceRelease (cs);
  if (!ctx) { free (px); return nil; }

  /* No CTM flip: drawing the image upright into a CGBitmapContext already puts
     the visual top of the image in the first memory row, which is exactly what
     Metal's texture row 0 (V=0, the top of the quad) expects.  Flipping here
     would invert the lone orientation and render the image upside down. */
  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx
                                                                  flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:gc];
  [nsimg drawInRect:NSMakeRect (0, 0, (CGFloat)w, (CGFloat)h)];
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

/* Render a Metal RGBA texture as a quad at (x,y,w,h) into fd.encoder */
static void
mtl_draw_image_texture (MtlFrameData *fd, id<MTLTexture> tex,
                         float x, float y, float w, float h, float alpha)
{
  if (!fd.encoder || !g_image_pipeline || !tex) return;

  typedef struct { float x, y, u, v, a; } ImgVert;
  float x1 = x+w, y1 = y+h;
  ImgVert verts[6] = {
    {x, y,  0,0,alpha}, {x1,y,  1,0,alpha}, {x, y1, 0,1,alpha},
    {x1,y,  1,0,alpha}, {x1,y1, 1,1,alpha}, {x, y1, 0,1,alpha},
  };
  [fd.encoder setRenderPipelineState:g_image_pipeline];
  [fd.encoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
  [fd.encoder setVertexBuffer:fd.uniformBuffer offset:0 atIndex:1];
  [fd.encoder setFragmentTexture:tex atIndex:0];
  [fd.encoder setFragmentSamplerState:g_sampler atIndex:0];
  [fd.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

/* -----------------------------------------------------------------------
   redisplay_interface — all file-static, called by xdisp.c engine
   ----------------------------------------------------------------------- */

int mtl_dgs_call_count   = 0;  /* total calls */
int mtl_dgs_nofd_count   = 0;  /* no fd or encoder */
int mtl_dgs_nofont_count = 0;  /* no ctfont */
int mtl_dgs_drawn_count  = 0;  /* glyphs actually drawn */

/* Lighten (toward white) or darken (toward black) COLOR by LEVEL [0,1].
   Matches NSColor highlightWithLevel:/shadowWithLevel: closely enough for the
   relief shadows. */
static unsigned long
mtl_shade_color (unsigned long c, double level, bool lighten)
{
  double r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
  if (lighten) { r += (255 - r) * level; g += (255 - g) * level; b += (255 - b) * level; }
  else         { r *= (1.0 - level);     g *= (1.0 - level);     b *= (1.0 - level); }
  return ((unsigned long) r << 16) | ((unsigned long) g << 8) | (unsigned long) b;
}

/* Draw the face box / relief around glyph string S (mode line, buttons, etc.).
   Ports ns_dumpglyphs_box_or_relief + ns_draw_box/ns_draw_relief with simple
   rectangle edges (good enough for the typical 1px relief). */
static void
mtl_draw_glyph_string_box (struct glyph_string *s, MtlFrameData *fd)
{
  struct face *face = s->face;
  if (!face || face->box == FACE_NO_BOX) return;

  int hth = abs (face->box_horizontal_line_width);
  int vth = abs (face->box_vertical_line_width);
  if (hth == 0 && vth == 0) return;

  struct glyph *last_glyph = s->first_glyph + s->nchars - 1;
  int last_x = (s->row->full_width_p && !s->w->pseudo_window_p)
               ? WINDOW_RIGHT_EDGE_X (s->w)
               : window_box_right (s->w, s->area);
  int right_x = (s->row->full_width_p && s->extends_to_end_of_line_p
                 ? last_x - 1
                 : min (last_x, s->x + s->background_width) - 1);
  bool left_p  = s->first_glyph->left_box_line_p;
  bool right_p = last_glyph->right_box_line_p;

  int x = s->x, y = s->y, w = right_x - s->x + 1, h = s->height;
  if (w <= 0 || h <= 0) return;

  unsigned long tl, br;   /* top/left and bottom/right edge colors */
  if (face->box == FACE_SIMPLE_BOX)
    tl = br = face->box_color;
  else
    {
      unsigned long base = face->use_box_color_for_shadows_p
                           ? face->box_color : face->background;
      if (s->hl == DRAW_CURSOR)
        base = ns_color_to_pixel (FRAME_CURSOR_COLOR (s->f));
      /* Use the same NSColor highlight/shadow used by ns_setup_relief_colors:
         these are appearance-dynamic (dark mode shifts the highlight), so a
         plain blend toward pure white/black does not match what NS renders
         (e.g. the mode-line top edge: NS ~177 vs blend-to-white 211). */
      NSColor *bc = [NSColor colorWithUnsignedLong:base];
      NSColor *lc = [bc highlightWithLevel:0.4];
      NSColor *dc = [bc shadowWithLevel:0.4];
      unsigned long light = lc ? ns_color_to_pixel (lc)
                               : mtl_shade_color (base, 0.4, true);
      unsigned long dark  = dc ? ns_color_to_pixel (dc)
                               : mtl_shade_color (base, 0.4, false);
      bool raised = (face->box == FACE_RAISED_BOX);
      tl = raised ? light : dark;
      br = raised ? dark  : light;
    }

  [fd fillRect:NSMakeRect (x, y, w, hth) color:tl];                 /* top */
  [fd fillRect:NSMakeRect (x, y + h - hth, w, hth) color:br];       /* bottom */
  if (left_p)
    [fd fillRect:NSMakeRect (x, y, vth, h) color:tl];               /* left */
  if (right_p)
    [fd fillRect:NSMakeRect (x + w - vth, y, vth, h) color:br];     /* right */
}

/* Compute the underline offset below the baseline and its thickness, mirroring
   ns_draw_text_decoration.  These depend on font metrics; the glyph string's
   underline_position/underline_thickness are otherwise left uninitialized, so
   the underline was being drawn at the baseline (offset 0), cutting through the
   bottom of the glyphs.  Honors the face's descent-line options and uses the
   default underline-minimum-offset (1) and x-use-underline-position-properties
   (t). */
static void
mtl_underline_metrics (struct glyph_string *s, int *position, int *thickness)
{
  /* Match a previous underlined run so a continued underline stays seamless. */
  if (s->prev
      && s->prev->face->underline != FACE_UNDERLINE_WAVE
      && s->prev->face->underline >= FACE_UNDERLINE_SINGLE
      && s->prev->underline_thickness > 0
      && (s->prev->face->underline_at_descent_line_p
          == s->face->underline_at_descent_line_p)
      && (s->prev->face->underline_pixels_above_descent_line
          == s->face->underline_pixels_above_descent_line))
    {
      *thickness = s->prev->underline_thickness;
      *position  = s->prev->underline_position;
      return;
    }

  struct font *font = font_for_underline_metrics (s);
  int descent = s->y + s->height - s->ybase;
  int minimum_offset = 1;
  int th = (font && font->underline_thickness > 0) ? font->underline_thickness : 1;
  int pos;

  if (s->face->underline_at_descent_line_p)
    pos = descent - th - s->face->underline_pixels_above_descent_line;
  else if (font && font->underline_position >= 0)
    pos = font->underline_position;
  else if (font)
    pos = lround (font->descent / 2.0);
  else
    pos = minimum_offset;

  if (!s->face->underline_pixels_above_descent_line)
    pos = max (pos, minimum_offset);

  /* Keep the underline inside the cell. */
  if (descent <= pos)        { pos = descent - 1; th = 1; }
  else if (descent < pos + th) th = 1;

  *position = pos;
  *thickness = th;
}

static void
mtl_draw_glyph_string_impl (struct glyph_string *s)
{
  mtl_dgs_call_count++;

  struct frame *f = s->f;
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.encoder) { mtl_dgs_nofd_count++; return; }

  struct face *face = s->face;
  unsigned long fg = face ? face->foreground : 0x000000;
  unsigned long bg = face ? face->background : 0xFFFFFF;

  /* When this string is drawn as the cursor (via draw_phys_cursor_glyph),
     invert: fill the background with the cursor color and draw the glyph in
     the face's background color so the character stays readable.  Mirrors the
     NS backend (FRAME_CURSOR_COLOR + FRAME_BACKGROUND for text). */
  if (s->hl == DRAW_CURSOR)
    {
      bg = ns_color_to_pixel (FRAME_CURSOR_COLOR (f));
      fg = face ? face->background : 0xFFFFFF;
    }

  /* Background fill.  Inset vertically by the box line width, exactly like the
     NS backend (ns_maybe_dumpglyphs_background): for a boxed face (e.g. the
     selected tab-bar tab) this leaves the box edge rows untouched so the relief
     drawn afterwards is not overwritten and then redrawn.  For unboxed faces
     box_line_width is 0, so this is identical to filling the full height. */
  if (!s->background_filled_p)
    {
      int blw = face ? max (face->box_horizontal_line_width, 0) : 0;
      NSRect bgr = NSMakeRect (s->x, s->y + blw,
                                s->background_width, s->height - 2 * blw);
      [fd fillRect:bgr color:bg];
      s->background_filled_p = true;
    }

  if (!s->first_glyph) return;

  /* Phase 5: render inline images via Metal RGBA pipeline */
  if (s->first_glyph->type == IMAGE_GLYPH)
    {
      struct image *img = s->img;
      if (img)
        {
          id<MTLTexture> tex = mtl_texture_for_image (img);
          if (tex)
            {
              int x = s->x + s->img->hmargin;
              int y = s->ybase - image_ascent (img, s->face, &s->slice)
                      + s->img->vmargin;
              mtl_draw_image_texture (fd, tex,
                                      (float)x, (float)y,
                                      (float)s->slice.width,
                                      (float)s->slice.height,
                                      1.0f);
            }
        }
      return;
    }

  /* Skip stretch glyphs (background already filled) */
  if (s->first_glyph->type == STRETCH_GLYPH) return;

  /* Get CoreText font */
  CTFontRef ctfont = mtl_ctfont_for_face (face);
  if (!ctfont) { mtl_dgs_nofont_count++; return; }


  /* Advance using Emacs's own integer glyph grid (first_glyph[i].pixel_width),
     NOT the CoreText float advance.  Re-advancing by the font's fractional
     advance drifts away from the layout Emacs computed: glyphs land at
     fractional positions (linear sampling blurs them) and progressively
     overlap/clip across the line.  Keeping integer pen positions also makes the
     1:1 blit pixel-crisp. */
  int pen_x = s->x;
  int baseline_y = s->ybase;

  for (int i = 0; i < s->nchars; i++)
    {
      /* char2b contains GLYPH IDs for the macfont backend — NOT Unicode codepoints.
         Use mtl_cache_glyph_id which calls CoreText with the ID directly. */
      CGGlyph glyphId = s->char2b ? (CGGlyph)s->char2b[i] : 0;
      int adv = (i < s->nchars) ? s->first_glyph[i].pixel_width
                                : FRAME_COLUMN_WIDTH (f);

      if (glyphId)
        {
          MtlGlyphCacheEntry *ge = mtl_cache_glyph_id (ctfont, glyphId);
          if (ge && ge->width > 0)
            {
              mtl_dgs_drawn_count++;
              /* bearing_y: distance from glyph top-left to baseline.
                 In our top-left coord system, glyph top = baseline_y - bearing_y. */
              [fd drawGlyph:ge at:CGPointMake ((float)pen_x, (float)baseline_y)
                      color:fg];
            }
        }

      pen_x += adv;
    }

  /* Underline.  Wave FIRST: FACE_UNDERLINE_WAVE is above FACE_UNDERLINE_SINGLE
     in the enum, so the >= SINGLE branch would otherwise swallow it (NS checks
     wave first too). */
  if (face && face->underline == FACE_UNDERLINE_WAVE)
    {
      /* Zigzag wave matching ns_draw_underwave: wave_height 3, wave_length 2,
         drawn at ybase..ybase+2 (y = ybase - wave_height + 3).  One 1px cell
         per column following the triangle pattern 0,1,2,1; indexing by the
         absolute column keeps the wave continuous across adjacent strings,
         like NS's a.x = x - (x % dx) phase anchoring. */
      unsigned long uc = face->underline_defaulted_p ? fg : face->underline_color;
      static const int wave[4] = {0, 1, 2, 1};
      int wy = s->ybase;
      for (int cx = s->x; cx < s->x + s->width; cx++)
        [fd fillRect:NSMakeRect (cx, wy + wave[cx & 3], 1, 1) color:uc];
    }
  else if (face && face->underline >= FACE_UNDERLINE_SINGLE)
    {
      int position, thickness;
      mtl_underline_metrics (s, &position, &thickness);
      s->underline_thickness = thickness;
      s->underline_position  = position;
      unsigned long uc = face->underline_defaulted_p ? fg : face->underline_color;
      [fd fillRect:NSMakeRect (s->x, s->ybase + position, s->width, thickness)
             color:uc];
      /* Second line above the first for double underline. */
      if (face->underline == FACE_UNDERLINE_DOUBLE_LINE)
        {
          int p2 = position - thickness - 1;
          [fd fillRect:NSMakeRect (s->x, s->ybase + p2, s->width, thickness)
                 color:uc];
        }
    }

  /* Overline: 1px at the top of the string (NS ignores overline_margin too). */
  if (face && face->overline_p)
    {
      unsigned long oc = face->overline_color_defaulted_p
        ? fg : face->overline_color;
      [fd fillRect:NSMakeRect (s->x, s->y, s->width, 1) color:oc];
    }

  /* Strike-through: a 1px line centered on the first glyph's body, like NS.
     Using s->y/s->height would mis-center it when the row is taller than this
     string (e.g. a bigger font elsewhere on the line). */
  if (face && face->strike_through_p)
    {
      int glyph_y = s->ybase - s->first_glyph->ascent;
      int glyph_height = s->first_glyph->ascent + s->first_glyph->descent;
      int dy = lrint ((glyph_height - 1) / 2.0);
      unsigned long sc = face->strike_through_color_defaulted_p
        ? fg : face->strike_through_color;
      [fd fillRect:NSMakeRect (s->x, glyph_y + dy, s->width, 1) color:sc];
    }

  /* Face box / 3D relief (mode line, buttons, etc.). */
  if (face && face->box != FACE_NO_BOX)
    mtl_draw_glyph_string_box (s, fd);
}

/* The redisplay engine also draws OUTSIDE the update_begin/end cycle: mouse-face
   highlight (note_mouse_highlight → show_mouse_face) and other immediate draws
   call draw_glyph_string directly, with no Metal render encoder active.  The NS
   backend draws immediately via lockFocus; we must open a self-contained frame
   (LOAD preserves the static texture), draw, then present.  Without this the
   mouse-face highlight never appeared (the draw was silently dropped). */
static void
mtl_draw_glyph_string (struct glyph_string *s)
{
  MtlFrameData *fd = mtl_get_frame_data (s->f);
  if (!fd) return;

  /* If we are outside the normal update_begin/end cycle (mouse-face highlight
     and other immediate draws), wrap this one string in its own frame: open,
     draw, and COMMIT to the static texture, but DEFER the on-screen present.
     Presenting on every immediate draw flickered (a mouse move runs
     clear_mouse_face + show_mouse_face = several draws, each flashing the
     intermediate state); leaving the encoder open across draws instead made the
     state leak into the next click/redisplay.  Committing per draw keeps the
     pipeline clean, and deferring the present lets mtl_flush_display show the
     whole sequence in one composite. */
  if (fd.encoder)
    {
      mtl_draw_glyph_string_impl (s);
    }
  else
    {
      [fd beginFrame];
      mtl_draw_glyph_string_impl (s);
      [fd endFramePresent:NO];
    }
}

static void
mtl_clear_frame (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  NSRect bounds = fd.metalLayer ? CGRectMake (0, 0,
                    fd.metalLayer.frame.size.width,
                    fd.metalLayer.frame.size.height) : NSZeroRect;
  [fd fillRect:bounds color:ns_color_to_pixel (FRAME_BACKGROUND_COLOR (f))];
}

static void
mtl_clear_frame_area (struct frame *f, int x, int y, int width, int height)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  [fd fillRect:NSMakeRect (x, y, width, height)
         color:ns_color_to_pixel (FRAME_BACKGROUND_COLOR (f))];
}

static void
mtl_clear_under_internal_border (struct frame *f)
{
  int b = FRAME_INTERNAL_BORDER_WIDTH (f);
  if (b <= 0) return;
  int w = FRAME_PIXEL_WIDTH (f), h = FRAME_PIXEL_HEIGHT (f);
  mtl_clear_frame_area (f, 0, 0,     w,  b);
  mtl_clear_frame_area (f, 0, h-b,   w,  b);
  mtl_clear_frame_area (f, 0, 0,     b,  h);
  mtl_clear_frame_area (f, w-b, 0,   b,  h);
}

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
mtl_queue_clear (struct frame *f, int x, int y, int w, int h)
{
  if (w <= 0 || h <= 0) return;
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  if (!fd.pendingClears) fd.pendingClears = [NSMutableArray array];
  [fd.pendingClears addObject:[NSValue valueWithRect:NSMakeRect (x, y, w, h)]];
}

static void
mtl_set_vertical_scroll_bar (struct window *window,
                             int portion, int whole, int position)
{
  struct frame *f = XFRAME (WINDOW_FRAME (window));
  int window_y, window_height;
  window_box (window, ANY_AREA, 0, &window_y, 0, &window_height);
  mtl_queue_clear (f, WINDOW_SCROLL_BAR_AREA_X (window), window_y,
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
  mtl_queue_clear (f, window_x, WINDOW_SCROLL_BAR_AREA_Y (window),
                   window_width, WINDOW_SCROLL_BAR_AREA_HEIGHT (window));

  if (mtl_orig_set_hsb_hook)
    mtl_orig_set_hsb_hook (window, portion, whole, position);
}

static void
mtl_flush_display (struct frame *f)
{
  /* Present the current Metal frame if one is in progress.
     Do NOT start a new frame here — that is update_begin's responsibility.
     The bug in Phase 2 was calling beginFrame here, which left an orphaned
     encoder that never got endEncoding, causing an assertion failure. */
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  if (fd.encoder)
    [fd endFrame];
  else if (fd.needsPresent)
    /* Present the deferred immediate draws (mouse-face highlight, etc.) that
       were committed to the static texture without presenting. */
    [fd compositeToScreen];
}

static void
mtl_update_begin (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  /* Guard: if encoder already active (e.g. from a re-entrant redisplay),
     end it cleanly before starting a new frame. */
  if (fd.encoder) [fd endFrame];
  [fd beginFrame];
}

static void
mtl_update_end (struct frame *f)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (fd) [fd endFrame];
}

static void
mtl_frame_up_to_date (struct frame *f)
{
  /* Called when the frame display is fully up to date.
     In the NS backend this handles cursor blinking via update_begin/end.
     For Metal, we just ensure the latest frame is presented. */
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  /* If a frame was begun but not ended (unusual), end it now. */
  if (fd.encoder) [fd endFrame];
}

static void
mtl_scroll_run (struct window *w, struct run *run)
{
  struct frame *f = WINDOW_XFRAME (w);
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;

  /* Move the already-rendered block of pixels inside the static texture, the
     same geometry the NS backend uses (ns_scroll_run): the text area box of W
     including fringes, clamped so we never copy over the mode line. */
  int x, y, width, height, from_y, to_y, bottom_y;
  window_box (w, ANY_AREA, &x, &y, &width, &height);
  from_y = WINDOW_TO_FRAME_PIXEL_Y (w, run->current_y);
  to_y   = WINDOW_TO_FRAME_PIXEL_Y (w, run->desired_y);
  bottom_y = y + height;

  if (to_y < from_y)
    height = (from_y + run->height > bottom_y) ? bottom_y - from_y : run->height;
  else
    height = (to_y + run->height > bottom_y) ? bottom_y - to_y : run->height;

  if (height <= 0) return;

  [fd scrollRunFrom:from_y to:to_y x:x width:width height:height];
}

static void
mtl_after_update_window_line (struct window *w,
                               struct glyph_row *desired_row)
{
  (void)w; (void)desired_row;
}

static void
mtl_draw_window_cursor (struct window *w,
                         struct glyph_row *row, int x, int y,
                         enum text_cursor_kinds cursor_type,
                         int cursor_width, bool on_p, bool active_p)
{
  (void)x; (void)y; (void)active_p;

  struct frame *f = WINDOW_XFRAME (w);
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  if (!on_p) return;

  w->phys_cursor_type = cursor_type;
  w->phys_cursor_on_p = on_p;

  if (cursor_type == NO_CURSOR)
    {
      w->phys_cursor_width = 0;
      return;
    }

  /* Resolve the glyph and geometry exactly like the NS backend so the cursor
     box lines up with the character cell.  See ns_draw_window_cursor. */
  struct glyph *phys_cursor_glyph = get_phys_cursor_glyph (w);
  if (phys_cursor_glyph == NULL)
    {
      if (row->exact_window_width_line_p
          && w->phys_cursor.hpos >= row->used[TEXT_AREA])
        {
          row->cursor_in_fringe_p = 1;
          draw_fringe_bitmap (w, row, 0);
        }
      return;
    }

  int fx, fy, h, cursor_height;
  get_phys_cursor_geometry (w, row, phys_cursor_glyph, &fx, &fy, &h);

  if (cursor_type == BAR_CURSOR)
    {
      struct glyph *cursor_glyph;
      if (cursor_width < 1)
        cursor_width = max (FRAME_CURSOR_WIDTH (f), 1);
      if (cursor_width < w->phys_cursor_width)
        w->phys_cursor_width = cursor_width;
      /* For R2L glyphs draw the bar on the right edge. */
      cursor_glyph = get_phys_cursor_glyph (w);
      if ((cursor_glyph->resolved_level & 1) != 0)
        fx += cursor_glyph->pixel_width - w->phys_cursor_width;
    }
  else if (cursor_type == HBAR_CURSOR)
    {
      cursor_height = (cursor_width < 1) ? lrint (0.25 * h) : cursor_width;
      if (cursor_height > row->height)
        cursor_height = row->height;
      if (h > cursor_height)
        fy += h - cursor_height;
      h = cursor_height;
    }

  unsigned long cc = ns_color_to_pixel (FRAME_CURSOR_COLOR (f));
  int cwidth = w->phys_cursor_width;

  /* With the animation layer OFF, draw the cursor straight into the static
     texture (like NS).  With it ON, the compositor draws the animated cursor on
     top, so skip the static one here to avoid a double cursor. */
  if (!g_mtl_animations_enabled)
    switch (cursor_type)
      {
      case DEFAULT_CURSOR:
      case NO_CURSOR:
        break;
      case FILLED_BOX_CURSOR:
        /* Re-draw the glyph with DRAW_CURSOR highlight: fills the cell with the
           cursor color and draws the character in the background color, keeping
           it readable (mtl_draw_glyph_string handles DRAW_CURSOR). */
        draw_phys_cursor_glyph (w, row, DRAW_CURSOR);
        break;
      case HOLLOW_BOX_CURSOR:
        /* Outline only: four 1px edges. */
        [fd fillRect:NSMakeRect (fx, fy, cwidth, 1)         color:cc];
        [fd fillRect:NSMakeRect (fx, fy + h - 1, cwidth, 1) color:cc];
        [fd fillRect:NSMakeRect (fx, fy, 1, h)              color:cc];
        [fd fillRect:NSMakeRect (fx + cwidth - 1, fy, 1, h) color:cc];
        break;
      case HBAR_CURSOR:
      case BAR_CURSOR:
        [fd fillRect:NSMakeRect (fx, fy, cwidth, h) color:cc];
        break;
      }

  /* Feed the animator the target position and the real cursor color so the
     compositor can draw the animated cursor (no hardcoded cyan). */
  if (g_mtl_animations_enabled && fd.animator)
    {
      fd.animator.cursorColor = cc;
      [fd.animator setCursorX:fx y:fy width:cwidth height:h];
    }
}

static void
mtl_draw_vertical_window_border (struct window *w, int x, int y0, int y1)
{
  struct frame *f = WINDOW_XFRAME (w);
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  struct face *face = FACE_FROM_ID_OR_NULL (f, VERTICAL_BORDER_FACE_ID);
  unsigned long color = face ? face->foreground
                             : ns_color_to_pixel (FRAME_FOREGROUND_COLOR (f));
  [fd fillRect:NSMakeRect (x, y0, 1, y1 - y0) color:color];
}

static void
mtl_draw_window_divider (struct window *w,
                          int x0, int x1, int y0, int y1)
{
  struct frame *f = WINDOW_XFRAME (w);
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;

  struct face *face = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_FACE_ID);
  struct face *face_first = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_FIRST_PIXEL_FACE_ID);
  struct face *face_last = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_LAST_PIXEL_FACE_ID);
  unsigned long fg = ns_color_to_pixel (FRAME_FOREGROUND_COLOR (f));
  unsigned long color       = face ? face->foreground : fg;
  unsigned long color_first = face_first ? face_first->foreground : fg;
  unsigned long color_last  = face_last ? face_last->foreground : fg;

  if ((y1 - y0 > x1 - x0) && (x1 - x0 >= 3))
    {
      /* Vertical divider >= 3px wide: distinct first/last columns. */
      [fd fillRect:NSMakeRect (x0, y0, 1, y1 - y0)             color:color_first];
      [fd fillRect:NSMakeRect (x0 + 1, y0, x1 - x0 - 2, y1 - y0) color:color];
      [fd fillRect:NSMakeRect (x1 - 1, y0, 1, y1 - y0)         color:color_last];
    }
  else if ((x1 - x0 > y1 - y0) && (y1 - y0 >= 3))
    {
      /* Horizontal divider >= 3px high: distinct first/last rows. */
      [fd fillRect:NSMakeRect (x0, y0, x1 - x0, 1)             color:color_first];
      [fd fillRect:NSMakeRect (x0, y0 + 1, x1 - x0, y1 - y0 - 2) color:color];
      [fd fillRect:NSMakeRect (x0, y1 - 1, x1 - x0, 1)         color:color_last];
    }
  else
    [fd fillRect:NSMakeRect (x0, y0, x1 - x0, y1 - y0) color:color];
}

static void mtl_draw_fringe_bitmap (struct window *w,
  struct glyph_row *row, struct draw_fringe_bitmap_params *p)
{
  (void)row;
  struct frame *f = WINDOW_XFRAME (w);
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.encoder) return;

  struct face *face = p->face;
  unsigned long bg = face ? face->background
                          : ns_color_to_pixel (FRAME_BACKGROUND_COLOR (f));

  /* Clear the fringe background (and the wider bx area) unless this is an
     overlay bitmap.  Mirrors ns_draw_fringe_bitmap. */
  if (!p->overlay_p)
    {
      if (p->bx >= 0)
        [fd fillRect:NSMakeRect (p->bx, p->by, p->nx, p->ny) color:bg];
      [fd fillRect:NSMakeRect (p->x, p->y, p->wd, p->h) color:bg];
    }

  if (!p->bits || p->wd <= 0 || p->h <= 0)
    return;

  unsigned long color;
  if (!p->cursor_p)
    color = face ? face->foreground : ns_color_to_pixel (FRAME_FOREGROUND_COLOR (f));
  else if (p->overlay_p)
    color = bg;
  else
    color = ns_color_to_pixel (FRAME_CURSOR_COLOR (f));

  [fd drawFringeBits:p->bits dh:p->dh wd:p->wd h:p->h
                 atX:p->x y:p->y color:color];
}

static void mtl_define_fringe_bitmap (int w, unsigned short *b, int h, int wd)
{ (void)w; (void)b; (void)h; (void)wd; }

static void mtl_destroy_fringe_bitmap (int w) { (void)w; }

static void
mtl_compute_glyph_string_overhangs (struct glyph_string *s)
{ s->left_overhang = s->right_overhang = 0; }

static void
mtl_define_frame_cursor (struct frame *f, Emacs_Cursor c)
{ (void)f; (void)c; }

static void
mtl_shift_glyphs_for_insert (struct frame *f, int x, int y,
                               int w, int h, int by)
{
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd) return;
  [fd shiftGlyphsX:x y:y width:w height:h by:by];
}

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
  mtl_scroll_run,
  mtl_after_update_window_line,
  NULL,    /* update_window_begin */
  NULL,    /* update_window_end   */
  mtl_flush_display,
  gui_clear_window_mouse_face,
  gui_get_glyph_overhangs,
  gui_fix_overlapping_area,
  mtl_draw_fringe_bitmap,
  mtl_define_fringe_bitmap,
  mtl_destroy_fringe_bitmap,
  mtl_compute_glyph_string_overhangs,
  mtl_draw_glyph_string,
  mtl_define_frame_cursor,
  mtl_clear_frame_area,
  mtl_clear_under_internal_border,
  mtl_draw_window_cursor,
  mtl_draw_vertical_window_border,
  mtl_draw_window_divider,
  mtl_shift_glyphs_for_insert,
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

  /* Notify Emacs that the frame pixel size changed */
  if (self.emacsFrame)
    {
      FRAME_PIXEL_WIDTH  (self.emacsFrame) = (int)sz.width;
      FRAME_PIXEL_HEIGHT (self.emacsFrame) = (int)sz.height;
      SET_FRAME_GARBAGED (self.emacsFrame);
    }
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
      mtl_ns_rif_copy = xmalloc (sizeof (struct redisplay_interface));
      *mtl_ns_rif_copy = *term->rif;  /* copy all NS functions as baseline */

      /* Override only the functions that perform pixel drawing.
         Everything else (frame_parm_handlers, produce_glyphs, etc.)
         stays as the NS implementation — frame management must work. */
      mtl_ns_rif_copy->scroll_run_hook               = mtl_scroll_run;
      mtl_ns_rif_copy->after_update_window_line_hook  = mtl_after_update_window_line;
      mtl_ns_rif_copy->flush_display                 = mtl_flush_display;
      mtl_ns_rif_copy->draw_fringe_bitmap            = mtl_draw_fringe_bitmap;
      mtl_ns_rif_copy->define_fringe_bitmap          = mtl_define_fringe_bitmap;
      mtl_ns_rif_copy->destroy_fringe_bitmap         = mtl_destroy_fringe_bitmap;
      mtl_ns_rif_copy->compute_glyph_string_overhangs= mtl_compute_glyph_string_overhangs;
      mtl_ns_rif_copy->draw_glyph_string             = mtl_draw_glyph_string;
      mtl_ns_rif_copy->clear_frame_area              = mtl_clear_frame_area;
      mtl_ns_rif_copy->clear_under_internal_border   = mtl_clear_under_internal_border;
      mtl_ns_rif_copy->draw_window_cursor            = mtl_draw_window_cursor;
      mtl_ns_rif_copy->draw_vertical_window_border   = mtl_draw_vertical_window_border;
      mtl_ns_rif_copy->draw_window_divider           = mtl_draw_window_divider;
      mtl_ns_rif_copy->shift_glyphs_for_insert       = mtl_shift_glyphs_for_insert;
      /* show_hourglass, hide_hourglass, default_font_parameter: keep NS versions */
    }

  term->rif = mtl_ns_rif_copy;

  /* Patch render cycle hooks so Metal manages the frame pixel lifecycle.
     The NS backend's update_begin calls [view lockFocus] for CoreGraphics;
     we bypass that entirely and use Metal command buffers instead. */
  term->update_begin_hook     = mtl_update_begin;
  term->update_end_hook       = mtl_update_end;
  term->clear_frame_hook      = mtl_clear_frame;
  term->frame_up_to_date_hook = mtl_frame_up_to_date;

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
      mtl_draw_string_enc (enc, bf14, "emacs-gl: Metal GPU Backend",
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
  t->clear_frame_hook      = mtl_clear_frame;
  t->ring_bell_hook        = mtl_ring_bell;
  t->update_begin_hook     = mtl_update_begin;
  t->update_end_hook       = mtl_update_end;
  t->read_socket_hook      = mtl_read_socket;
  t->frame_up_to_date_hook = mtl_frame_up_to_date;
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
