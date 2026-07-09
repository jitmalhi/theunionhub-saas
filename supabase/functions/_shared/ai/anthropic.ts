// Anthropic implementation of AiProvider. The ONLY file that imports the SDK.
// Grounded in the current Claude API: adaptive thinking, effort, streaming,
// prompt-cached grounding prefix, structured output via output_config.format,
// refusal handling. No assistant prefill (removed on Opus 4.8).
//
// NOTE: pin @anthropic-ai/sdk to a known-good version after a first live call
// (see functions/ai-service/README.md). Params are built loosely-typed so a
// minor SDK type lag on newer fields (thinking/adaptive, output_config) can't
// break the build.

import Anthropic from "npm:@anthropic-ai/sdk";
import {
  AiRefusal,
  type AiProvider,
  type GenerateOptions,
  type GenerateResult,
  type GenerationStream,
} from "./provider.ts";
import type { TokenUsage } from "./pricing.ts";

const DEFAULT_MODEL = Deno.env.get("AI_MODEL") ?? "claude-opus-4-8";

const client = new Anthropic(); // reads ANTHROPIC_API_KEY from the Function secret

function buildSystem(o: GenerateOptions): unknown[] | undefined {
  const blocks: unknown[] = [];
  if (o.system) blocks.push({ type: "text", text: o.system });
  if (o.cacheableContext) {
    // cache the large, stable grounding prefix (CBA + precedents)
    blocks.push({
      type: "text",
      text: o.cacheableContext,
      cache_control: { type: "ephemeral" },
    });
  }
  return blocks.length ? blocks : undefined;
}

function usageOf(u: Record<string, number> | undefined): TokenUsage {
  return {
    input_tokens: u?.input_tokens ?? 0,
    output_tokens: u?.output_tokens ?? 0,
    cache_creation_input_tokens: u?.cache_creation_input_tokens ?? 0,
    cache_read_input_tokens: u?.cache_read_input_tokens ?? 0,
  };
}

export function makeAnthropicProvider(model = DEFAULT_MODEL): AiProvider {
  return {
    id: `anthropic:${model}`,
    model,

    generate(o: GenerateOptions): GenerationStream {
      // deno-lint-ignore no-explicit-any
      const params: any = {
        model,
        max_tokens: o.maxTokens ?? 16000,
        thinking: { type: "adaptive" },
        output_config: { effort: o.effort ?? "high" },
        system: buildSystem(o),
        messages: o.messages,
      };

      const stream = client.messages.stream(params, { signal: o.signal });

      let resolve!: (r: GenerateResult) => void;
      let reject!: (e: unknown) => void;
      const done = new Promise<GenerateResult>((res, rej) => {
        resolve = res;
        reject = rej;
      });

      async function* tokens(): AsyncIterable<string> {
        try {
          for await (const ev of stream) {
            if (
              ev.type === "content_block_delta" &&
              // deno-lint-ignore no-explicit-any
              (ev.delta as any).type === "text_delta"
            ) {
              // deno-lint-ignore no-explicit-any
              yield (ev.delta as any).text as string;
            }
          }
          const final = await stream.finalMessage();
          if (final.stop_reason === "refusal") {
            // deno-lint-ignore no-explicit-any
            reject(new AiRefusal((final as any).stop_details ?? null));
            return;
          }
          const text = final.content
            // deno-lint-ignore no-explicit-any
            .filter((b: any) => b.type === "text")
            // deno-lint-ignore no-explicit-any
            .map((b: any) => b.text)
            .join("");
          resolve({
            text,
            // deno-lint-ignore no-explicit-any
            usage: usageOf(final.usage as any),
            stopReason: final.stop_reason ?? null,
            model,
          });
        } catch (e) {
          reject(e);
          throw e;
        }
      }

      return { tokens: tokens(), done };
    },

    async generateObject<T>(
      o: GenerateOptions & { schema: Record<string, unknown> },
    ): Promise<{ value: T; result: GenerateResult }> {
      // deno-lint-ignore no-explicit-any
      const params: any = {
        model,
        max_tokens: o.maxTokens ?? 8000,
        thinking: { type: "adaptive" },
        output_config: {
          effort: o.effort ?? "high",
          format: { type: "json_schema", schema: o.schema },
        },
        system: buildSystem(o),
        messages: o.messages,
      };
      const msg = await client.messages.create(params, { signal: o.signal });
      if (msg.stop_reason === "refusal") {
        // deno-lint-ignore no-explicit-any
        throw new AiRefusal((msg as any).stop_details ?? null);
      }
      const text = msg.content
        // deno-lint-ignore no-explicit-any
        .filter((b: any) => b.type === "text")
        // deno-lint-ignore no-explicit-any
        .map((b: any) => b.text)
        .join("");
      return {
        value: JSON.parse(text) as T,
        result: {
          text,
          // deno-lint-ignore no-explicit-any
          usage: usageOf(msg.usage as any),
          stopReason: msg.stop_reason ?? null,
          model,
        },
      };
    },
  };
}
