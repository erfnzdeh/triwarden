/* Version, size, and release-notes text are baked at build time, so they go stale until the next
   site deploy even when the download URL is the fixed releases/latest/download/Triwarden.dmg.
   Refresh whenever any of these markers is on the page — not only [data-dmg]. A stable-named
   asset is not a reason to skip this: the file URL can stay fixed while the label text cannot.
   sessionStorage paints the last known release immediately; the fetch always runs and overwrites it,
   including in a tab left open across a publish. */
import { $$ } from "./motion";
import { SITE } from "../config";

type Rel = { version: string; dmg: string; size: number; notes: string };
type Asset = { name: string; browser_download_url: string; size: number };
type Payload = { tag_name?: string; html_url?: string; assets?: Asset[] };

/** Map a GitHub latest-release payload to the fields the page shows. Null when it has no DMG. */
export const releaseFromPayload = (d: Payload | null): Rel | null => {
  if (!d?.tag_name || !d.html_url) return null;
  const assets = d.assets ?? [];
  const fixed = assets.find((x) => x.name === "Triwarden.dmg");
  const dmg = fixed ?? assets.find((x) => /\.dmg$/i.test(x.name));
  if (!dmg) return null;
  return {
    version: String(d.tag_name).replace(/^v/, ""),
    dmg: fixed ? SITE.latestDmg : dmg.browser_download_url,
    size: dmg.size,
    notes: d.html_url,
  };
};

const isRel = (v: unknown): v is Rel => {
  if (!v || typeof v !== "object") return false;
  const r = v as Rel;
  return typeof r.version === "string" && typeof r.dmg === "string" && typeof r.size === "number" && typeof r.notes === "string";
};

const apply = (r: Rel) => {
  $$<HTMLAnchorElement>("[data-dmg]").forEach((a) => (a.href = r.dmg));
  $$<HTMLAnchorElement>("[data-dmg-notes]").forEach((a) => (a.href = r.notes));
  $$("[data-dmg-version]").forEach((el) => (el.textContent = r.version));
  $$("[data-dmg-size]").forEach((el) => (el.textContent = `${(r.size / 1_000_000).toFixed(1)} MB`));
  $$("[data-dmg-mb]").forEach((el) => {
    el.dataset.count = String(r.size / 1_000_000);
    el.textContent = (r.size / 1_000_000).toFixed(Number(el.dataset.digits ?? 1));
  });
};

const markers = "[data-dmg], [data-dmg-version], [data-dmg-size], [data-dmg-notes], [data-dmg-mb]";

const start = () => {
  if (typeof document === "undefined" || !$$(markers).length) return;
  try {
    const cached = sessionStorage.getItem("release");
    if (cached) {
      const parsed: unknown = JSON.parse(cached);
      if (isRel(parsed)) apply(parsed);
    }
  } catch { /* a bad cache must not block the fetch */ }
  fetch(`${SITE.api}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((res) => (res.ok ? res.json() : null))
    .then((d: Payload | null) => {
      const r = releaseFromPayload(d);
      if (!r) return;
      apply(r);
      try { sessionStorage.setItem("release", JSON.stringify(r)); } catch { /* private mode */ }
    })
    .catch(() => {});
};

start();
