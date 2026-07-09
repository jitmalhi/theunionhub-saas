// Model pricing + cost estimation (USD per 1M tokens).
// Cached from the Claude API reference (pricing_version below). When Anthropic
// changes prices, bump PRICING_VERSION and update the table — the ai_generations
// ledger stores the version used, so historical costs stay reproducible.

export const PRICING_VERSION = "2026-06-04";

type Rate = { input: number; output: number }; // $ per 1,000,000 tokens

const RATES: Record<string, Rate> = {
  "claude-fable-5": { input: 10, output: 50 },
  "claude-opus-4-8": { input: 5, output: 25 },
  "claude-opus-4-7": { input: 5, output: 25 },
  "claude-opus-4-6": { input: 5, output: 25 },
  "claude-sonnet-4-6": { input: 3, output: 15 },
  "claude-haiku-4-5": { input: 1, output: 5 },
};

export interface TokenUsage {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
}

// Cache economics: writes cost ~1.25x input (5-min TTL); reads cost ~0.1x input.
const CACHE_WRITE_MULT = 1.25;
const CACHE_READ_MULT = 0.1;

/** Estimated USD cost for one call. Returns 0 for an unknown model (still logged). */
export function estimateCostUsd(model: string, u: TokenUsage): number {
  const r = RATES[model];
  if (!r) return 0;
  const perInput = r.input / 1_000_000;
  const perOutput = r.output / 1_000_000;
  const cost =
    u.input_tokens * perInput +
    u.output_tokens * perOutput +
    u.cache_creation_input_tokens * perInput * CACHE_WRITE_MULT +
    u.cache_read_input_tokens * perInput * CACHE_READ_MULT;
  // round to 6dp to match numeric(12,6)
  return Math.round(cost * 1e6) / 1e6;
}
