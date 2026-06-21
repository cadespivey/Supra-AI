import type { NextConfig } from "next";

// Static export for GitHub Pages.
// The site is served from the apex custom domain https://supralegal.ai/ (root),
// so no basePath is set — assets resolve from "/" (e.g. /_next/static/...).
// The custom domain is pinned by website/public/CNAME (copied into out/ on every
// build) plus the GitHub repo's Pages settings + DNS.
const isStaticExport = process.env.STATIC_EXPORT === "1";

const nextConfig: NextConfig = {
  ...(isStaticExport
    ? {
        output: "export",
        trailingSlash: true,
        images: {
          unoptimized: true,
        },
      }
    : {}),
};

export default nextConfig;
