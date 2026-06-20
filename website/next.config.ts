import type { NextConfig } from "next";

// Static export for GitHub Pages.
// The site is currently served from the project subpath
// https://cadespivey.github.io/Supra-AI/, so it needs a basePath.
// To move to the apex domain (https://supralegal.ai):
//   1. Set basePath to "" (or delete the property).
//   2. Add a CNAME file in public/ containing `supralegal.ai`.
//   3. Point Porkbun DNS at GitHub Pages and set the custom domain in repo settings.
const isStaticExport = process.env.STATIC_EXPORT === "1";

const nextConfig: NextConfig = {
  ...(isStaticExport
    ? {
        output: "export",
        basePath: "/Supra-AI",
        trailingSlash: true,
        images: {
          unoptimized: true,
        },
      }
    : {}),
};

export default nextConfig;
