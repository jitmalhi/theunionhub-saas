// The single seam every AI feature depends on. Callers use AiProvider — never a
// vendor SDK type — so swapping model/provider is one file (see factory.ts).

import type { TokenUsage } from "./pricing.ts";

export interface AiMessage {
  role: "user" | "assistant";
  content: string;
}

export interface GenerateOptions {
  system?: string; // stable instruction prefix
  cacheableContext?: string; // large grounding block (CBA + precedents) — prompt-cached
  messages: AiMessage[]; // the volatile turn(s)
  maxTokens?: number;
  effort?: "low" | "medium" | "high";
  schema?: Record<string, unknown>; // JSON Schema → structured output (generateObject)
  signal?: AbortSignal;
}

export interface GenerateResult {
  text: string;
  usage: TokenUsage;
  stopReason: string | null;
  model: string;
}

export interface GenerationStream {
  tokens: AsyncIterable<string>; // stream text deltas
  done: Promise<GenerateResult>; // resolves with usage + stop reason when complete
}

export class AiRefusal extends Error {
  constructor(public details: unknown) {
    super("model_refusal");
    this.name = "AiRefusal";
  }
}

export interface AiProvider {
  readonly id: string; // e.g. "anthropic:claude-opus-4-8"
  readonly model: string;
  generate(opts: GenerateOptions): GenerationStream;
  generateObject<T>(
    opts: GenerateOptions & { schema: Record<string, unknown> },
  ): Promise<{ value: T; result: GenerateResult }>;
}
