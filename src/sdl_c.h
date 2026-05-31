// Translation unit fed to Zig's build-system translate-c (b.addTranslateC) to
// produce the `sdl2` module for native builds. Replaces the unmaintained
// third-party SDL.zig binding with the system SDL2 headers, tracked by the
// compiler's own translate-c.
//
// Skip SDL's inclusion of <arm_neon.h>: Zig's bundled clang can't parse the
// NEON builtins, and our bindings don't use any NEON types from SDL.
#define SDL_DISABLE_ARM_NEON_H 1
#include <SDL2/SDL.h>
