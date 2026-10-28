import React from "react";
import { AbsoluteFill, Easing, interpolate, useCurrentFrame } from "remotion";
import { AnimatedMark } from "./Logo";
import { ClipProps, EASE_OUT, FONT, ensureFonts, nacre, palette, stageAccent, stageSecondary, stageText } from "./theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const ease = Easing.bezier(...EASE_OUT);

/** Deterministic pseudo-random envelope for waveforms. */
const env = (i: number) => {
  const v = Math.abs(Math.sin(i * 12.9898) * 43758.5453) % 1;
  const speech = Math.sin(i / 9) > -0.55 ? 1 : 0.15;
  return Math.max(0.08, (0.25 + v * 0.75) * speech);
};

const Frame: React.FC<{ mode: ClipProps["mode"]; children: React.ReactNode }> = ({ mode, children }) => {
  ensureFonts();
  const p = palette(mode);
  return <AbsoluteFill style={{ backgroundColor: p.bg, fontFamily: FONT, color: p.text }}>{children}</AbsoluteFill>;
};

const Stage: React.FC<{ width: number; height: number; children: React.ReactNode; style?: React.CSSProperties; mode: ClipProps["mode"] }> = ({ width, height, children, style, mode }) => (
  <div style={{ width, height, borderRadius: 22, background: palette(mode).stage, overflow: "hidden", position: "relative",
    boxShadow: "0 8px 30px rgba(0,0,0,0.16)", border: "1px solid rgba(255,255,255,0.06)", ...style }}>{children}</div>
);

const Waveform: React.FC<{ bars: number; width: number; height: number; grown: number; played: number }> = ({ bars, width, height, grown, played }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 3, width, height }}>
    {Array.from({ length: bars }).map((_, i) => {
      const t = i / bars;
      const h = t <= grown ? env(i) * height : 3;
      return <div key={i} style={{ width: (width - 3 * bars) / bars, height: Math.max(3, h), borderRadius: 2,
        background: t <= played ? stageAccent : "rgba(255,255,255,0.24)" }} />;
    })}
  </div>
);

// 1. Welcome: a meteor lands and writes the M.
export const IntroClip: React.FC<ClipProps> = ({ mode }) => {
  const f = useCurrentFrame();
  const p = palette(mode);
  return (
    <Frame mode={mode}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column" }}>
        <AnimatedMark size={300} color={p.accent} start={6} />
        <div style={{ fontSize: 56, fontWeight: 600, letterSpacing: -1.4, marginTop: -6,
          opacity: interpolate(f, [52, 76], [0, 1], { ...clamp, easing: ease }),
          translate: interpolate(f, [52, 76], ["0px 14px", "0px 0px"], { ...clamp, easing: ease }) }}>Meteora</div>
      </AbsoluteFill>
    </Frame>
  );
};

// 2. Open: a recording drops in and becomes the stage with its waveform.
export const OpenClip: React.FC<ClipProps> = ({ mode }) => {
  const f = useCurrentFrame();
  const p = palette(mode);
  const drop = interpolate(f, [4, 34], [0, 1], { ...clamp, easing: ease });
  const absorb = interpolate(f, [36, 50], [1, 0], { ...clamp, easing: ease });
  const stageIn = interpolate(f, [40, 62], [0, 1], { ...clamp, easing: ease });
  const grown = interpolate(f, [56, 104], [0, 1], { ...clamp, easing: Easing.bezier(0.33, 0, 0.2, 1) });
  const played = interpolate(f, [104, 140], [0, 0.32], clamp);
  return (
    <Frame mode={mode}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Stage mode={mode} width={760} height={400} style={{ opacity: stageIn, scale: interpolate(stageIn, [0, 1], [0.96, 1]) }}>
          <div style={{ position: "absolute", inset: 0, bottom: 74, background: "#000", display: "flex", alignItems: "center", justifyContent: "center" }}>
            <div style={{ width: 430, height: 236, borderRadius: 8, background: "#F2F2F0", position: "relative",
              opacity: interpolate(f, [62, 84], [0, 1], { ...clamp, easing: ease }) }}>
              <div style={{ position: "absolute", left: 30, top: 30, width: 210, height: 16, borderRadius: 4, background: "#1B1E22" }} />
              {[0, 1, 2, 3].map((r) => (
                <div key={r} style={{ position: "absolute", left: 30, top: 74 + r * 30, width: 250 - r * 40, height: 9, borderRadius: 4, background: "#A9AFB7" }} />
              ))}
              {[0, 1, 2].map((k) => (
                <div key={k} style={{ position: "absolute", left: 300 + k * 34, bottom: 30, width: 22, height: 50 + k * 34, borderRadius: 4,
                  background: `linear-gradient(180deg, ${nacre[k]}, ${nacre[k + 1]})` }} />
              ))}
            </div>
          </div>
          <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 74, background: palette(mode).stageRaised,
            display: "flex", alignItems: "center", gap: 18, padding: "0 26px", borderTop: "1px solid rgba(255,255,255,0.06)" }}>
            <div style={{ width: 0, height: 0, borderTop: "11px solid transparent", borderBottom: "11px solid transparent", borderLeft: `17px solid ${stageText}` }} />
            <div style={{ color: stageText, fontSize: 19, fontVariantNumeric: "tabular-nums" }}>0:00</div>
            <Waveform bars={84} width={500} height={44} grown={grown} played={played} />
            <div style={{ color: stageSecondary, fontSize: 19, fontVariantNumeric: "tabular-nums" }}>47:12</div>
          </div>
        </Stage>
        {/* the file */}
        <div style={{ position: "absolute", top: interpolate(drop, [0, 1], [-140, 210]), left: 300,
          opacity: absorb, scale: interpolate(absorb, [0, 1], [0.86, 1]),
          width: 360, height: 120, borderRadius: 18, background: p.bg, border: `1px solid ${p.hairline}`,
          boxShadow: "0 18px 40px rgba(0,0,0,0.18)", display: "flex", alignItems: "center", gap: 18, padding: "0 22px" }}>
          <div style={{ width: 52, height: 64, borderRadius: 8, background: p.accentSoft, border: `1px solid ${p.hairline}`,
            display: "flex", alignItems: "flex-end", justifyContent: "center", paddingBottom: 8, fontSize: 13, fontWeight: 600, color: p.accent }}>webm</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <div style={{ fontSize: 18, fontWeight: 500 }}>Встреча в Телемосте</div>
            <div style={{ fontSize: 15, color: p.secondary, fontVariantNumeric: "tabular-nums" }}>26.10.26 13-59-23</div>
          </div>
        </div>
      </AbsoluteFill>
    </Frame>
  );
};

const LINES = [
  ["0:04", "Коллеги, добрый день. Начнём с итогов недели."],
  ["0:11", "Макет лендинга согласовали, правки внесём до среды."],
  ["0:19", "По рассылке: пилот на десять тысяч адресов."],
  ["0:27", "Следующая встреча — в пятницу в одиннадцать."],
];

// 3. Listen: speech becomes text, line by line, while the pearl sheen runs.
export const ListenClip: React.FC<ClipProps> = ({ mode }) => {
  const f = useCurrentFrame();
  const p = palette(mode);
  const progress = interpolate(f, [8, 132], [0.04, 1], clamp);
  const sheenX = ((f % 84) / 84) * 1.6 - 0.3;
  const done = interpolate(f, [132, 146], [1, 0], clamp);
  return (
    <Frame mode={mode}>
      <AbsoluteFill style={{ padding: "0 110px", gap: 26, justifyContent: "center" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          <div style={{ fontSize: 22, fontWeight: 600 }}>Расшифровка</div>
          <div style={{ flex: 1, height: 7, borderRadius: 4, background: p.sunken, position: "relative", overflow: "hidden" }}>
            <div style={{ position: "absolute", inset: 0, width: `${progress * 100}%`, borderRadius: 4, background: p.accent, overflow: "hidden" }}>
              <div style={{ position: "absolute", top: 0, bottom: 0, width: "45%", left: `${sheenX * 100}%`, opacity: done,
                mixBlendMode: "screen", background: `linear-gradient(90deg, transparent, ${nacre[0]}, ${nacre[1]}, ${nacre[2]}, ${nacre[3]}, transparent)` }} />
            </div>
          </div>
          <div style={{ fontSize: 18, color: p.secondary, width: 64, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{Math.round(progress * 100)} %</div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          {LINES.map(([t, s], i) => {
            const at = 22 + i * 26;
            const o = interpolate(f, [at, at + 16], [0, 1], { ...clamp, easing: ease });
            const latest = Math.min(LINES.length - 1, Math.floor((f - 22) / 26));
            const current = i === latest;
            return (
              <div key={t} style={{ display: "flex", gap: 22, alignItems: "baseline", padding: "10px 14px", borderRadius: 10,
                background: current ? p.accentSoft : "transparent", opacity: o,
                translate: interpolate(o, [0, 1], ["0px 10px", "0px 0px"]) }}>
                <div style={{ fontSize: 18, color: current ? p.accent : p.tertiary, width: 46, fontVariantNumeric: "tabular-nums" }}>{t}</div>
                <div style={{ fontSize: 23 }}>{s}</div>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Frame>
  );
};

// 4. Frames: slides land in a strip; the chosen one gives up its text.
export const FramesClip: React.FC<ClipProps> = ({ mode }) => {
  const f = useCurrentFrame();
  const p = palette(mode);
  const lift = interpolate(f, [70, 100], [0, 1], { ...clamp, easing: ease });
  return (
    <Frame mode={mode}>
      <AbsoluteFill style={{ padding: "70px 90px", gap: 30 }}>
        <div style={{ display: "flex", gap: 22 }}>
          {[0, 1, 2, 3].map((k) => {
            const at = 6 + k * 12;
            const o = interpolate(f, [at, at + 18], [0, 1], { ...clamp, easing: ease });
            const selected = k === 1 && f > 60;
            return (
              <div key={k} style={{ display: "flex", flexDirection: "column", gap: 10, opacity: o,
                translate: interpolate(o, [0, 1], ["24px 0px", "0px 0px"]) }}>
                <div style={{ width: 172, height: 108, borderRadius: 12, background: palette(mode).stage, position: "relative", overflow: "hidden",
                  outline: selected ? `3px solid ${p.accent}` : `1px solid ${p.hairline}`, outlineOffset: selected ? 0 : -1 }}>
                  <div style={{ position: "absolute", left: 16, top: 16, width: 90, height: 9, borderRadius: 4, background: "rgba(255,255,255,0.75)" }} />
                  {[0, 1, 2].map((r) => (
                    <div key={r} style={{ position: "absolute", left: 16, top: 38 + r * 18, width: 120 - r * 26, height: 6, borderRadius: 3, background: "rgba(255,255,255,0.32)" }} />
                  ))}
                  <div style={{ position: "absolute", right: 14, bottom: 14, width: 34, height: 40, borderRadius: 4,
                    background: `linear-gradient(180deg, ${nacre[k % 4]}, ${nacre[(k + 1) % 4]})`, opacity: 0.7 }} />
                </div>
                <div style={{ fontSize: 17, fontWeight: 500, color: selected ? p.accent : p.text, fontVariantNumeric: "tabular-nums" }}>{["0:00", "4:12", "11:37", "26:05"][k]}</div>
              </div>
            );
          })}
        </div>
        <div style={{ borderRadius: 14, background: p.sunken, padding: "20px 24px", display: "flex", flexDirection: "column", gap: 9,
          opacity: lift, translate: interpolate(lift, [0, 1], ["0px 18px", "0px 0px"]) }}>
          <div style={{ fontSize: 20, fontWeight: 600 }}>Итоги квартала</div>
          <div style={{ fontSize: 18, color: p.secondary }}>Охват кампании · Конверсия в заявку · План на ноябрь</div>
        </div>
      </AbsoluteFill>
    </Frame>
  );
};
