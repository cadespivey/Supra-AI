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

`build:pages` sets `STATIC_EXPORT=1`, which enables `output: "export"`. The site
ships from the apex domain root, so there is **no `basePath`** — assets resolve
from `/`. Plain `npm run dev` / `npm run build` also serve from root.

## Deployment

Pushes to `main` that touch `website/**` trigger the GitHub Pages workflow.
The site is served from the apex custom domain:

> https://supralegal.ai/

The custom domain is pinned by [`public/CNAME`](public/CNAME) (Next.js copies
`public/` into `out/`, so the `CNAME` ships in every Pages artifact and the
domain survives each Actions deploy) plus the repo's **Settings → Pages** custom
domain and the Porkbun DNS records.

**First-time setup (one click in the GitHub UI):**
Repo **Settings → Pages → Build and deployment → Source → "GitHub Actions"**.

## Structure

- `app/` — routes (`/`, `/product`, `/download`, `/privacy-security`,
  `/disclaimer`, `/privacy`, `/terms`) plus `layout.tsx` and `globals.css`.
- `components/` — page sections and shared UI.
- `lib/` — site constants (download/GitHub URLs) and local font definitions.
- `public/` — fonts, images, and favicon.
