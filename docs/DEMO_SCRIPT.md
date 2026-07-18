# DEMO SCRIPT — The Union Hub

**Phase 12** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Audience:** a salesperson runs it; a union executive gets the value in **≤30 minutes**. Tenant: **Local 5000 · Cedarline Health Workers Union** (`DEMO_ENVIRONMENT.md`; data per `MOCKUP-RULES.md`).

**Core message — say it at the start, prove it throughout, repeat it at the end:**
> **The Union Hub preserves institutional knowledge, so a Local does not lose decades of experience when officers, stewards, and leadership change.**

This demo shows the *existing* platform value. No feature is invented; anything not built is labelled roadmap or shown as sample.

---

## 0 · Before the demo (2 min, off-camera)
- `./reset-demo.sh` → clean Local 5000 state.
- Three tabs logged in: **Executive (L. Marchetti)**, **Steward (C. Adeyemi)**, **Member (M. Thibault)**.
- Open on the public site (`local5000.demo…`).
- **Opening line:** "Cedarline Local 5000 has 15,000 members, 120 stewards, eight units, six employers — and turnover every election. Watch one thing today: *nothing you see depends on a particular person still being in the role.*"

## 1 · Act I — Executive (~9 min) · *what the Local can see about itself*
Log in as **Executive**.
1. **Local dashboard** — membership across 8 units / 6 employers, active issues, steward activity. "This is the whole Local at a glance — and it's the same view for whoever's elected next."
2. **Membership overview** — filter by unit/employer. "The roster belongs to the Local, not to a spreadsheet on someone's laptop. It's still here after they've gone."
3. **Active issues + steward activity** — open grievances by stage, deadlines approaching, steward load. "An incoming Executive inherits *this*, not a mystery and a filing cabinet."

*Value: organizational visibility that outlives any term.*

## 2 · Act II — Steward (~13 min) · *the heart of the demo*
Log in as **Steward (C. Adeyemi)**.
1. **Caseload / assigned members** — "A steward sees their people and their cases — only theirs." *(quietly shows tenant + role isolation.)*
2. **Grievance workflow** — open **GRV-2026-0231** (M. Thibault, attendance discipline, Long-Term Care @ Northgate, Article 14). Walk `INTAKE → STEP_1 → STEP_2`; advance a stage. "Every status change is logged automatically, forever — an append-only case history."
3. **Deadlines** — the auto-computed contract clock + an approaching deadline with its notification. "The contract's timelines are tracked by the system, not by memory. Missed steps are how good grievances die."
4. **Documents** — the case's forms and evidence from the vault. "Everything for the case lives with the case."
5. **The money shot — institutional memory.** From GRV-2026-0231, search **Article 14** → the system surfaces **GRV-2021-0088**, the same-article case the Local *won five years ago, under a previous Executive and a steward who has since retired.* "This is the whole point. A brand-new steward argues from everything the Local has ever learned — on day one. The experience didn't retire when the person did."
6. **Case history / audit trail** — the immutable trail. "If this reaches arbitration, the record is complete and tamper-evident."

*Value: decades of hard-won experience, preserved and usable by whoever holds the role next.*

## 3 · Act III — Member (~5 min) · *what the member gets*
Log in as **Member (M. Thibault)**.
1. **Digital credential** — the card on the phone; **verify** (Verified / Not valid / Not found) by QR. "No app, no password. A rep verifies membership in seconds."
2. **Profile** — the member's own record, privacy-modelled. "Members see their own record — nobody else's."
3. **Communications & resources** — Local updates, the collective agreement, their steward. "The member's link to the Local."

*Value: modern, frictionless membership on top of the same system of record.*

## 4 · The close (~2 min)
Restate the core message, looking them in the eye:
> **"Everything you saw today survives your next election. The Union Hub keeps what the Local knows — the grievances, the precedent, the record — so the next officers and stewards build on decades of your experience instead of starting from zero."**

Then the honest pilot ask: *"We'd set this up for one of your units, by hand, and you tell us whether it earns its place."*

## 5 · Emphasize / avoid
- **Emphasize:** continuity across turnover; precedent from years ago (GRV-2021-0088); deadlines never missed; data stays in Canada and belongs to the Local; isolation ("only your Local, only your role").
- **Be honest about:** voting is shown as **sample historical records only** — not a live feature; aggregate stats are **labelled demo assumptions**; roadmap items are labelled roadmap. Union audiences spot overselling instantly — honesty is the differentiator.

## 6 · Timing
| Act | Min | Anchor |
|---|---|---|
| Setup (pre) | 2 | reset + tabs |
| Executive | 9 | visibility that outlives terms |
| Steward | 13 | **precedent + deadlines (the core)** |
| Member | 5 | card + verify |
| Close | 2 | continuity + pilot ask |
| **Total** | **~29** | under 30 |

## 7 · Prerequisite (honest note)
The Steward act assumes migrations `0022–0040` are applied **in the demo project** and the grievance UI is wired (Phase 4/5). Until then, run the Executive and Member acts (demonstrable on the current build) and present the Steward capabilities with roadmap framing rather than demoing something not live in the demo project.
