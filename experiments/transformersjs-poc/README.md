# transformers.js PoC — local on-device embeddings for the stack

Proves [transformers.js](https://github.com/huggingface/transformers.js) running
**locally on this machine** (browser WebGPU + Node), doing real **embeddings +
semantic search** with **zero load on Ollama or the 24 GB host** — the capability
to drop into **claw3d**.

> Why this lives here, not in `claw3d/`: claw3d is a vendored clone (gitignored,
> re-clonable), so a PoC inside it wouldn't be committed or survive a re-clone.
> This is a self-contained, committed demo you port *into* claw3d once you like it.

## What it shows

- Embeddings computed **on-device** (browser GPU via WebGPU, or onnxruntime in Node) —
  the model (~23 MB `all-MiniLM-L6-v2`) downloads from HF **once**, then runs fully local.
- Semantic search: rank a corpus by cosine similarity to a free-text query.
- This is the cheap, latency-sensitive work that should **never** occupy your scarce
  24 GB RAM or an Ollama slot — it belongs on the client GPU / the claw3d Node server.

## Run it

**Browser (the headline demo — WebGPU):**
```bash
cd ~/ai-stack/experiments/transformersjs-poc
python3 -m http.server 8099        # ES-module CDN import + WebGPU need http://, not file://
# open http://localhost:8099 in Safari 26 (macOS Tahoe ships WebGPU on) or Chrome
```
Type a question (e.g. "where do traces go?") → ranked results + the device used
(`webgpu ⚡` or WASM fallback) + latency.

**Node (server-side path for claw3d's WS server):**
```bash
cd ~/ai-stack/experiments/transformersjs-poc
npm install
node node-embed.mjs "which agent does research?"
```

## Porting into claw3d

claw3d is Next.js 16 / React 19 / Three.js + a Node WS server — both paths fit:

- **Browser side** (a React component): `npm i @huggingface/transformers`, then the
  `pipeline('feature-extraction', 'Xenova/all-MiniLM-L6-v2', { device: 'webgpu' })`
  call from `index.html`. Uses: client-side search over session text, a semantic
  command palette, or **intent classification to route a request to the right Hermes
  profile** before it ever hits LiteLLM.
- **Server side** (the WS server): the `node-embed.mjs` logic — generate embeddings
  without a separate Python service.
- **Voice**: swap the pipeline to `automatic-speech-recognition` + `Xenova/whisper-tiny`
  for talk-to-your-agents input.

## Caveats (honest seams)

- **ONNX-only — a separate model path.** It does **not** reuse your Ollama GGUF / LM
  Studio MLX weights. Use it for browser/edge jobs Ollama shouldn't do, not as a
  second copy of your LLMs.
- **Keep in-browser *generation* tiny** (≤ ~0.5–1 B q4); WebGPU text-gen is slow above
  that on M-series. **Embeddings / Whisper-tiny are the clean wins**; route heavy
  generation to LiteLLM → Ollama.
- License: transformers.js is Apache-2.0; each model carries its own license
  (`all-MiniLM-L6-v2` = Apache-2.0).
