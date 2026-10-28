"""Exercise the renderer's font retention under manual Objective-C ownership."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires macOS CoreText")
class GlyphFontOwnershipTest(unittest.TestCase):
    def test_equal_fonts_retain_each_identity_until_cache_reset(self):
        clang = shutil.which("clang")
        if not clang:
            self.skipTest("Clang is required for the font ownership regression")
        source = (Path(__file__).resolve().parents[2] / "src/mtlterm.m").read_text()
        # Compile the actual cache declarations and retention statements, not
        # a second implementation of their collection and ownership settings.
        fragments = []
        for name in ("g_glyph_fonts", "g_color_glyph_fonts"):
            declaration = re.search(r"static \w+ \*" + name + r";", source)
            retention = re.search(
                r"if \(!" + name + r"\).*?\[" + name + r" addObject:.*?;",
                source, re.DOTALL)
            self.assertIsNotNone(declaration)
            self.assertIsNotNone(retention)
            fragments.append(declaration.group() + "\n"
                             + "static void keep_" + name + "(id font) {\n"
                             + retention.group() + "\n}\n")
        harness = r'''
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>

static int destroyed;
@interface EqualToken : NSObject
@end
@implementation EqualToken
- (BOOL)isEqual:(id)other { return [other isKindOfClass:[EqualToken class]]; }
- (NSUInteger)hash { return 1; }
- (void)dealloc { destroyed++; [super dealloc]; }
@end

static void check(id fonts, void (*keep)(id))
{
  CTFontRef first = CTFontCreateWithName(CFSTR("Menlo"), 16, NULL);
  CGFontRef graphics = CTFontCopyGraphicsFont(first, NULL);
  CTFontRef second = CTFontCreateWithGraphicsFont(graphics, 16, NULL, NULL);
  NSCAssert(first != second && CFEqual(first, second), @"Need equal distinct fonts");
  keep((id)first);
  keep((id)second);
  NSCAssert([fonts count] == 2, @"Each cached font address must stay retained");
  [fonts removeAllObjects];
  CFRelease(second);
  CFRelease(graphics);
  CFRelease(first);

  destroyed = 0;
  @autoreleasepool {
    id firstToken = [EqualToken new];
    id secondToken = [EqualToken new];
    keep(firstToken);
    keep(secondToken);
    [firstToken release];
    [secondToken release];
  }
  NSCAssert(destroyed == 0, @"Cache must strongly retain both identities");
  NSCAssert([fonts count] == 2, @"Cache must survive autorelease-pool draining");
  [fonts removeAllObjects];
  NSCAssert(destroyed == 2, @"Cache reset must release both retained objects");
}

int main(void)
{
  // Initialize inside a short-lived pool, matching Emacs event processing.
  @autoreleasepool {
    @autoreleasepool {
      id token = [EqualToken new];
      keep_g_glyph_fonts(token);
      keep_g_color_glyph_fonts(token);
      [token release];
    }
    [g_glyph_fonts removeAllObjects];
    [g_color_glyph_fonts removeAllObjects];
    check(g_glyph_fonts, keep_g_glyph_fonts);
    check(g_color_glyph_fonts, keep_g_color_glyph_fonts);
    [g_glyph_fonts release];
    [g_color_glyph_fonts release];
  }
  return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="bmacs-glyph-fonts-") as temp:
            directory = Path(temp)
            test = directory / "ownership.m"
            binary = directory / "ownership"
            imports, body = harness.split("static int destroyed;", 1)
            test.write_text(imports + "\n".join(fragments)
                            + "\nstatic int destroyed;" + body)
            compiled = subprocess.run(
                [clang, "-fno-objc-arc", "-framework", "Foundation", "-framework",
                 "CoreText", str(test), "-o", str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
