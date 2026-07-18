# DEMO SCRIPT — The Union Hub

**Phase 12** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Audience:** a salesperson runs it; a union executive understands the value in **≤30 minutes**. Uses the Local 5000 demo tenant (`DEMO_ENVIRONMENT.md`).
**Thesis (say it, then prove it):** *The Union Hub is the system of record for what your Local knows — so the experience that wins grievances survives every election, retirement, and turnover.* Lead with continuity, not features.

---

## 0 · Before the demo (2 min, off-camera)
- Run `./reset-demo.sh` → clean Local 5000 state.
- Have three tabs ready, logged in: **Executive**, **Steward (E. Vance)**, **Member (Jordan Rivera)**.
- Open on the **public site** (`local5000.demo…`) so they see the Local's own front door first.
- **Framing line to open with:** "I'm going to show you three views — an officer's, a steward's, and a member's. Watch for one thing: nothing here depends on a particular person still being in the role."

## 1 · Act I — Executive view (~10 min) · *"What the Local can see about itself"*
Log in as **Executive**.
1. **Local dashboard.** Membership overview (15,000 across 8 units, 5 employers), active issues, steward activity. **Say:** "This is the whole Local at a glance — and it's the same view for whoever's elected next."
2. **Membership overview.** Filter by unit/employer. **Say:** "The roster is the Local's, not a spreadsheet on someone's laptop. It's here after they're gone."
3. **Active issues + steward activity.** Show open grievances by stage, deadlines approaching, which stewards are carrying load. **Say:** "An incoming Executive inherits *this*, not a mystery."
4. **The continuity moment.** Point to a closed historical grievance from years ago. **Say:** "The officer who won that has retired. The knowledge didn't leave with them."

*Value landed: organizational visibility that outlives any term.*

## 2 · Act II — Steward view (~12 min) · *the heart of the demo*
Log in as **Steward (E. Vance)**.
1. **Assigned members / caseload.** Show coverage. **Say:** "A steward sees their people and their cases — and only theirs." *(quietly demonstrates tenant + role isolation.)*
2. **Grievance workflow.** Open **Marcus Bennett — GRV-2026-0147** (attendance discipline). Walk the lifecycle `INTAKE → STEP_1 → STEP_2 → …`. Advance a stage. **Say:** "Every status change is logged, automatically, forever — an append-only case history."
3. **Deadlines.** Show the auto-computed SLA clock and an approaching deadline with its notification. **Say:** "The contract's timelines are tracked by the system, not by memory. Missed steps are how good grievances die."
4. **Documents.** Open the grievance's documents (forms, evidence) from the vault. **Say:** "Everything for this case lives with the case."
5. **The 'how did we handle this last time?' moment — the money shot.** Search the CBA article at issue → the system surfaces **past grievances on the same article** (precedent) including older, closed cases. **Say:** "This is the institutional memory. A brand-new steward argues from everything the Local has ever learned — on day one."
6. **Case history.** Show the full immutable trail on a case. **Say:** "If this ever goes to arbitration, the record is complete and tamper-evident."

*Value landed: the Local's hard-won experience is preserved, searchable, and usable by whoever holds the role next.*

## 3 · Act III — Member view (~5 min) · *"What the member gets"*
Log in as **Member (Jordan Rivera)**.
1. **Digital member credential.** Open the card on the phone. Show **verify** (Verified / Not valid / Not found) via QR. **Say:** "No app, no password. A rep verifies membership in seconds."
2. **Profile.** Member's own info; privacy-modelled. **Say:** "Members see their own record — nobody else's."
3. **Communications & resources.** Local updates, the collective agreement, contacts. **Say:** "The member's link to the Local — the CA, their steward, the latest."

*Value landed: modern, frictionless membership on top of the same system of record.*

## 4 · The 30-minute close (1–2 min)
One line, looking them in the eye: **"Everything you just saw survives your next election. The Union Hub keeps what the Local knows — the grievances, the precedent, the record — so the next Executive builds on your work instead of starting over."**

Then the honest ask (the pilot motion from the strategy work): *"We'd set this up for one of your units, by hand, and you tell us if it earns its place."*

## 5 · What to emphasize / avoid
- **Emphasize:** continuity across turnover; precedent search; deadlines never missed; data stays in Canada and belongs to the Local; isolation ("only your Local, only your role").
- **Avoid / be honest about:** voting is shown as **sample historical records only** — do not imply a live ballot feature ships today; aggregate stats are **labelled demo assumptions**; anything on the roadmap is labelled roadmap. Union people spot overselling instantly — honesty is the differentiator.

## 6 · Timing
| Act | Minutes | Anchor |
|---|---|---|
| Setup | 2 (pre) | reset + tabs |
| Executive | 10 | visibility that outlives terms |
| Steward | 12 | precedent + deadlines (the core) |
| Member | 5 | card + verify |
| Close | 2 | continuity + pilot ask |
| **Total** | **~29** | under 30 |

## 7 · Prerequisite (honest note)
This script assumes migrations `0022–0040` are applied in the **demo** project and the grievance UI is wired (Phase 4/5). Until then, the Steward act runs on the demo dataset as it becomes available; the Executive and Member acts are demonstrable on the current build. Don't demo a capability that isn't live in the demo project — substitute the roadmap framing instead.
