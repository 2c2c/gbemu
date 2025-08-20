let wasm; let memory; let width=160, height=144; let animationId=null; let paused=false;
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const logEl = document.getElementById('log');
const pauseBtn = document.getElementById('pauseBtn');
const fileInput = document.getElementById('romfile');

function log(msg){ logEl.textContent += msg + '\n'; logEl.scrollTop = logEl.scrollHeight; }

async function init(){
  // Cache-busting query param to ensure we load the freshly built wasm.
  const resp = await fetch('../zig-out/bin/gbemu_wasm.wasm?v=' + Date.now(), { cache: 'no-store' });
  const bytes = await resp.arrayBuffer();
  log('Fetched wasm bytes: '+ bytes.byteLength);
  const inst = await WebAssembly.instantiate(bytes, { env: { } });
  wasm = inst.instance.exports;
  memory = inst.instance.exports.memory;
  // Log exports for debugging
  log('Exports: ' + Object.keys(wasm).join(', '));
  if(!wasm.gb_init){
    // Attempt to find a function whose name contains 'gb_init'
    for(const k of Object.keys(wasm)){
      if(/gb.?init/i.test(k) && typeof wasm[k]==='function'){ wasm.gb_init = wasm[k]; log('Mapped '+k+' -> gb_init'); break; }
    }
  }
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
  if(typeof wasm.gb_init !== 'function'){ log('gb_init export not found (exports logged above)'); return; }
  const res = wasm.gb_init(ptr, data.length);
  if(res!==0){ log('gb_init failed'); return; }
  pauseBtn.disabled = false; paused=false; startLoop();
});

pauseBtn.addEventListener('click', ()=>{ if(!paused){ cancelAnimationFrame(animationId); pauseBtn.textContent='Resume'; paused=true; } else { paused=false; pauseBtn.textContent='Pause'; startLoop(); }});

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
let audioCtx; let audioInterval=null;
function startAudioPull(){
  if(audioInterval) return;
  audioCtx = audioCtx || new (window.AudioContext||window.webkitAudioContext)({sampleRate:48000});
  audioInterval = setInterval(()=>{
    if(!wasm) return;
    const frames = wasm.gb_audio_available();
    if(frames===0) return;
    const ptrOut = alloc(4); const framesOut = alloc(4);
    wasm.gb_audio_read(ptrOut, framesOut);
    const u32 = new Uint32Array(memory.buffer);
    const audioPtr = u32[ptrOut/4];
    const frameCount = u32[framesOut/4];
    if(frameCount===0) return;
    const samples = new Float32Array(memory.buffer, audioPtr, frameCount*2);
    const buf = audioCtx.createBuffer(2, frameCount, 48000);
    for(let i=0;i<frameCount;i++){ buf.getChannelData(0)[i]=samples[i*2]; buf.getChannelData(1)[i]=samples[i*2+1]; }
    const src = audioCtx.createBufferSource(); src.buffer = buf; src.connect(audioCtx.destination); src.start();
  }, 16);
}

init().catch(e=>log('Init error: '+e));
