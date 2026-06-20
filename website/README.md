# Supra AI — Marketing Website

The public marketing site for Supra AI, built with [Next.js](https://nextjs.org)
(App Router) and [Tailwind CSS v4](https://tailwindcss.com). It is statically
exported and deployed to GitHub Pages by
[`.github/workflows/deploy-website.yml`](../.github/workflows/deploy-website.yml).

## Local development

```bash
cd website
npm install
npm run dev          # http://localhost:3000
```

## Build

```bash
npm run build:pages  # static export to website/out/ (used by CI)
```

`build:pages` sets `STATIC_EXPORT=1`, which enables `output: "export"` and the
`/Supra-AI` `basePath` in `next.config.ts`. Plain `npm run dev` / `npm run build`
serve from the root with no basePath, which is more convenient locally.

## Deployment

Pushes to `main` that touch `website/**` trigger the GitHub Pages workflow.
The site is served from the project subpath:

> https://cadespivey.github.io/Supra-AI/

**First-time setup (one click in the GitHub UI):**
Repo **Settings → Pages → Build and deployment → Source → "GitHub Actions"**.

### Moving to the custom domain (supralegal.ai)

1. In `next.config.ts`, set `basePath` to `""` (or remove it).
2. Add `website/public/CNAME` containing a single line: `supralegal.ai`.
3. Update `metadataBase` in `app/layout.tsx` to `https://supralegal.ai`.
4. At Porkbun, point the apex domain at GitHub Pages (ALIAS/ANAME →
   `cadespivey.github.io`, or the four GitHub Pages `A` records), and set the
   custom domain under **Settings → Pages**. Detach the domain from the old
   `supralegal.ai` repo first — only one Pages site can claim it.

## Structure

- `app/` — routes (`/`, `/product`, `/download`, `/privacy-security`,
  `/disclaimer`, `/privacy`, `/terms`) plus `layout.tsx` and `globals.css`.
- `components/` — page sections and shared UI.
- `lib/` — site constants (download/GitHub URLs) and local font definitions.
- `public/` — fonts, images, and favicon.
