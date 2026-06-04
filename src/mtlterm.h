/* Metal driver for the GNU Emacs GPU display backend (macOS).
   Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
*/

#ifndef EMACS_MTLTERM_H
#define EMACS_MTLTERM_H

#ifdef HAVE_MTL

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#include "dispextern.h"
#include "frame.h"
#include "font.h"
#include "sysselect.h"

#include "gfxdrv.h"

/* -----------------------------------------------------------------------
   Glyph atlas cache entry: the driver-side name for the neutral
   struct gfx_glyph (gfxdrv.h) the policy layer sees.
   ----------------------------------------------------------------------- */

typedef struct gfx_glyph MtlGlyphCacheEntry;

#define MTL_ATLAS_WIDTH  2048
#define MTL_ATLAS_HEIGHT 2048

/* -----------------------------------------------------------------------
   Phase 4: Animation types
   ----------------------------------------------------------------------- */

typedef NS_ENUM(NSUInteger, MtlCursorMode) {
  MTL_CURSOR_BLOCK    = 0,  /* Static filled rectangle */
  MTL_CURSOR_SPRING   = 1,  /* Critically-damped spring position */
  MTL_CURSOR_TORPEDO  = 2,  /* Trail of last N positions */
  MTL_CURSOR_SONICBOOM= 3,  /* Expanding ring on jump */
  MTL_CURSOR_RIPPLE   = 4,  /* 3 concentric expanding rings */
  MTL_CURSOR_PIXIEDUST= 5,  /* Radial particle burst */
  MTL_CURSOR_HOLLOW   = 6,  /* Hollow box (outline only) */
  MTL_CURSOR_BEAM     = 7,  /* Thin vertical bar */
};

typedef NS_ENUM(NSUInteger, MtlScrollEasing) {
  MTL_EASE_NONE        = 0,
  MTL_EASE_LINEAR      = 1,
  MTL_EASE_OUT_QUAD    = 2,  /* default */
  MTL_EASE_OUT_CUBIC   = 3,
  MTL_EASE_SPRING      = 4,
  MTL_EASE_IN_OUT_CUBIC= 5,
};

/* One trail particle (cursor trail / pixiedust) */
typedef struct mtl_particle {
  float x, y;          /* current position */
  float vx, vy;        /* velocity */
  float age;           /* 0.0 = just spawned, 1.0 = dead */
  float size;          /* diameter in pixels */
  unsigned long color; /* packed RRGGBB */
} MtlParticle;

#define MTL_MAX_PARTICLES 80
#define MTL_TRAIL_LEN     40

/* Spring state for one axis */
typedef struct mtl_spring {
  float pos;   /* current */
  float vel;   /* current velocity */
} MtlSpring1D;

/* -----------------------------------------------------------------------
   MtlAnimator — manages CADisplayLink + animation state per frame.
   Owns the intermediate static texture and the cursor/scroll animations.
   ----------------------------------------------------------------------- */

@class MtlFrameData;

@interface MtlAnimator : NSObject
{
@public
  /* Trail history (torpedo mode) — C arrays cannot be @property */
  float trailX[MTL_TRAIL_LEN];
  float trailY[MTL_TRAIL_LEN];
  /* Seconds since each trail sample was emitted; drives the smooth fade. */
  float trailAge[MTL_TRAIL_LEN];
  /* Particles (pixiedust, sonicboom, ripple) */
  MtlParticle particles[MTL_MAX_PARTICLES];
}

@property (nonatomic, assign) struct frame *emacsFrame;
@property (nonatomic, assign) MtlCursorMode   cursorMode;
@property (nonatomic, assign) MtlScrollEasing scrollEasing;

/* Cursor state */
@property (nonatomic, assign) float curTargetX, curTargetY;  /* Emacs target */
@property (nonatomic, assign) float curTargetW, curTargetH;
@property (nonatomic, assign) unsigned long cursorColor;     /* real frame cursor color */
@property (nonatomic, assign) MtlSpring1D springX, springY;  /* animated pos */
@property (nonatomic, assign) BOOL cursorDirty;

/* Trail history (torpedo mode) */
@property (nonatomic, assign) NSUInteger trailHead;
@property (nonatomic, assign) NSUInteger trailCount;

/* Particles (pixiedust, sonicboom, ripple) */
@property (nonatomic, assign) NSUInteger nParticles;

/* Scroll animation */
@property (nonatomic, assign) float scrollOffset;   /* current pixel offset */
@property (nonatomic, assign) float scrollTarget;   /* target offset (0 when done) */
@property (nonatomic, assign) float scrollVel;      /* for spring mode */
@property (nonatomic, assign) CFTimeInterval scrollStartTime;
@property (nonatomic, assign) float scrollDuration; /* seconds */

/* CADisplayLink (drives 60fps animation) */
@property (nonatomic, strong) CADisplayLink *displayLink;

- (instancetype)initWithFrame:(struct frame *)f;
- (void)startAnimating;
- (void)stopAnimating;

/* Called by mtl_draw_window_cursor to update target */
- (void)setCursorX:(int)x y:(int)y width:(int)w height:(int)h;

/* Called by mtl_scroll_run to start scroll animation */
- (void)beginScrollBy:(float)pixels;

/* Called every animation tick (CADisplayLink target) */
- (void)animationTick:(CADisplayLink *)link;

/* One animation step + composite, drivable from a Lisp timer (the display
   link starves while Emacs idles). */
- (void)tickWithDt:(float)dt;

/* Spawn particles at cursor for pixiedust/sonicboom/ripple modes */
- (void)spawnParticlesAtX:(float)x y:(float)y;

@end

/* -----------------------------------------------------------------------
   MtlVideoPlayer — inline video playback.
   AVPlayer decodes; AVPlayerItemVideoOutput hands BGRA pixel buffers that
   CVMetalTextureCache wraps as Metal textures with zero copies; the
   compositor draws the current frame as a textured quad over the static
   texture each present, and the animator's CADisplayLink keeps presents
   flowing while playback is active.
   ----------------------------------------------------------------------- */

@interface MtlVideoPlayer : NSObject
@property (nonatomic, strong) AVPlayer                 *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput  *output;
@property (nonatomic, assign) CVMetalTextureCacheRef    textureCache;
/* Keep the CoreVideo wrapper alive while its MTLTexture is in use. */
@property (nonatomic, assign) CVMetalTextureRef         currentCVTexture;
@property (nonatomic, strong) id<MTLTexture>            currentTexture;
@property (nonatomic, assign) NSRect                    rect;  /* logical px */
/* Window-interior clip (logical px); NSZeroRect = no clipping.  Keeps a
   half-scrolled video from bleeding over the mode line. */
@property (nonatomic, assign) NSRect                    clipRect;
@property (nonatomic, assign) BOOL                      loop;
/* NSNotificationCenter block token for loop mode (retained; this file is
   compiled without ARC, so raw ivar assignments would not retain). */
@property (nonatomic, strong) id                        endObserver;

- (instancetype)initWithURL:(NSURL *)url rect:(NSRect)rect loop:(BOOL)loop;
/* Latest decoded frame as a Metal texture (nil before the first frame). */
- (id<MTLTexture>)textureForNow;
- (BOOL)isPlaying;
- (void)shutdown;
@end

/* -----------------------------------------------------------------------
   MtlFrameData — per-frame Metal rendering state.
   Stored as ObjC associated object on EmacsView.
   ----------------------------------------------------------------------- */

@interface MtlFrameData : NSObject
/* Metal resources */
@property (nonatomic, strong) CAMetalLayer               *metalLayer;
@property (nonatomic, strong) id<MTLBuffer>               uniformBuffer;
@property (nonatomic, strong) id<MTLCommandBuffer>        cmdBuf;
@property (nonatomic, strong) id<MTLRenderCommandEncoder> encoder;
@property (nonatomic, strong) id<CAMetalDrawable>         drawable;
@property (nonatomic, assign) struct frame               *emacsFrame;

/* Phase 4: intermediate texture — Emacs renders here, animator blits to screen */
@property (nonatomic, strong) id<MTLTexture>              staticTexture;
/* Scratch texture for scroll_run: a region can't be blitted onto itself when
   source and destination overlap, so we bounce through this. */
@property (nonatomic, strong) id<MTLTexture>              scratchTexture;
@property (nonatomic, strong) id<MTLRenderPipelineState>  blitPipeline;

/* Phase 4: animator */
@property (nonatomic, strong) MtlAnimator                *animator;

/* F1: immediate draws (mouse-face highlight, etc.) commit to the static texture
   but defer presenting; this flag tells the policy's flush a present is pending
   so the whole clear+redraw sequence is shown in one go (no flicker).
   (Render-cycle POLICY state -- clear-only deferral, pending gutter clears,
   the expose substitute -- lives in gfxterm.c, not here.) */
@property (nonatomic, assign) BOOL                        needsPresent;

/* Active inline video (one per frame for now), drawn by
   compositeToScreen over the static texture. */
@property (nonatomic, strong) MtlVideoPlayer             *videoPlayer;

/* Main Emacs render cycle (renders to staticTexture) */
- (void)beginFrame;
- (void)endFrame;

/* Compositor render (called by animator: blit static + overlay animations) */
- (void)compositeToScreen;

/* Drawing helpers */
- (void)fillRect:(NSRect)rect color:(unsigned long)color;
- (void)drawGlyph:(MtlGlyphCacheEntry *)ge
               at:(CGPoint)origin
            color:(unsigned long)fgcolor;
@end

/* -----------------------------------------------------------------------
   MtlView — standalone NSView for test windows.
   ----------------------------------------------------------------------- */

@interface MtlView : NSView
{
@public
  struct frame *emacsframe;
}
@property (nonatomic, strong) CAMetalLayer               *metalLayer;
@property (nonatomic, strong) id<MTLBuffer>               uniformBuffer;
@property (nonatomic, strong) id<MTLCommandBuffer>        frameCommandBuffer;
@property (nonatomic, strong) id<MTLRenderCommandEncoder> frameEncoder;
@property (nonatomic, strong) id<CAMetalDrawable>         frameDrawable;

- (instancetype)initWithFrame:(NSRect)frame emacsFrame:(struct frame *)f;
- (void)setupMetal;
- (void)beginFrame;
- (void)endFrameAndPresent;
- (void)fillRect:(NSRect)rect withColor:(unsigned long)color;
- (void)drawText:(NSString *)text at:(NSPoint)pt
          ctfont:(CTFontRef)font color:(unsigned long)color;
@end

/* -----------------------------------------------------------------------
   MtlWindow
   ----------------------------------------------------------------------- */

@interface MtlWindow : NSWindow
{ @public struct frame *emacsframe; }
@end

/* -----------------------------------------------------------------------
   Per-display info
   ----------------------------------------------------------------------- */

struct mtl_display_info
{
  struct mtl_display_info *next;
  struct terminal          *terminal;
  Mouse_HLInfo              mouse_highlight;
  struct frame             *highlight_frame;
};

/* -----------------------------------------------------------------------
   Global cursor/scroll mode (Lisp-configurable)
   ----------------------------------------------------------------------- */

extern MtlCursorMode   g_mtl_cursor_mode;
extern MtlScrollEasing g_mtl_scroll_easing;
extern float           g_mtl_scroll_duration; /* seconds, default 0.15 */
extern NSUInteger      g_mtl_trail_len;        /* default 20 */
extern BOOL            g_mtl_animations_enabled; /* default NO (animations are opt-in) */

/* -----------------------------------------------------------------------
   Global Metal display list
   ----------------------------------------------------------------------- */

extern struct mtl_display_info *mtl_display_list;

/* -----------------------------------------------------------------------
   Public API
   ----------------------------------------------------------------------- */

extern struct mtl_display_info *mtl_term_init (Lisp_Object display_name);
extern void mtl_term_shutdown (struct terminal *terminal);
extern void mtl_free_frame_resources (struct frame *f);
extern void mtl_destroy_window (struct frame *f);
extern void mtl_default_font_parameter (struct frame *f, Lisp_Object parms);

extern MtlFrameData *mtl_setup_frame (struct frame *f);
extern MtlFrameData *mtl_get_frame_data (struct frame *f);

MtlGlyphCacheEntry *mtl_cache_glyph (CTFontRef font, uint32_t codepoint);

/* Pre-rasterize printable ASCII for FRAME's default face (atlas warm-up). */
extern void mtl_warm_glyph_cache (struct frame *f);

/* Inline video (one player per frame). */
extern bool mtl_video_open (struct frame *f, const char *path,
                            int x, int y, int w, int h, bool loop);
extern bool mtl_video_close (struct frame *f);
extern bool mtl_video_set_paused (struct frame *f, bool paused);
extern bool mtl_video_set_rect (struct frame *f, int x, int y, int w, int h);
extern bool mtl_video_set_clip (struct frame *f, int x, int y, int w, int h);
extern bool mtl_video_tick (struct frame *f);

extern bool mtl_render_offscreen_png (const char *path, int w, int h,
                                       void (^draw)(id<MTLRenderCommandEncoder>));
extern bool mtl_render_text_png (const char *path);
extern void mtl_patch_terminal_rif (struct frame *f);

/* Device/queue accessors for mtlfns.m (g_device and g_queue are file-static) */
extern id<MTLDevice>       mtl_get_device (void);
extern id<MTLCommandQueue> mtl_get_queue  (void);

/* Diagnostic counters for mtl_draw_glyph_string */
extern int mtl_dgs_call_count;
extern int mtl_dgs_nofd_count;
extern int mtl_dgs_nofont_count;
extern int mtl_dgs_drawn_count;

extern void syms_of_mtlfns (void);

#endif /* HAVE_MTL */
#endif /* EMACS_MTLTERM_H */
