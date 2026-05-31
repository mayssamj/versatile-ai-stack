/**
 * Pi extension — route all OpenAI-shape calls through LiteLLM (Phase 01)
 * using the Pi-scoped virtual key.
 *
 * The OpenShell sandbox network policy (openshell/policies/pi-v1.yaml)
 * whitelists host.docker.internal:4000. PI_LITELLM_KEY is a LiteLLM
 * virtual key minted in Phase 15 with models=[local, local-heavy,
 * local-lfm2] — LiteLLM rejects requests for any other model with
 * "key not allowed to access model".
 *
 * Why not `inference.local`? OpenShell's shipped `openai` provider type
 * ignores --config endpoint overrides and forwards to api.openai.com.
 * Direct-dial via virtual key is the working pattern. See CHANGELOG
 * 2026-05-29 for the diagnosis.
 *
 * Pi never sees LITELLM_MASTER_KEY. PI_LITELLM_KEY is set in the sandbox
 * by bin/pi (which reads it from the host .env mode 0600).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("openai", {
    baseUrl: "http://host.docker.internal:4000/v1",
    authHeader: true,
    apiKey: "$PI_LITELLM_KEY",
  });
}
