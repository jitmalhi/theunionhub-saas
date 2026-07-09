// ai-service — the single server-side seam for all model calls (Step 0).
//
// Guarantees:
//  · ANTHROPIC_API_KEY lives here as a Function secret, never in the browser.
//  · NOTHING calls the model until the key is set — a missing key returns 503
//    BEFORE any provider/SDK is constructed.
//  · Every request is authenticated; the x-tenant-id header SELECTS a tenant and
//    the database AUTHORIZES it (D5: is_request_tenant_member() must be true).
//    The case is read under the caller's RLS, scoped to that header tenant.
//  · Every call appends a tenant-scoped usage+cost row to ai_generations.
//
// Request:  POST { feature: "draft_grievance", grievanceId: uuid, instructions?: string }
//           Headers: Authorization: Bearer <jwt>, x-tenant-id: <uuid>
// Response: text/event-stream — `data: <token>` frames, then `event: done`.

import {
  adminClient,
  resolveIdentity,
  userClientFrom,
} from "../_shared/auth.ts";
import { buildGrounding, loadCase } from "../_shared/rag.ts";
import { getProvider } from "../_shared/ai/factory.ts";
import { AiRefusal, type AiMessage } from "../_shared/ai/provider.ts";
import { estimateCostUsd, PRICING_VERSION } from "../_shared/ai/pricing.ts";

const CORS = {
  "Access-Control-Allow-Origin": Deno.env.get("AI_ALLOW_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-tenant-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const SYSTEM_PROMPTS: Record<string, string> = {
  draft_grievance:
    "You are assisting a union steward. Draft the statement of grievance and the " +
    "argument, grounded ONLY in the collective agreement text and prior precedents " +
    "provided below. Cite article numbers where relevant. Do not predict whether the " +
    "grievance will succeed. If the provided material does not support a point, say so. " +
    "Write in plain, professional language the steward can edit and own.",
  quality_review:
    "You are reviewing a drafted grievance for completeness before filing. Check only " +
    "whether required information is present; do not judge the merits or predict outcomes.",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // (1) HARD GATE: no key → no call. Returns before any provider is built.
  if (!Deno.env.get("ANTHROPIC_API_KEY")) {
    return json(
      { error: "ai_not_configured", message: "ANTHROPIC_API_KEY is not set." },
      503,
    );
  }

  // (2) Authn/z
  if (!req.headers.get("Authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  const db = userClientFrom(req);
  // resolveIdentity applies the D5 gate: the x-tenant-id header selects the
  // tenant, and is_request_tenant_member() (DB) authorizes it. A cross-tenant
  // request (A-user sending B's header) fails that check → null → 403 below.
  const identity = await resolveIdentity(req, db);
  if (!identity) return json({ error: "forbidden" }, 403);

  // (3) Input
  let body: { feature?: string; grievanceId?: string; instructions?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const feature = body.feature ?? "draft_grievance";
  if (!SYSTEM_PROMPTS[feature]) return json({ error: "unknown_feature" }, 400);
  if (!body.grievanceId) return json({ error: "missing_grievanceId" }, 400);

  // (4) Load the case under the caller's RLS (header tenant only) + grounding
  const caseRow = await loadCase(db, body.grievanceId);
  if (!caseRow) return json({ error: "case_not_found" }, 404);
  const grounding = await buildGrounding(db, caseRow);

  const userText = [
    `Grievance case ${caseRow.case_number ?? caseRow.id}.`,
    caseRow.description ? `Facts as recorded: ${caseRow.description}` : "",
    body.instructions ? `Steward instructions: ${body.instructions}` : "",
  ].filter(Boolean).join("\n");

  const messages: AiMessage[] = [{ role: "user", content: userText }];
  const provider = getProvider();
  const started = Date.now();

  // (5) Stream tokens to the browser; write the audit row when complete.
  const admin = adminClient();
  const encoder = new TextEncoder();
  let collected = "";

  const stream = new ReadableStream({
    async start(controller) {
      const send = (s: string) => controller.enqueue(encoder.encode(s));
      const { tokens, done } = provider.generate({
        system: SYSTEM_PROMPTS[feature],
        cacheableContext: grounding.text,
        messages,
        signal: req.signal,
      });

      let status: "ok" | "refusal" | "error" = "ok";
      let errorMsg: string | null = null;

      try {
        for await (const t of tokens) {
          collected += t;
          send(`data: ${JSON.stringify(t)}\n\n`);
        }
        const result = await done;
        const cost = estimateCostUsd(result.model, result.usage);
        await admin.from("ai_generations").insert({
          tenant_id: identity.tenantId,
          created_by: identity.userId,
          feature,
          grievance_id: caseRow.id,
          provider: provider.id.split(":")[0],
          model: result.model,
          input_tokens: result.usage.input_tokens,
          output_tokens: result.usage.output_tokens,
          cache_creation_input_tokens: result.usage.cache_creation_input_tokens,
          cache_read_input_tokens: result.usage.cache_read_input_tokens,
          estimated_cost_usd: cost,
          pricing_version: PRICING_VERSION,
          status: "ok",
          stop_reason: result.stopReason,
          duration_ms: Date.now() - started,
          output_sha256: await sha256Hex(collected),
        });
        send(
          `event: done\ndata: ${
            JSON.stringify({ estimated_cost_usd: cost, model: result.model })
          }\n\n`,
        );
      } catch (e) {
        status = e instanceof AiRefusal ? "refusal" : "error";
        errorMsg = e instanceof Error ? e.message : String(e);
        // best-effort audit of the failed call (no usage available)
        await admin.from("ai_generations").insert({
          tenant_id: identity.tenantId,
          created_by: identity.userId,
          feature,
          grievance_id: caseRow.id,
          provider: provider.id.split(":")[0],
          model: provider.model,
          estimated_cost_usd: 0,
          pricing_version: PRICING_VERSION,
          status,
          error: errorMsg,
          duration_ms: Date.now() - started,
        }).then(() => {}, () => {});
        send(`event: error\ndata: ${JSON.stringify({ status, error: errorMsg })}\n\n`);
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...CORS,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    },
  });
});
