// node-embed.mjs — transformers.js server-side embeddings + semantic search.
//
// Proves the Node path for claw3d's WS server: generate embeddings locally (via
// onnxruntime, no Python service, no Ollama, no cloud) and rank a corpus by
// cosine similarity to a query.
//
//   npm install            # once
//   node node-embed.mjs "which agent does research?"
//
// The model (~23MB) downloads from HF once, is cached under ~/.cache/huggingface,
// then runs fully locally. Only the WEIGHTS are fetched once — inference is on-device.
import { pipeline } from '@huggingface/transformers';

const MODEL = 'Xenova/all-MiniLM-L6-v2';          // tiny, canonical embedding model
const corpus = [
  'Hermes is the chief-of-staff agent that decomposes goals and routes to specialists.',
  'Pi is the sandboxed terminal coding agent running inside the pi-v1 sandbox.',
  'DeerFlow is a multi-step research agent built on LangGraph.',
  'Qdrant stores vector embeddings for retrieval-augmented generation.',
  'Phoenix is the OpenTelemetry tracing UI for every LLM call in the stack.',
  'LiteLLM is the OpenAI-compatible gateway that routes to local Ollama models.',
];

const query = process.argv.slice(2).join(' ') || 'which agent does research?';

function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}

console.log(`Loading ${MODEL} (downloads once from HF, then fully local)...`);
const t0 = performance.now();
const extract = await pipeline('feature-extraction', MODEL);
const tLoad = (performance.now() - t0).toFixed(0);

const embed = async (texts) =>
  (await extract(texts, { pooling: 'mean', normalize: true })).tolist();   // -> [n, dim]

const t1 = performance.now();
const corpusVecs = await embed(corpus);
const [queryVec] = await embed([query]);
const tEmbed = (performance.now() - t1).toFixed(0);

const ranked = corpus
  .map((text, i) => ({ text, score: cosine(queryVec, corpusVecs[i]) }))
  .sort((a, b) => b.score - a.score);

console.log(`\nmodel loaded in ${tLoad}ms · embedded ${corpus.length + 1} texts in ${tEmbed}ms · dim=${corpusVecs[0].length}`);
console.log(`\nQuery: "${query}"\n`);
ranked.forEach((r, i) => console.log(`  ${i === 0 ? '→' : ' '} ${r.score.toFixed(3)}  ${r.text}`));
console.log(`\n✓ Embeddings computed locally (onnxruntime) — no Ollama, no cloud. Top match marked →.`);
