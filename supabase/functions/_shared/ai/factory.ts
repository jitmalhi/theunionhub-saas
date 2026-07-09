// The one place a provider is chosen. Swap models/providers here; callers are
// untouched (model-agnostic architecture — see docs/shared-knowledge-schema.md §3.3).

import type { AiProvider } from "./provider.ts";
import { makeAnthropicProvider } from "./anthropic.ts";

export function getProvider(): AiProvider {
  const providerId = Deno.env.get("AI_PROVIDER") ?? "anthropic";
  switch (providerId) {
    case "anthropic":
      return makeAnthropicProvider();
    default:
      throw new Error(`unknown AI_PROVIDER: ${providerId}`);
  }
}
