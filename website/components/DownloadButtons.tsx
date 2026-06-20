"use client";

import { useEffect, useState } from "react";
import {
  DOWNLOAD_DMG_URL,
  DOWNLOAD_ZIP_URL,
  FALLBACK_RELEASE_TAG,
  GITHUB_LATEST_RELEASE_API,
} from "@/lib/constants";

type ReleaseAsset = {
  name: string;
  browser_download_url: string;
};

type ReleaseState = {
  dmgUrl: string;
  zipUrl: string;
  tag: string;
  resolved: boolean;
};

const FALLBACK: ReleaseState = {
  dmgUrl: DOWNLOAD_DMG_URL,
  zipUrl: DOWNLOAD_ZIP_URL,
  tag: FALLBACK_RELEASE_TAG,
  resolved: false,
};

export function DownloadButtons() {
  const [release, setRelease] = useState<ReleaseState>(FALLBACK);

  useEffect(() => {
    const controller = new AbortController();

    async function loadLatest() {
      try {
        const res = await fetch(GITHUB_LATEST_RELEASE_API, {
          signal: controller.signal,
          headers: { Accept: "application/vnd.github+json" },
        });
        if (!res.ok) return;

        const data: { tag_name?: string; assets?: ReleaseAsset[] } =
          await res.json();
        const assets = data.assets ?? [];
        const dmg = assets.find((a) => a.name.toLowerCase().endsWith(".dmg"));
        const zip = assets.find((a) => a.name.toLowerCase().endsWith(".zip"));

        // Only adopt the live release if it actually carries the assets we
        // expect; otherwise the pinned fallback links stay in place.
        if (dmg || zip) {
          setRelease({
            dmgUrl: dmg?.browser_download_url ?? DOWNLOAD_DMG_URL,
            zipUrl: zip?.browser_download_url ?? DOWNLOAD_ZIP_URL,
            tag: data.tag_name ?? FALLBACK_RELEASE_TAG,
            resolved: true,
          });
        }
      } catch {
        // Network/API failure: keep the pinned fallback links.
      }
    }

    loadLatest();
    return () => controller.abort();
  }, []);

  return (
    <div>
      <div className="flex flex-wrap gap-3">
        <a
          href={release.dmgUrl}
          className="inline-flex flex-col rounded-xl border border-supra-gold bg-supra-gold px-5 py-3 text-supra-navyDeep transition hover:bg-supra-white"
        >
          <span className="text-base font-bold">Download .dmg</span>
          <span className="font-caps text-xs uppercase tracking-wide opacity-80">
            Recommended · drag to install
          </span>
        </a>
        <a
          href={release.zipUrl}
          className="inline-flex flex-col rounded-xl border border-supra-border px-5 py-3 text-supra-white transition hover:border-supra-gold hover:text-supra-gold"
        >
          <span className="text-base">Download .zip</span>
          <span className="font-caps text-xs uppercase tracking-wide text-supra-muted">
            Plain app bundle
          </span>
        </a>
      </div>

      <p className="mt-4 text-sm text-supra-muted">
        {release.resolved ? "Latest release" : "Current release"}:{" "}
        <span className="text-supra-white">{release.tag}</span> · Apple Silicon,
        macOS 15+
      </p>
    </div>
  );
}
