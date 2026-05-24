/* ──────────────────────────────────────────────────────────────────────────
   /middleware.js
   Vercel scans this exact path at the project root for edge middleware on
   non-framework deployments. The real logic lives in api/_middleware.js so
   the directory map in README.md matches the codebase; this file is a
   one-line shim that re-exports.
   ────────────────────────────────────────────────────────────────────────── */
export { default, config } from './api/_middleware.js';
