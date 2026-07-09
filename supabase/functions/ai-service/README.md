# ai-service — AI service layer (Step 0)

The single, server-side seam for every model call. See
`docs/document-generation-spec.md` §Step 0 for the design.

## Layout

```
supabase/functions/
├── ai-service/index.ts        ← the HTTP handler (auth → RAG → generate → SSE → audit)
└── _shared/
    ├── auth.ts                ← JWT verify, role/tenant resolve, user vs admin client
    ├── rag.ts                 ← grounding retrieval (case, CBA, precedents) under RLS
    └── ai/
        ├── provider.ts        ← AiProvider interface (the swappable seam)
        ├── anthropic.ts       ← the ONLY file importing @anthropic-ai/sdk
        ├── factory.ts         ← getProvider() — swap model/provider here
        └── pricing.ts         ← cost estimate + PRICING_VERSION
```

DB: `supabase/migrations/0010_ai_generations.sql` (append-only usage+cost ledger, tenant-scoped).

## ⚠️ Nothing calls the API until the key is set

The handler returns **HTTP 503 `ai_not_configured`** *before constructing any
provider or SDK client* whenever `ANTHROPIC_API_KEY` is absent. The client
(`src/lib/aiService.js`) surfaces that as "AI is not set up yet." So you can
deploy this now and it will simply refuse to generate until you set the key —
no accidental spend, no key in the browser.

## Set the key (do this when you're ready to enable AI)

The Anthropic key must be a **Supabase Function secret** — never a `VITE_` var
(Vite inlines those into the browser bundle).

1. **Get a key:** Anthropic Console → API Keys → create key (`sk-ant-...`).
2. **Set it as a secret** (from the repo root, logged into the Supabase CLI):
   ```bash
   supabase secrets set ANTHROPIC_API_KEY=sk-ant-xxxxxxxx
   # optional overrides:
   #   supabase secrets set AI_MODEL=claude-opus-4-8
   #   supabase secrets set AI_ALLOW_ORIGIN=https://your-app-domain
   ```
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are
   injected automatically — you do **not** set those.
3. **Deploy the function:**
   ```bash
   supabase functions deploy ai-service
   ```
4. **Apply the migration** (SQL editor or `supabase db push`), then
   `NOTIFY pgrst, 'reload schema';`.

To confirm the key never leaks to the client, after `npm run build`:
```bash
grep -R "sk-ant" dist/ ; grep -Ri "anthropic" dist/     # both must return nothing
```

## Pin the SDK after first success

`anthropic.ts` imports `npm:@anthropic-ai/sdk` (latest). After one successful
live call, pin it — `npm:@anthropic-ai/sdk@<version>` — so a future SDK release
can't change behavior under you.

## Cost tracking per local

Every call writes to `ai_generations` (tenant-scoped, append-only) with token
counts + `estimated_cost_usd`. Per-local monthly spend:
```sql
select * from public.ai_cost_by_month order by month desc;
```
(ADMIN/STAFF see the whole local; stewards see their own calls — enforced by RLS.)
