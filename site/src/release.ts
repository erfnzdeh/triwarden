/** The newest GitHub release, looked up once per build.
    When that release carries Triwarden.dmg (scripts/release.sh), pages link the fixed
    releases/latest/download/Triwarden.dmg. That URL always names the newest file, but version, size,
    and notes in the HTML are still from this lookup and go stale until the next site build.
    scripts/release.ts refreshes those in the browser on every visit — do not skip it because `stable` is true.
    Until the latest release has the stable-named file, pages link its versioned DMG and the client
    script points download anchors at that asset. If the lookup fails entirely, the fixed link is still
    right once a release has it; before that, the releases page. */
import { SITE } from "./config";

export type Release = { version: string; dmg: string; size: number; notes: string; stable: boolean };

let cached: Promise<Release | null> | undefined;

export const latestRelease = () =>
  (cached ??= (async () => {
    try {
      const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
      const token = import.meta.env.GITHUB_TOKEN ?? process.env.GITHUB_TOKEN;
      if (token) headers.Authorization = `Bearer ${token}`;
      const res = await fetch(`${SITE.api}/releases/latest`, { headers });
      if (!res.ok) return null;
      const d = await res.json();
      const assets: { name: string; browser_download_url: string; size: number }[] = d.assets ?? [];
      const fixed = assets.find((a) => a.name === "Triwarden.dmg");
      const dmg = fixed ?? assets.find((a) => /\.dmg$/i.test(a.name));
      if (!dmg) return null;
      return {
        version: String(d.tag_name).replace(/^v/, ""),
        dmg: fixed ? SITE.latestDmg : dmg.browser_download_url,
        size: dmg.size,
        notes: d.html_url,
        stable: Boolean(fixed),
      };
    } catch {
      return null;
    }
  })());

export const formatSize = (bytes: number) => `${(bytes / 1_000_000).toFixed(1)} MB`;
