// Repository identity. Everything else is derived from these.
export const GITHUB_OWNER = "cadespivey";
export const GITHUB_PROJECT = "Supra-AI";

export const GITHUB_REPO_URL = `https://github.com/${GITHUB_OWNER}/${GITHUB_PROJECT}`;
export const GITHUB_RELEASES_URL = `${GITHUB_REPO_URL}/releases`;
export const GITHUB_ISSUES_URL = `${GITHUB_REPO_URL}/issues`;

// GitHub Releases API for the newest published release. The DownloadButtons
// component reads this at runtime so the download links always resolve to the
// current .dmg / .zip without a code change each release.
export const GITHUB_LATEST_RELEASE_API = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_PROJECT}/releases/latest`;

// Pinned fallback used for the server-rendered markup, for visitors without
// JavaScript, and if the GitHub API is unreachable. Bump on each release (or
// wire the release workflow to update it); the runtime fetch normally takes
// over and points at whatever the latest release actually is.
export const FALLBACK_RELEASE_TAG = "v1.8.0";
export const FALLBACK_RELEASE_VERSION = "1.8.0";
export const DOWNLOAD_DMG_URL = `${GITHUB_REPO_URL}/releases/download/${FALLBACK_RELEASE_TAG}/SupraAI-${FALLBACK_RELEASE_VERSION}.dmg`;
export const DOWNLOAD_ZIP_URL = `${GITHUB_REPO_URL}/releases/download/${FALLBACK_RELEASE_TAG}/SupraAI-${FALLBACK_RELEASE_VERSION}.zip`;
