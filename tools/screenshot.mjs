// Render a ROM's framebuffer to a PPM (P6) after running N frames — for the
// visual PPU tests (dmg-acid2, mealybug, etc.) that have no machine-readable
// pass/fail. Convert to PNG with: sips -s format png out.ppm --out out.png
//
// Usage: node tools/screenshot.mjs <rom> <out.ppm> [frames=600]
import { readFileSync, writeFileSync } from 'node:fs';

const romPath = process.argv[2];
const outPath = process.argv[3];
const FRAMES = Number(process.argv[4] ?? 600);
if (!romPath || !outPath) { console.error('usage: screenshot.mjs <rom> <out.ppm> [frames]'); process.exit(64); }

let clock = 1000n;
const { instance } = await WebAssembly.instantiate(
  readFileSync('zig-out/bin/gbemu_wasm.wasm'),
  { env: { host_now_us: () => { clock += 1000n; return clock; } } },
);
const w = instance.exports, mem = w.memory;
let top = 0; const alloc = n => { if (top === 0) top = mem.buffer.byteLength; while (top + n > mem.buffer.byteLength) mem.grow(1); const p = top; top += n; return p; };
const rom = new Uint8Array(readFileSync(romPath));
const p = alloc(rom.length); new Uint8Array(mem.buffer, p, rom.length).set(rom);
if (w.gb_init(p, rom.length) !== 0) { console.error('gb_init failed'); process.exit(1); }
w.gb_set_pacing(0); w.gb_frame();

const width = (typeof w.gb_width === 'function' ? w.gb_width() : w.gb_width);
const height = (typeof w.gb_height === 'function' ? w.gb_height() : w.gb_height);
let fbPtr = 0;
for (let i = 0; i < FRAMES; i++) { const r = w.gb_frame(); if (r) fbPtr = typeof r === 'bigint' ? Number(r) : r; }
if (!fbPtr) { console.error('no framebuffer'); process.exit(1); }

const fb = new Uint8Array(mem.buffer, fbPtr, width * height * 3);
const header = Buffer.from(`P6\n${width} ${height}\n255\n`, 'ascii');
writeFileSync(outPath, Buffer.concat([header, Buffer.from(fb)]));
console.log(`wrote ${outPath} (${width}x${height}, ${FRAMES} frames, ${romPath})`);
