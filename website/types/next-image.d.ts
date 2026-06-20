// Ambient declarations for static image imports, e.g.
//   import logo from "@/public/images/logo.png";
// This mirrors the reference Next.js writes into the generated (and gitignored)
// next-env.d.ts, so `tsc --noEmit` can resolve image imports even on a clean
// checkout where no build has run yet (the CI typecheck runs before the build).
/// <reference types="next/image-types/global" />
