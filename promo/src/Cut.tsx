import React from "react";
import { AbsoluteFill, Img, Sequence, staticFile, useCurrentFrame } from "remotion";
import { Dial, RINGS } from "./Dial";
import { C, inOut, mono, sans, serif, tween } from "./theme";
import { Crop, Kbd, Paper } from "./ui";

/* The film, cut to the music: 120 BPM at 30 fps is 15 frames a beat, 60 a bar. Every cut lands on a downbeat, every
   word and key on a beat. Scenes are hard cuts with a quick punch-in, not cross-fades. scripts/soundtrack.py places
   the drop and the hits from the same grid (CUT below). */
import cuts from "./cuts.json";

export const BEAT = cuts.beat;
export const BAR = 4 * BEAT;
export type CutName = "short" | "film";
export const cutFrames = (name: CutName) => cuts[name].bars * BAR;

type Tri = [number, number, number];

/** A quick punch-in on a cut: starts a little large and settles in a third of a beat. */
const punch = (f: number, at = 0, amt = 0.07) => 1 + amt * (1 - tween(f, at, at + 9, 0, 1));

/** Words that rise out of a mask, each on its own frame. Masks leave room below the baseline for descenders. */
const Words: React.FC<{ words: [string, number][]; size: number; color?: string; italic?: boolean; align?: "left" | "center" }> = ({ words, size, color = C.ink, italic, align = "left" }) => {
  const f = useCurrentFrame();
  return (
    <div style={{ font: `400 ${size}px/1 ${serif}`, fontStyle: italic ? "italic" : "normal", letterSpacing: "-.025em", color, textAlign: align, display: "flex", flexWrap: "wrap", gap: `0 ${size * 0.24}px`, justifyContent: align === "center" ? "center" : "flex-start" }}>
      {words.map(([w, at]) => (
        <span key={w + at} style={{ display: "inline-block", overflow: "hidden", padding: `0.06em 0 0.24em`, margin: "0 0 -0.18em" }}>
          <span style={{ display: "inline-block", transform: `translateY(${tween(f, at, at + 8, 115, 0)}%)` }}>{w}</span>
        </span>
      ))}
    </div>
  );
};

const Label: React.FC<{ at: number; children: React.ReactNode; color?: string }> = ({ at, children, color = C.ink3 }) => {
  const f = useCurrentFrame();
  return <div style={{ font: `500 22px ${mono}`, letterSpacing: ".18em", textTransform: "uppercase", color, opacity: tween(f, at, at + 6, 0, 1) }}>{children}</div>;
};

const shot = (name: string, width: number, style?: React.CSSProperties) => (
  <Img src={staticFile(`shots/${name}.png`)} style={{ width, display: "block", ...style }} />
);

/* ── Hook: the promise, a word a beat ── */
const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const b = (n: number) => n * BEAT;
  return (
    <Paper>
      <AbsoluteFill style={{ display: "grid", placeItems: "center", transform: `scale(${tween(f, 0, BAR * 2, 1, 1.06)})` }}>
        <div>
          <Words size={150} align="center" words={[["Your", b(0)], ["passwords", b(1)], ["deserve", b(2)]]} />
          <Words size={150} italic align="center" color={C.ink3} words={[["a", b(4)], ["native", b(4) + 4], ["Mac", b(5)], ["app.", b(6)]]} />
        </div>
      </AbsoluteFill>
    </Paper>
  );
};

/* ── Dial: the rings click into line on beats 2, 3 and 4, then we dive through the keyhole ── */
const DialCut: React.FC = () => {
  const f = useCurrentFrame();
  const alignAt = [3 * BEAT, 2 * BEAT, BEAT]; // inside first
  const rot = RINGS.map((g, i) => g.apart * 1.6 * (1 - tween(f, alignAt[i] - 6, alignAt[i], 0, 1, inOut))) as Tri;
  const dive = tween(f, BAR - 8, BAR, 1, 9, inOut);
  return (
    <Paper>
      <AbsoluteFill style={{ display: "grid", placeItems: "center" }}>
        <div style={{ transform: `scale(${tween(f, 0, 8, 0.82, 1) * dive})`, transformOrigin: "50% 52%" }}>
          <Dial size={820} rot={rot} hub={1 + 0.08 * Math.max(0, 1 - Math.abs(f - 3 * BEAT) / 4)} bezel bezelRot={tween(f, 0, BAR, -20, 20)} />
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "#fff", opacity: tween(f, BAR - 4, BAR, 0, 1) }} />
    </Paper>
  );
};

/* ── Vault: the drop. The real window slams in and keeps drifting. ── */
const VaultCut: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <Paper>
      <AbsoluteFill style={{ background: "#fff", opacity: tween(f, 0, 6, 1, 0) }} />
      <div style={{ position: "absolute", left: 960 - 800, top: 250, transform: `scale(${punch(f, 0, 0.12) * tween(f, 0, 2 * BAR, 1, 1.05)})`, transformOrigin: "70% 20%" }}>
        {shot("vault-light", 1600)}
      </div>
      <div style={{ position: "absolute", left: 160, top: 80 }}>
        <Label at={BEAT}>Native on your Mac</Label>
        <div style={{ height: 18 }} />
        <Words size={92} words={[["Every", 2 * BEAT], ["login.", 2 * BEAT + 5], ["Every", 4 * BEAT], ["passkey.", 4 * BEAT + 5]]} />
      </div>
    </Paper>
  );
};

/* ── Search: zoom onto the field on beat 2; the filters pop a beat each ── */
const SearchCut: React.FC = () => {
  const f = useCurrentFrame();
  const z = tween(f, BEAT, 2 * BEAT, 1.05, 1.5, inOut);
  const tokens = ["type:card", "is:favorite", "has:passkey", "#Work"];
  return (
    <Paper>
      <div style={{ position: "absolute", left: 960 - 680, top: 250, width: 1360, height: 690, overflow: "hidden", borderRadius: 26, transform: `scale(${punch(f)})`, boxShadow: "0 0 0 1.5px rgba(11,42,64,.12), 0 60px 120px -50px rgba(11,42,64,.5)" }}>
        <div style={{ position: "absolute", inset: 0, transform: `scale(${z})`, transformOrigin: "12.5% -10%" }}>
          <Img src={staticFile("shots/search-light.png")} style={{ position: "absolute", width: 1360 * (2704 / 2480), left: -112 * (1360 / 2480), top: -76 * (1360 / 2480), maxWidth: "none" }} />
        </div>
      </div>
      <div style={{ position: "absolute", left: 160, top: 80 }}>
        <Label at={0}>New · Search</Label>
        <div style={{ height: 18 }} />
        <Words size={92} words={[["One", BEAT], ["search.", BEAT + 5], ["Every", 2 * BEAT], ["vault.", 2 * BEAT + 5]]} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 52, display: "flex", justifyContent: "center", gap: 34, font: `500 30px ${mono}`, color: C.ink }}>
        {tokens.map((t, i) => {
          const at = (4 + i) * BEAT;
          return <span key={t} style={{ opacity: tween(f, at, at + 4, 0, 1), transform: `translateY(${tween(f, at, at + 8, 18, 0)}px) scale(${punch(f, at, 0.25)})` }}>{t}</span>;
        })}
      </div>
    </Paper>
  );
};

/* ── Palette: ⇧ ⌘ Space go down on beats 1–3; the palette lands on beat 5 ── */
const PaletteCut: React.FC = () => {
  const f = useCurrentFrame();
  const keys = ["⇧", "⌘", "Space"];
  const pal = tween(f, 4 * BEAT, 4 * BEAT + 9, 0, 1);
  return (
    <Paper>
      {pal < 1 && (
        <AbsoluteFill style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 30, opacity: 1 - pal, transform: `scale(${1 + 0.15 * pal})` }}>
          {keys.map((k, i) => {
            const at = i * BEAT;
            const down = Math.max(0, 1 - Math.abs(f - at - 3) / 4);
            return (
              <div key={k} style={{ opacity: tween(f, at, at + 3, 0, 1), transform: `translateY(${10 * down}px) scale(${tween(f, at, at + 6, 1.3, 1)})` }}>
                <Kbd size={190} style={{ fontSize: 80, minWidth: k === "Space" ? 420 : 190, background: down > 0.2 ? C.sky : C.card, color: C.ink }}>{k}</Kbd>
              </div>
            );
          })}
        </AbsoluteFill>
      )}
      <div style={{ position: "absolute", left: 960 - 530, top: 250, opacity: pal, transform: `translateY(${(1 - pal) * 60}px) scale(${0.96 + 0.04 * pal})` }}>
        <Crop src="shots/palette-focus-light.png" rect={[450, 358, 1800, 1380]} width={1060} zoom={tween(f, 4 * BEAT, 2 * BAR, 1, 1.05)} />
      </div>
      <div style={{ position: "absolute", left: 160, top: 80, opacity: pal }}>
        <Label at={4 * BEAT}>From any app</Label>
        <div style={{ height: 18 }} />
        <Words size={92} words={[["The", 5 * BEAT], ["right", 5 * BEAT + 3], ["login,", 5 * BEAT + 6], ["already", 6 * BEAT], ["there.", 6 * BEAT + 5]]} />
      </div>
    </Paper>
  );
};

/* ── Auto-type: each key lights on its beat ── */
const AutoTypeCut: React.FC = () => {
  const f = useCurrentFrame();
  const rows: [string[], string][] = [[["↵"], "Username + password"], [["⌃", "↵"], "Username"], [["⌥", "↵"], "Password"], [["⌥", "⌘", "\\"], "From anywhere"]];
  return (
    <Paper>
      <div style={{ position: "absolute", left: 160, top: 300, width: 760 }}>
        <Label at={0}>Auto-type</Label>
        <div style={{ height: 18 }} />
        <Words size={104} words={[["It", 0], ["types", 4], ["it", 8], ["in.", 12]]} />
        <Words size={104} italic color={C.ink3} words={[["Any", BEAT], ["app.", BEAT + 5]]} />
      </div>
      <div style={{ position: "absolute", left: 1040, top: 260, width: 720, display: "grid", gap: 18 }}>
        {rows.map(([keys, label], i) => {
          const at = i * BEAT;
          const lit = f >= at && f < at + BEAT;
          return (
            <div key={label} style={{ display: "grid", gridTemplateColumns: "200px 1fr", alignItems: "center", gap: 24, opacity: tween(f, at - 4, at, 0.25, 1), transform: `scale(${punch(f, at, 0.06)})`, transformOrigin: "0 50%" }}>
              <span style={{ display: "flex", gap: 8 }}>{keys.map((k) => <Kbd key={k} size={62} style={{ fontSize: 28, background: lit ? C.sky : C.card, color: C.ink }}>{k}</Kbd>)}</span>
              <span style={{ font: `500 32px ${sans}`, color: lit ? C.ink : C.ink2 }}>{label}</span>
            </div>
          );
        })}
      </div>
    </Paper>
  );
};

/* ── Montage: a new feature every two beats ── */
type Beat = { word: string; sub: string; visual: () => React.ReactNode; dark?: boolean; wide?: boolean };
const M: Record<string, Beat> = {
  // Whole windows, never cropped: every card in view.
  codes: { word: "One-time codes.", sub: "Every code, one glance", wide: true, visual: () => shot("codes-light", 1080) },
  watchtower: { word: "Watchtower.", sub: "Breached and reused, flagged", wide: true, visual: () => shot("watchtower-light", 1080) },
  menubar: { word: "Menu bar.", sub: "One click from any app", visual: () => <div style={{ width: 300, height: 568, borderRadius: 22, overflow: "hidden", boxShadow: "0 0 0 1.5px rgba(11,42,64,.12), 0 50px 90px -36px rgba(11,42,64,.55)" }}>{shot("menubar-light", 300)}</div> },
  ssh: { word: "SSH agent.", sub: "Keys signed with Touch ID", dark: true, visual: () => (
    <div style={{ width: 720, padding: 40, borderRadius: 28, background: "#0F1A24", font: `400 30px/2 ${mono}`, color: "#E6EEF4", boxShadow: "0 0 0 1.5px rgba(230,238,244,.1)" }}>
      <div><span style={{ color: "#7F95A7" }}>~ </span>git commit -S -m "ship"</div>
      <div style={{ color: "#7F95A7" }}>approve github-signing</div>
      <div><span style={{ color: "#3FB96B" }}>✓ </span>[main 9307fb2] ship</div>
    </div>
  ) },
  zk: { word: "Zero-knowledge.", sub: "Keys never leave your Mac", visual: () => <Dial size={460} rot={[0, 0, 0]} /> },
  languages: { word: "Nine languages.", sub: "", visual: () => (
    <div style={{ display: "grid", gap: 14, font: `400 64px/1.1 ${serif}`, color: C.ink }}>
      {["English", "繁體中文", "粵語", "简体中文", "日本語", "한국어", "Français", "Español", "ไทย"].map((l) => <span key={l}>{l}</span>)}
    </div>
  ) },

  send: { word: "Send.", sub: "Encrypted links you can edit later", visual: () => (
    <div style={{ width: 700, padding: "44px 48px", borderRadius: 28, background: C.card, boxShadow: `0 0 0 1.5px ${C.line}, 0 50px 90px -46px rgba(11,42,64,.45)`, font: `400 54px/1.2 ${serif}`, color: C.ink }}>
      Share a secret.<br /><em style={{ color: C.ink3 }}>Change it later.</em><br />Same link.
    </div>
  ) },
  import: { word: "Bring everything.", sub: "Import in a minute", visual: () => (
    <div style={{ display: "grid", gap: 10, font: `400 52px/1.15 ${serif}`, color: C.ink }}>
      {["1Password", "LastPass", "KeePass", "Bitwarden", "Proton Pass", "Dashlane"].map((l, i) => <span key={l} style={{ opacity: 1 - i * 0.1 }}>{l}</span>)}
    </div>
  ) },
  emergency: { word: "Emergency access.", sub: "Trusted contacts, after a wait you choose", visual: () => (
    <div style={{ width: 640, padding: "44px 48px", borderRadius: 28, background: C.card, boxShadow: `0 0 0 1.5px ${C.line}, 0 50px 90px -46px rgba(11,42,64,.45)`, font: `400 30px/1.6 ${sans}`, color: C.ink2 }}>
      <div style={{ font: `400 76px/1 ${serif}`, color: C.ink }}>7 days</div>
      then they can view, or take over.
    </div>
  ) },
};
const MONTAGES: Record<number, Beat[]> = {
  3: ["codes", "watchtower", "menubar", "ssh", "zk", "languages"].map((k) => M[k]),
  4: ["codes", "watchtower", "menubar", "ssh", "send", "import", "emergency", "languages"].map((k) => M[k]),
};

const MontageCut: React.FC<{ bars: number }> = ({ bars }) => {
  const f = useCurrentFrame();
  const MONTAGE = MONTAGES[bars] ?? MONTAGES[3];
  const i = Math.min(MONTAGE.length - 1, Math.floor(f / (2 * BEAT)));
  const t = f - i * 2 * BEAT;
  const m = MONTAGE[i];
  const ink = m.dark ? "#E6EEF4" : C.ink;
  return (
    <Paper dark={m.dark}>
      <div style={{ position: "absolute", left: m.wide ? 110 : 160, top: m.wide ? 420 : 400, width: m.wide ? 700 : 860 }}>
        <div style={{ font: `500 22px ${mono}`, letterSpacing: ".18em", color: m.dark ? "#7F95A7" : C.ink3, marginBottom: 20 }}>0{i + 1} / 0{MONTAGE.length}</div>
        <div style={{ overflow: "hidden", padding: "0.04em 0 0.24em", marginBottom: "-0.18em" }}>
          <div style={{ font: `400 ${m.wide ? 96 : m.word.length > 13 ? 104 : 132}px/1 ${serif}`, letterSpacing: "-.03em", color: ink, transform: `translateX(${tween(t, 0, 8, 60, 0)}px)`, opacity: tween(t, 0, 4, 0, 1) }}>{m.word}</div>
        </div>
        <div style={{ font: `400 32px ${sans}`, color: m.dark ? "#A9BBC9" : C.ink2, marginTop: 18, opacity: tween(t, 5, 10, 0, 1) }}>{m.sub}</div>
      </div>
      <div style={{ position: "absolute", left: m.wide ? 790 : 1060, top: 540, transform: `translateY(-50%) translateX(${tween(t, 0, 9, 120, 0)}px) scale(${punch(t, 0, 0.05)})`, opacity: tween(t, 0, 5, 0, 1) }}>
        {m.visual()}
      </div>
    </Paper>
  );
};

/* ── Speed: a number lands on each of beats 1, 3 and 5 ── */
const SpeedCut: React.FC = () => {
  const f = useCurrentFrame();
  const stats = [
    // Figures that hold on any Mac: the 0.2.1 DMG, memory at rest (footnoted), browser engines shipped.
    { v: 14.5, d: 1, u: "MB", l: "download" },
    { v: 138, d: 0, u: "MB", l: "memory at rest" },
    { v: 0, d: 0, u: "", l: "bundled browser engines" },
  ];
  return (
    <Paper dark>
      <div style={{ position: "absolute", left: 160, top: 110 }}>
        <Label at={0} color="#7F95A7">Lightweight</Label>
        <div style={{ height: 18 }} />
        <Words size={92} color="#E6EEF4" words={[["Not", 0], ["a", 3], ["browser", 6], ["in", BEAT], ["a", BEAT + 3], ["box.", BEAT + 6]]} />
      </div>
      <div style={{ position: "absolute", left: 160, right: 160, top: 470, display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 40 }}>
        {stats.map((s, i) => {
          const at = (2 + i * 2) * BEAT;
          const p = tween(f, at, at + 10, 0, 1);
          return (
            <div key={s.u} style={{ borderTop: "1.5px solid rgba(230,238,244,.16)", paddingTop: 28, opacity: tween(f, at, at + 3, 0, 1), transform: `scale(${punch(f, at, 0.08)})`, transformOrigin: "0 0" }}>
              <div style={{ font: `400 168px/1 ${serif}`, letterSpacing: "-.03em", color: "#F3F6F9" }}>
                {(s.v * p).toFixed(s.d)}<span style={{ font: `500 42px ${mono}`, color: "#7F95A7", marginLeft: 14, letterSpacing: 0 }}>{s.u}</span>
              </div>
              <div style={{ font: `400 30px ${sans}`, color: "#A9BBC9", marginTop: 16 }}>{s.l}</div>
            </div>
          );
        })}
      </div>
      <div style={{ position: "absolute", left: 160, bottom: 64, font: `500 18px ${mono}`, letterSpacing: ".14em", color: "#55697A" }}>MEMORY MEASURED ON AN M4 PRO WITH 200+ ITEMS · IT VARIES BY MAC</div>
    </Paper>
  );
};

/* ── Light and dark: the sweep crosses on the bar ── */
const LightDarkCut: React.FC = () => {
  const f = useCurrentFrame();
  const sweep = tween(f, 4, BAR - 10, 0, 1, inOut);
  const w = 1300, h = w * (2084 / 2704);
  return (
    <AbsoluteFill style={{ background: `linear-gradient(90deg, ${C.paper} ${(1 - sweep) * 100}%, ${C.night} ${(1 - sweep) * 100}%)` }}>
      <div style={{ position: "absolute", left: 960 - w / 2, top: 210, width: w, height: h }}>
        {shot("vault-light", w, { position: "absolute", inset: 0 })}
        <div style={{ position: "absolute", inset: 0, clipPath: `inset(0 0 0 ${(1 - sweep) * 100}%)` }}>{shot("vault-dark", w, { position: "absolute", inset: 0 })}</div>
      </div>
      {(["light", "dark"] as const).map((mode) => (
        <div key={mode} style={{ position: "absolute", left: 0, right: 0, top: 70, textAlign: "center", font: `400 88px ${serif}`, letterSpacing: "-.02em",
          clipPath: mode === "light" ? `inset(0 ${sweep * 100}% 0 0)` : `inset(0 0 0 ${(1 - sweep) * 100}%)` }}>
          <span style={{ color: mode === "light" ? C.ink : "#E6EEF4" }}>Light and dark, </span>
          <em style={{ color: mode === "light" ? C.ink3 : "#7F95A7" }}>of course.</em>
        </div>
      ))}
    </AbsoluteFill>
  );
};

/* ── Offer: the licence as it is now, a line a step ── */
const OfferCut: React.FC<{ bars: number }> = ({ bars }) => {
  const f = useCurrentFrame();
  const long = bars >= 3;
  const step = long ? 2 * BEAT : BEAT; // the long version gives each line two beats
  const size = long ? 116 : 124;
  return (
    <Paper>
      <AbsoluteFill style={{ display: "grid", placeItems: "center" }}>
        <div style={{ display: "grid", gap: 6 }}>
          <Words size={size} align="center" words={[["Free", 0], ["for", 3], ["personal", 6], ["use.", 10]]} />
          <Words size={size} align="center" italic color={C.ink3} words={[["Every", step], ["feature.", step + 5]]} />
          <Words size={size} align="center" words={[["$19.99", 2 * step], ["once,", 2 * step + 5], ["for", 2 * step + 8], ["work.", 2 * step + 11]]} />
          {long && <Words size={size} align="center" italic color={C.ink3} words={[["One", 3 * step], ["person,", 3 * step + 4], ["every", 3 * step + 8], ["Mac.", 3 * step + 12]]} />}
        </div>
      </AbsoluteFill>
      {long && (
        <div style={{ position: "absolute", left: 0, right: 0, bottom: 70, textAlign: "center", font: `500 24px ${mono}`, letterSpacing: ".16em", color: C.ink3, opacity: tween(f, 2 * BAR, 2 * BAR + 8, 0, 1) }}>
          NO SUBSCRIPTION · NOTHING LOCKED · GPL-3.0 SOURCE
        </div>
      )}
    </Paper>
  );
};

/* ── End card: the icon's rings land on beats 1–3; then the name and where to get it ── */
const EndCut: React.FC = () => {
  const f = useCurrentFrame();
  const rot = RINGS.map((g, i) => g.apart * (1 - tween(f, (3 - i) * BEAT - 5, (3 - i) * BEAT, 0, 1, inOut))) as Tri;
  return (
    <Paper>
      <AbsoluteFill style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center" }}>
        <div style={{ width: 240, height: 240, borderRadius: 56, overflow: "hidden", position: "relative", transform: `scale(${punch(f, 0, 0.2)})`, background: "linear-gradient(#8FCDF3, #4BA7E0)", boxShadow: "0 40px 80px -30px rgba(11,42,64,.5)" }}>
          <div style={{ position: "absolute", inset: 0, background: "radial-gradient(circle at 50% 15%, rgba(255,255,255,.28), rgba(255,255,255,0) 75%)" }} />
          <Dial size={240} rot={rot} style={{ position: "absolute", inset: 0 }} />
        </div>
        <div style={{ height: 40 }} />
        <Words size={180} align="center" words={[["Triwarden", 3 * BEAT]]} />
        <div style={{ height: 30 }} />
        <div style={{ opacity: tween(f, 5 * BEAT, 5 * BEAT + 6, 0, 1), transform: `scale(${punch(f, 5 * BEAT, 0.1)})`, font: `600 30px ${sans}`, padding: "20px 36px", borderRadius: 999, background: C.sky, color: C.ink }}>
          triwarden.cc
        </div>
        <div style={{ height: 22 }} />
        <div style={{ opacity: tween(f, 6 * BEAT, 6 * BEAT + 6, 0, 1), font: `500 24px ${mono}`, color: C.ink3 }}>
          brew install --cask sinhong2011/tap/triwarden
        </div>
      </AbsoluteFill>
    </Paper>
  );
};

/* ── Shared vaults: the real sidebar, your vault and your team's ── */
const SharedCut: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <Paper>
      <div style={{ position: "absolute", left: 120, top: 330, width: 760 }}>
        <Label at={0}>Shared vaults</Label>
        <div style={{ height: 18 }} />
        <Words size={104} words={[["Your", 0], ["vault.", 5]]} />
        <Words size={104} italic color={C.ink3} words={[["Your", BEAT * 2], ["team’s.", BEAT * 2 + 5]]} />
        <div style={{ font: `400 30px/1.4 ${sans}`, color: C.ink2, marginTop: 30, opacity: tween(f, 4 * BEAT, 4 * BEAT + 8, 0, 1) }}>
          Nested shared folders, one switcher, one Touch ID.
        </div>
      </div>
      <div style={{ position: "absolute", left: 860, top: 120, transform: `scale(${punch(f, 0, 0.06) * tween(f, 0, 2 * BAR, 1, 1.04)})`, transformOrigin: "0 30%" }}>
        {shot("vault-light", 1000)}
      </div>
    </Paper>
  );
};

/* ── Security: one lock a bar. The dial's ring for that lock lines up on the bar's downbeat. ── */
const LOCKS = [
  { label: "Lock one · your password", title: "Zero-knowledge.", sub: "Keys are made on your Mac. The server only sees ciphertext." },
  { label: "Lock two · your touch", title: "Hardware-backed.", sub: "Touch ID, guarded by the Secure Enclave." },
  { label: "Lock three · your server", title: "End-to-end.", sub: "Vaultwarden or Bitwarden, encrypted before it syncs." },
];
const SecurityCut: React.FC = () => {
  const f = useCurrentFrame();
  const n = Math.min(2, Math.floor(f / BAR));
  const t = f - n * BAR;
  // Outer ring first; each lands on its bar's downbeat and stays lined up.
  const rot = RINGS.map((g, i) => g.apart * (1 - tween(f, i * BAR - 6, i * BAR, 0, 1, inOut))) as Tri;
  const op = RINGS.map((_, i) => (i === n ? 1 : i < n ? 0.55 : 0.2)) as Tri;
  const lock = LOCKS[n];
  return (
    <Paper>
      <div style={{ position: "absolute", left: 140, top: 140 }}>
        <Dial size={800} rot={rot} opacity={op} hub={1 + 0.06 * Math.max(0, 1 - Math.abs(t - 2) / 5)} />
      </div>
      <div style={{ position: "absolute", left: 1060, top: 330, width: 740 }}>
        <div style={{ font: `500 22px ${mono}`, letterSpacing: ".18em", textTransform: "uppercase", color: C.ink3, opacity: tween(t, 0, 5, 0, 1) }}>{lock.label}</div>
        <div style={{ height: 22 }} />
        <div style={{ overflow: "hidden", padding: "0.04em 0 0.24em", marginBottom: "-0.18em" }}>
          <div style={{ font: `400 112px/1 ${serif}`, letterSpacing: "-.03em", color: C.ink, transform: `translateY(${tween(t, 0, 8, 110, 0)}%)` }}>{lock.title}</div>
        </div>
        <div style={{ font: `400 32px/1.4 ${sans}`, color: C.ink2, marginTop: 22, opacity: tween(t, 5, 12, 0, 1) }}>{lock.sub}</div>
      </div>
    </Paper>
  );
};

/* ── Generator: the real generator, whole window, with a slow push ── */
const GeneratorCut: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <Paper>
      <div style={{ position: "absolute", left: 120, top: 330, width: 700 }}>
        <Label at={0}>Generator</Label>
        <div style={{ height: 18 }} />
        <Words size={104} words={[["Strong", 0], ["by", 5], ["default.", 10]]} />
        <Words size={104} italic color={C.ink3} words={[["Easy", 2 * BEAT], ["to", 2 * BEAT + 4], ["say.", 2 * BEAT + 8]]} />
        <div style={{ font: `400 30px/1.4 ${sans}`, color: C.ink2, marginTop: 30, opacity: tween(f, 4 * BEAT, 4 * BEAT + 8, 0, 1) }}>
          Passwords, passphrases and usernames, with history.
        </div>
      </div>
      <div style={{ position: "absolute", left: 800, top: 150, transform: `scale(${punch(f, 0, 0.06) * tween(f, 0, 2 * BAR, 1, 1.03)})`, transformOrigin: "50% 30%" }}>
        {shot("generator-light", 1060)}
      </div>
    </Paper>
  );
};

const SCENES: Record<string, React.FC<{ bars: number }>> = {
  hook: Hook, dial: DialCut, vault: VaultCut, shared: SharedCut, search: SearchCut, palette: PaletteCut,
  autotype: AutoTypeCut, security: SecurityCut, generator: GeneratorCut, montage: MontageCut, speed: SpeedCut,
  lightdark: LightDarkCut, offer: OfferCut, end: EndCut,
};

/** Plays one of the cuts in cuts.json: each scene starts on its bar and runs its bars, hard cuts between them. */
export const Cut: React.FC<{ name: CutName }> = ({ name }) => (
  <AbsoluteFill style={{ fontFamily: sans, background: C.paper }}>
    {(cuts[name].scenes as [string, number, number][]).map(([id, from, bars]) => {
      const S = SCENES[id];
      return <Sequence key={id} from={from * BAR} durationInFrames={bars * BAR}><S bars={bars} /></Sequence>;
    })}
  </AbsoluteFill>
);
