# Member Access & Knowledge — design

**One line:** the member card is a **key to the union's knowledge**, not just a verification ID. Access is **layered** — frictionless for knowledge, sign-in only when it gets personal.

This is the reference for how members reach the collective agreement, the knowledge base, their steward, and their own file. It complements [OCR-KNOWLEDGE-PIPELINE.md](OCR-KNOWLEDGE-PIPELINE.md) (how the knowledge gets in) and reuses the existing card, auth, and RLS layers.

**Status legend:** 🟢 Live · 🟡 Built/staged · 🔭 Roadmap · ✏️ Design decision

---

## Why this shape (the context)

Two facts from the field drove this design:

1. **~80% of steward↔member meetings are online** (Teams/Zoom). So the old hook — *"scan a QR at work to save your steward"* — is a minor moment, not the value. The card's job shifts from an in-person contact-save to an **always-on gateway to knowledge and help**. (Representation still needs documenting — online meetings arguably more so, since there's no paper trail. The DFR log stays central.)
2. **The collective agreement is not secret.** It already lives on the union website *and* the employer's portal; members have full access from two places. So the value was never *access to the document* — it's making the document **usable**, and connecting it to how it's actually been **enforced**.

**The through-line:** knowledge is the hook; documentation (representation, precedent) is the moat.

---

## The three tiers

### Tier 0 — Public (no login) 🟢🟡
The local's hosted website: updates, meetings, **find-your-steward**, and **public documents including the collective agreement download** (it's public — don't protect it).
- Access: open web.
- Backing: the Tier-1 website product; `site_documents.visibility = 'public'` (migration 0037) already marks what belongs here.

### Tier 1 — Card-keyed knowledge (frictionless, no password) ✏️🔭
What every member should reach with **zero friction**, because it's the same for all members and not personally sensitive:
- **Ask the agreement** — search + plain-language AI answers, with citations.
- **Rights explainers** — "can they deny my vacation?" grounded in the CBA.
- **Their steward's profile** — reachable *however* you meet (email, Teams, message), not just a vCard.
- **The knowledge base** — precedent/settlement summaries the local has chosen to surface.

- **Access:** the card's own **short-lived, signed token** ("you hold a member card of this local"). No email, no password.
- **Why gated at all — not secrecy (there is none):** **cost control** (AI queries cost money; keep bots/employer/randoms from running up the bill) + **member benefit / attribution** (members associate "I finally understand my agreement" with *their union*). Because there's no secrecy constraint, this is a deliberate *choice*, not a security requirement — it could be made fully public if the local accepts the AI cost + rate limits. **Default: card-keyed.**
- Backing: the member card (`card.html`) + a "My Union" entry point; the token follows the signed short-lived member-card design; AI via `ai-service`/RAG; steward via `lookup_steward` (0034).

### Tier 2 — Personal (secure sign-in link) 🟡🔭
Anything that is *theirs* or creates a record about them:
- Their **grievance status**, their **profile/personal info**, **members-only documents**, and any **AI conversation logged as them**.
- **Access:** a secure sign-in link — the existing passwordless email sign-in (a "magic link", internally). Step-up only when needed.
- Backing: `auth-guard.js` (live) + a members area (new); `site_documents.visibility = 'members'` (seam already in 0037) gates member-only files; grievance status from the grievance system.

---

## Access mechanics

- **The card is the identity anchor.** It's issued from the roster, so its token maps to a `member_id`. Possession of a valid, unexpired token opens Tier 1.
- **Short-lived signed token.** The card carries a rotating, signed token so a screenshot expires rather than granting forever-access. (Aligns with the member-card signed-token design note.)
- **The card bootstraps auth — and fixes the stale-email problem.** Your own problem list flags outdated member emails. Flow: member taps card → reaches Tier-1 knowledge instantly → when they want something personal, they're prompted *"confirm your email to see your own file"* → secure sign-in (Tier 2) is now enabled. The card is the on-ramp that *fixes* the missing-email problem instead of being blocked by it.

---

## Privacy rules (non-negotiable)

- **Ask-the-agreement questions are NOT logged against the member.** Card-in for cost/benefit, but "can I be fired for calling in sick?" is never stored against a name. A member's *question* reveals a worry; protect it.
- **Anything that creates a record about a person → Tier 2** (explicit sign-in, so it's clearly *their* action).
- **Count visits, not visitors** — the existing analytics stance holds throughout.

---

## Where the knowledge comes from (OCR priority)

Because the CBA is public *and already digital*, the pipeline priority sharpens:

- **The CBA is the easy part — no OCR.** It's a clean digital PDF (on the union site / employer portal). Ingest the text directly: near-perfect confidence, trivial. It's the public **spine** every answer references.
- **The private history is the moat — and the real OCR target.** Grievances, settlements, arbitration decisions, letters of understanding, side agreements, past cases — the filing-cabinet material that is *not* digital and *not* on the employer portal. Work backwards: **current CBA (trivial, digital) → recent grievances/settlements (valuable, often paper → OCR)**.
- Everything still passes the **verify-before-publish gate** (0040): AI only ever answers from human-verified content, with citations.

---

## The narrative this unlocks

> **The employer gives members a PDF. The union gives them the agreement that actually answers — in plain language, on their side, connected to how it's really been enforced.**

The employer's portal is a compliance checkbox. The union becomes the place members go to *understand* their rights — which flips the "employer information advantage" problem into a union advantage.

**Marketing implications** (for when we rework the materials):
- Lead with **"your card unlocks your union's knowledge — no password."**
- Reframe the steward card as **"your steward, reachable however you meet"** — demote the physical-scan language.
- Sell **usability + private precedent**, never "document storage."

---

## Build sequence

1. **Tier-1 wedge (first):** card → knowledge. The "My Union" entry on the card; the short-lived signed token; **ask-the-agreement** over the ingested **current CBA** (easy — digital); the reframed steward profile. Add **rate limiting** on the AI for cost.
2. **Private-history digitization (the moat):** OCR the paper grievances/settlements/LOUs via the pipeline (0040 + the extract function), verify-gated.
3. **Tier-2 members area (second):** secure-sign-in members portal — grievance status, personal file, members-only docs (`visibility='members'`).

## What we are explicitly NOT doing
- Not gating the collective agreement — it's public (Tier 0).
- Not logging members' knowledge questions.
- Not putting a password wall in front of knowledge — friction kills the adoption of the very thing that's the hook.

---
_Prepared as the reference for member access. Buildable on the existing card, auth (passwordless secure sign-in / magic-link), RAG, and RLS layers; reuses `site_documents.visibility` and the 0040 verify gate. No new vendor._
