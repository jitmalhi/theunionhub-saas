// Auth + client helpers for the ai-service function.
// - userClient: runs as the caller (their JWT) AND under the caller's selected
//   tenant (x-tenant-id header) → RLS + get_request_tenant_id() scope every read
//   to that header tenant. Used for grounding retrieval.
// - adminClient: service role → used ONLY to append the ai_generations audit row,
//   with tenant_id/created_by taken from the verified identity (never client input).
//
// D5 rule: the x-tenant-id header SELECTS a tenant; the database AUTHORIZES it.
// The header alone is never trusted — is_request_tenant_member() (0022), backed by
// the live tenant_admins/stewards tables, is the gate. A user who sends a tenant
// header they don't belong to is rejected (resolveIdentity → null → 403).

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

export function userClientFrom(req: Request): SupabaseClient {
  const authorization = req.headers.get("Authorization") ?? "";
  // Forward the tenant selector too, so PostgREST's request.headers GUC carries
  // it and get_request_tenant_id() / the RLS helpers resolve the header tenant
  // for every read this client performs.
  const tenantId = req.headers.get("x-tenant-id") ?? "";
  return createClient(SUPABASE_URL, ANON_KEY, {
    global: {
      headers: {
        Authorization: authorization,
        "x-tenant-id": tenantId,
      },
    },
    auth: { persistSession: false },
  });
}

export function adminClient(): SupabaseClient {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
}

export interface Identity {
  userId: string;
  role: "STEWARD" | "ADMIN" | "STAFF";
  tenantId: string;
}

/**
 * Verify the JWT and authorize the caller for the header-selected tenant.
 *
 * D5 gate: the x-tenant-id header only SELECTS a tenant; the database AUTHORIZES.
 *   (a) no header               → null
 *   (b) invalid JWT             → null
 *   (c) is_request_tenant_member() not exactly true → null  ← THE cross-tenant gate
 *   (d) get_user_role()         → role, for logging
 *   (e) tenantId = the validated header value
 */
export async function resolveIdentity(
  req: Request,
  userClient: SupabaseClient,
): Promise<Identity | null> {
  // (a) The header SELECTS the tenant. Missing/empty → nothing to authorize.
  const headerTenant = req.headers.get("x-tenant-id")?.trim();
  if (!headerTenant) return null;

  // (b) Verify the caller's JWT.
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return null;

  // (c) D5 authorization gate: the DB decides whether this user belongs to the
  // header tenant, reading the live tenant_admins/stewards tables. A user from
  // tenant A spoofing tenant B's header has no membership row in B → false → 403.
  const { data: isMember, error: memberErr } = await userClient.rpc(
    "is_request_tenant_member",
  );
  if (memberErr || isMember !== true) return null;

  // (d) Resolve the role for logging (ADMIN | STEWARD) from the header tenant.
  const { data: roleData, error: roleErr } = await userClient.rpc(
    "get_user_role",
  );
  if (roleErr || !roleData || !roleData.length) return null;
  const row = roleData[0] as { role: Identity["role"]; tenant_id: string };
  if (!row.role) return null;

  // (e) The validated header tenant is the authoritative tenant for this request.
  return { userId: userData.user.id, role: row.role, tenantId: headerTenant };
}
