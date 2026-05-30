let wasm; let memory; let width=160, height=144; let animationId=null; let paused=false;
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const logEl = document.getElementById('log');
const pauseBtn = document.getElementById('pauseBtn');
const fileInput = document.getElementById('romfile');

function log(msg){ logEl.textContent += msg + '\n'; logEl.scrollTop = logEl.scrollHeight; }

async function init(){
  const resp = await fetch('../zig-out/bin/gbemu_wasm.wasm');
  const bytes = await resp.arrayBuffer();
  const inst = await WebAssembly.instantiate(bytes, { env: {
    // Provide microseconds (truncate) as BigInt
    host_now_us: () => {
      const ms = performance.now();
      return BigInt(Math.floor(ms * 1000));
    },
  }});
  wasm = inst.instance.exports;
  memory = inst.instance.exports.memory;
  // width/height may be exported either as functions or globals depending on optimization.
  function resolveExport(val){
    if(typeof val === 'function') return val();
    // WebAssembly.Global or plain number
    if(typeof val === 'object' && val !== null && 'value' in val) return val.value;
    return val; // assume number
  }
  width = resolveExport(wasm.gb_width);
  height = resolveExport(wasm.gb_height);
  canvas.width = width; canvas.height = height;
  log('WASM loaded');
  setupInput();
}

function setupInput(){
  const map = { KeyJ:0, KeyK:1, Slash:2, Enter:3, ArrowRight:4, ArrowLeft:5, ArrowUp:6, ArrowDown:7, KeyS:7, KeyW:6, KeyA:5, KeyD:4 };
  window.addEventListener('keydown', e=>{ const b=map[e.code]; if(b!==undefined){ wasm.gb_input(b,1); e.preventDefault(); }});
  window.addEventListener('keyup', e=>{ const b=map[e.code]; if(b!==undefined){ wasm.gb_input(b,0); e.preventDefault(); }});
}

// (Removed earlier incomplete change handler)

// Simpler custom linear allocator for demo
let heapTop = 0;
function alloc(size){
  if(!memory) return 0;
  const pageSize = 65536;
  if(heapTop===0){ heapTop = memory.buffer.byteLength; }
  const needed = heapTop + size;
  while(needed > memory.buffer.byteLength){ memory.grow(1); }
  const ptr = heapTop; heapTop += size; return ptr;
}

fileInput.addEventListener('change', async e=>{
  const file = e.target.files[0]; if(!file) return;
  const data = new Uint8Array(await file.arrayBuffer());
  const ptr = alloc(data.length);
  new Uint8Array(memory.buffer, ptr, data.length).set(data);
  const res = wasm.gb_init(ptr, data.length);
  const err = wasm.gb_last_error_code ? wasm.gb_last_error_code() : 0;
  if(res!==0 || err!==0){
    let msg = 'Unknown error';
    if(err===1) msg = 'Unsupported MBC type (web build)';
    else if(err===2) msg = 'ROM too small / not a valid Game Boy ROM';
    log('gb_init failed: '+msg+' (code '+err+')');
    return;
  }
  // Diagnostics: log cartridge metadata
  if(wasm.gb_cart_type){
    const type = wasm.gb_cart_type();
    const romBytes = wasm.gb_cart_rom_size_bytes ? wasm.gb_cart_rom_size_bytes() : 0;
    const ramBytes = wasm.gb_cart_ram_size_bytes ? wasm.gb_cart_ram_size_bytes() : 0;
    log(`Cart type=0x${type.toString(16)} ROM=${romBytes} bytes RAM=${ramBytes} bytes`);
    // Start periodic frame counter logging
    if(wasm.gb_frame_count){
      setInterval(()=>{
        if(paused) return; // stop appending while paused so the log can be copied
        const fc = wasm.gb_frame_count();
        log('Frames executed: '+fc + (wasm.gb_cpu_pc? ' PC=0x'+ wasm.gb_cpu_pc().toString(16):''));
      }, 1000);
    }
  }
  pauseBtn.disabled = false; paused=false; startLoop();
});

pauseBtn.addEventListener('click', ()=>{ if(!paused){ cancelAnimationFrame(animationId); pauseBtn.textContent='Resume'; paused=true; } else { paused=false; pauseBtn.textContent='Pause'; startLoop(); }});

// Developer keyboard shortcuts
window.addEventListener('keydown', e=>{
  if(!wasm) return;
  if(e.code==='KeyP' && e.metaKey){ // Cmd+P toggle pacing
    const enabled = pacingToggle(); e.preventDefault();
  }
  if(e.code==='KeyF' && e.metaKey){ // Cmd+F force one frame
    if(wasm.gb_force_frame){ wasm.gb_force_frame(); const fbPtr = wasm.gb_frame ? wasm.gb_frame():0; if(fbPtr) drawFrame(fbPtr); }
    e.preventDefault();
  }
});

function pacingToggle(){
  if(!wasm || !wasm.gb_set_pacing) return false;
  // Query current by flipping and seeing result; store state locally.
  pacingToggle.state = !(pacingToggle.state ?? true);
  wasm.gb_set_pacing(pacingToggle.state ? 1:0);
  log('Pacing ' + (pacingToggle.state? 'enabled':'disabled'));
  return pacingToggle.state;
}

function startLoop(){ pauseBtn.textContent='Pause'; function frame(){ if(paused) return; const fbPtr = wasm.gb_frame(); if(fbPtr){ drawFrame(fbPtr); } animationId = requestAnimationFrame(frame); } frame(); startAudioPull(); }

const imageData = ctx.createImageData(width, height);
function drawFrame(fbPtr){
  const fb = new Uint8Array(memory.buffer, fbPtr, width*height*3);
  // Expand RGB24 to RGBA32
  const out = imageData.data;
  let j=0; for(let i=0;i<fb.length;i+=3){ out[j++] = fb[i]; out[j++] = fb[i+1]; out[j++] = fb[i+2]; out[j++] = 255; }
  ctx.putImageData(imageData,0,0);
}

// Audio pulling
let audioCtx; let audioInterval=null; let nextAudioTime=0;
const AUDIO_LEAD = 0.05; // seconds of scheduling lead to absorb timer jitter
function startAudioPull(){
  if(audioInterval) return;
  audioCtx = audioCtx || new (window.AudioContext||window.webkitAudioContext)({sampleRate:48000});
  audioInterval = setInterval(()=>{
    if(!wasm) return;
    const frameCount = wasm.gb_audio_available();
    if(frameCount===0) return;
    const audioPtr = wasm.gb_audio_ptr();
    if(!audioPtr) return;
    const samples = new Float32Array(memory.buffer, audioPtr, frameCount*2);
    const buf = audioCtx.createBuffer(2, frameCount, 48000);
    const L = buf.getChannelData(0), R = buf.getChannelData(1);
    for(let i=0;i<frameCount;i++){ L[i]=samples[i*2]; R[i]=samples[i*2+1]; }
    wasm.gb_audio_consume();
    // Schedule each chunk to start exactly where the previous one ended, so successive
    // buffers play gaplessly (firing them "now" causes ~60 clicks/sec = static). If we
    // fall behind real time (underrun), resync with a small lead.
    const now = audioCtx.currentTime;
    if(nextAudioTime < now) nextAudioTime = now + AUDIO_LEAD;
    const src = audioCtx.createBufferSource(); src.buffer = buf; src.connect(audioCtx.destination);
    src.start(nextAudioTime);
    nextAudioTime += buf.duration;
  }, 16);
}

init().catch(e=>log('Init error: '+e));
