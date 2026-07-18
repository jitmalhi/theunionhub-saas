# Security Validation — Operator Guide (run it yourself)

**Who this is for:** you (the founder). No coding required — you'll create a throwaway test database, run **one script**, and send back **one file**. About **20–30 minutes**, most of it waiting for the database to set up.

**What you're proving:** that one union cannot see another union's data. The script tests the system **before** the fix (some tests *should fail* — that's proof the test works) and **after** the fix (everything *should pass*).

**Safety, up front:**
- You will use a **brand-new throwaway Supabase project**, not production. The script **refuses to run against production**.
- The results file you send back contains **no passwords** — it's safe to paste to me.
- You never touch the live site.

**The gate (unchanged):** I will only mark validation complete and unblock the Security Model if the results show **baseline failed the vulnerable tests AND the fix made everything pass**. Expected is not observed — your run is the evidence.

---

## Part 1 — One-time setup (≈10 min)

### 1a. Install Node.js
1. Go to **https://nodejs.org** → download the **LTS** version → run the installer → click Next through the defaults.
2. To check it worked, you'll use a terminal in the next step.

### 1b. Install Git for Windows (gives you "Git Bash", the terminal you'll type in)
1. Go to **https://git-scm.com/download/win** → the download starts → run it → **click Next through all defaults**.
2. When done, click the Windows Start button, type **`Git Bash`**, and open it. A black terminal window appears. This is where you paste commands.

### 1c. Get the project ready
In the **Git Bash** window, copy/paste these **one line at a time** (press Enter after each):
```bash
cd /c/X/steward-system
node -v
npm install
npx --no-install supabase --version
```
- `node -v` should print something like `v20.x`.
- `npm install` may take a minute (it's fetching the tools). Wait for it to finish.
- The last line should print a version like `2.109.0`. If it does, setup is done. ✅

---

## Part 2 — Create the throwaway test database (≈5 min)

1. Go to **https://supabase.com** and sign in (create a free account if needed).
2. Click **New project**.
   - **Name:** `unionhub-staging-test`
   - **Database Password:** click **Generate a password**, then **copy it and paste it into a temporary note** — you'll need it in Part 3.
   - **Region:** **Canada (Central)**.
   - Click **Create new project** and **wait ~2 minutes** while it sets up (green = ready).
3. Get the **connection string**:
   - In the project, click **Connect** (top bar) → find **Session pooler** → copy the URI. It looks like:
     ```
     postgresql://postgres.abcdefgh:[YOUR-PASSWORD]@aws-0-ca-central-1.pooler.supabase.com:5432/postgres
     ```
   - Replace **`[YOUR-PASSWORD]`** with the password you saved in step 2. Keep this full line handy for Part 3.
   - *(If you have trouble connecting later, come back and copy the "Direct connection" string instead — Part 7 troubleshooting explains.)*
4. Get the **project ref**: it's the code right after `postgres.` in that string (e.g. `abcdefgh`), and it's also in your project URL (`https://supabase.com/dashboard/project/abcdefgh`). Keep it handy.

> This is a disposable test project. You'll delete it at the end (Part 6).

---

## Part 3 — Run the validation (≈5 min)

In the **Git Bash** window, paste these. **Replace the two values in quotes** with *your* project ref and *your* connection string from Part 2:

```bash
cd /c/X/steward-system
export PROJECT_REF='PASTE-YOUR-PROJECT-REF-HERE'
export DATABASE_URL='PASTE-YOUR-FULL-CONNECTION-STRING-HERE'
export CONFIRM_STAGING=1
```

**Test the connection first** (this should print a small result, not an error):
```bash
npx --no-install supabase db query --db-url "$DATABASE_URL" "select 1 as ok"
```
- If you see a result (a `1`), you're connected. ✅ Continue.
- If you see a connection error, jump to **Part 7 — Troubleshooting**.

**Now run the validation:**
```bash
bash scripts/run-security-validation.sh
```

**What you'll see (this is normal):**
1. It confirms your target is **not** production and is empty.
2. **Baseline:** it applies the older database version, then runs the tests. **Several tests will say `FAIL`** here — *this is correct and expected.* It means the tests successfully detect the security gap.
3. **Fix:** it applies migration `0041`.
4. **Final:** it runs all the tests again. **They should all say `PASS`.**
5. At the end it prints a **summary** with a line that says either **`GATE RESULT: PASS`** or **`GATE RESULT: NOT PASSED`**.

Let it run to the end (a few minutes). Don't close the window until it prints the summary.

---

## Part 4 — Where to find the results

The script saved everything in a folder:
```
C:\X\steward-system\validation-results\
```
- **`summary.md`** ← **this is the file to send me** (a short table + the gate result; **no passwords**).
- `baseline.log`, `fixed.log` — full detail (keep these in case we need to dig in).

To open the summary quickly, paste this in Git Bash:
```bash
cat validation-results/summary.md
```

---

## Part 5 — How to send the results back

1. Run `cat validation-results/summary.md` (above), **select all the text it prints, copy it**, and **paste it into our chat**.
   - Or open `C:\X\steward-system\validation-results\summary.md` in Notepad, copy everything, paste it to me.
2. That's it. The summary is credential-free — it never contains your password or connection string.

I'll then record your **observed** results into `TENANT_SECURITY_VALIDATION.md`, complete the sign-off, and — only if the gate passed — unblock the Security Model.

---

## Part 6 — Clean up (after you send results)

1. In the Supabase dashboard, open the `unionhub-staging-test` project → **Settings → General → Delete project**. It's gone; nothing lingers.
2. You can delete the temporary note with the password.
3. You never touched production, and no credentials were stored by the script or sent to me.

---

## Part 7 — Troubleshooting (common messages)

| You see… | What it means / do this |
|---|---|
| `ABORT: … matches the PRODUCTION project ref` | You pasted the live project by mistake. Use the **new throwaway** project's ref/string. |
| `ABORT: … not an empty database` | You pointed at a project that already has data. Create a **fresh** project (Part 2). |
| `ABORT: set CONFIRM_STAGING=1` | You skipped the `export CONFIRM_STAGING=1` line. Paste it and re-run. |
| Connection error / timeout on the `select 1` test | Go back to Supabase **Connect**, copy the **Direct connection** string instead of Session pooler (or vice-versa), redo the `export DATABASE_URL=…` line, and re-test. |
| `npx: command not found` | Node.js didn't install — redo Part 1a, close and reopen Git Bash. |
| Baseline shows tests **PASS** that we expected to FAIL | Tell me — that would mean the tests aren't detecting the gap, which we must investigate before trusting a "pass." |
| Final (`0041`) shows any **FAIL** | Tell me — we treat it as a **real security finding**: fix it and rerun. Do not proceed. |

---

## Appendix — Optional: local database with Docker (only if you prefer not to use a cloud project)
Not required — the cloud path above is simpler. If you'd rather run entirely on your own machine, install **Docker Desktop** (https://www.docker.com/products/docker-desktop), then tell me and I'll give you the local-database variant of the commands (it needs a slightly different setup to keep the before/after separation). For most people, the throwaway cloud project is the easiest route.

---

**Remember the standard:** the goal isn't to make Union Hub *look* secure — it's to *prove* it. Your run is the proof. Send me `summary.md` and we close the gate together.
