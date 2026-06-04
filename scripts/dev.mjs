#!/usr/bin/env node
/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · scripts/dev.mjs
   Cross-platform static-server launcher for local development.

   Why this exists:
     `vercel dev` invokes its @vercel/static-build child via `npm run dev`
     and tells the child to bind to a specific port via $PORT. If the child
     binds to anything else, vercel dev times out with "Failed to detect a
     server running on port N." A literal `serve -l 3000` in package.json
     ignored that handshake and broke local dev.

     This script reads PORT (falls back to 3000 for direct `npm run dev`
     use) and forwards it to `serve`.
   ────────────────────────────────────────────────────────────────────────── */
import { spawn } from 'node:child_process';

const port = process.env.PORT || '3000';
const child = spawn('npx', ['--yes', 'serve@latest', '-l', port], {
  stdio: 'inherit',
  shell: true,
});
child.on('exit', (code) => process.exit(code ?? 0));
