// Strict golden driver for the WASM core (SDL-free verification across Zig
// versions). Instantiates zig-out/bin/gbemu_wasm.wasm in Node, loads a ROM,
// drives deterministic auto-pilot input, and dumps a fully deterministic
// per-sample line (pc / cycles / framebuffer FNV-1a) plus sanity checks. The
// output is diffed against a golden captured on known-good Zig 0.14.1 — exact
// match => the toolchain change preserved emulation behavior bit-for-bit.
//
// Usage: node tools/wasm_golden.mjs <rom> [frames=900] [interval=30]
import { readFileSync } from 'node:fs';

const romPath = process.argv[2] ?? 'games/tetris.gb';
const FRAMES = Number(process.argv[3] ?? 900);
const INTERVAL = Number(process.argv[4] ?? 30);

function fail(msg) { console.error(`FAIL: ${msg}`); process.exit(1); }
const resolve = (v) => (typeof v === 'function' ? v() : v && typeof v === 'object' && 'value' in v ? v.value : v);

let fakeClockUs = 1000n;
const env = { host_now_us: () => { fakeClockUs += 1000n; return fakeClockUs; } };

const wasmBytes = readFileSync('zig-out/bin/gbemu_wasm.wasm');
const romBytes = new Uint8Array(readFileSync(romPath));
const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
const w = instance.exports;
const memory = w.memory;

let heapTop = 0;
function alloc(size) {
  if (heapTop === 0) heapTop = memory.buffer.byteLength;
  while (heapTop + size > memory.buffer.byteLength) memory.grow(1);
  const ptr = heapTop; heapTop += size; return ptr;
}

const romPtr = alloc(romBytes.length);
new Uint8Array(memory.buffer, romPtr, romBytes.length).set(romBytes);
if (w.gb_init(romPtr, romBytes.length) !== 0) fail('gb_init != 0');
if (resolve(w.gb_last_error_code) !== 0) fail(`error code ${resolve(w.gb_last_error_code)}`);

const width = resolve(w.gb_width), height = resolve(w.gb_height);
const canvasBytes = width * height * 3;

w.gb_set_pacing(0);   // deterministic: one frame per gb_frame()
w.gb_frame();         // priming call (runs no frame)

function fnv1a(ptr, len) {
  const view = new Uint8Array(memory.buffer, ptr, len);
  let h = 0x811c9dc5;
  for (let i = 0; i < len; i++) { h ^= view[i]; h = Math.imul(h, 0x01000193) >>> 0; }
  return h >>> 0;
}

// Deterministic auto-pilot: tap START, then A, then RIGHT on a fixed cadence so
// the game advances past its title/menus into gameplay (button map per gb_input:
// 0=A 3=START 4=RIGHT). Exact inputs are arbitrary — only determinism matters.
function drive(i) {
  const phase = i % 96;
  w.gb_input(3, phase < 4 ? 1 : 0);                 // START
  w.gb_input(0, phase >= 32 && phase < 36 ? 1 : 0); // A
  w.gb_input(4, phase >= 64 && phase < 68 ? 1 : 0); // RIGHT
}

console.log(`# rom=${romPath} frames=${FRAMES} interval=${INTERVAL} canvas=${width}x${height}`);

let canvasPtr = 0, prevCycles = 0n, monotonic = true;
const distinct = new Set();
const hex = (n, w8) => n.toString(16).padStart(w8, '0');

for (let i = 0; i < FRAMES; i++) {
  drive(i);
  const ret = w.gb_frame();
  if (ret && canvasPtr === 0) canvasPtr = typeof ret === 'bigint' ? Number(ret) : ret;

  const cyc = w.gb_cycles();
  if (i > 0 && !(cyc > prevCycles)) monotonic = false;
  prevCycles = cyc;

  if (i % INTERVAL === 0 || i === FRAMES - 1) {
    const fb = canvasPtr ? fnv1a(canvasPtr, canvasBytes) : 0;
    distinct.add(fb);
    const pc = resolve(w.gb_cpu_pc);
    console.log(`frame=${String(i).padStart(5, '0')} pc=0x${hex(pc, 4)} cycles=${cyc} fb=0x${hex(fb, 8)}`);
  }
}

console.log(`# distinct_fb=${distinct.size} monotonic=${monotonic} final_pc=0x${hex(resolve(w.gb_cpu_pc), 4)}`);

if (!monotonic) fail('cycles not monotonically increasing');
if (resolve(w.gb_cpu_pc) === 0x38) fail('PC stuck at RST $38 (corruption loop)');
if (distinct.size < 2) fail('framebuffer never changed');
console.log(`OK: ran ${FRAMES} frames; ${distinct.size} distinct framebuffers, cycles monotonic`);
