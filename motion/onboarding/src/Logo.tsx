import { Easing, interpolate, useCurrentFrame } from "remotion";
import { nacre } from "./theme";

// Same geometry as Sources/Meteora/Logo.swift (1024 canvas).
const A = [392, 802], B = [392, 390], C = [580, 620], D = [768, 390], E = [768, 802];
const STROKE = 88, TAIL = 380;
const dx = B[0] - C[0], dy = B[1] - C[1], n = Math.hypot(dx, dy);
const U = [dx / n, dy / n];
const TIP = [B[0] + U[0] * TAIL, B[1] + U[1] * TAIL];

const tailPath = () => {
  const r = STROKE / 2, nx = -U[1] * r, ny = U[0] * r;
  const c1 = [B[0] + nx * 0.5 + U[0] * TAIL * 0.55, B[1] + ny * 0.5 + U[1] * TAIL * 0.55];
  const c2 = [B[0] - nx * 0.5 + U[0] * TAIL * 0.55, B[1] - ny * 0.5 + U[1] * TAIL * 0.55];
  return `M${B[0] + nx},${B[1] + ny} Q${c1[0]},${c1[1]} ${TIP[0]},${TIP[1]} Q${c2[0]},${c2[1]} ${B[0] - nx},${B[1] - ny} A${r},${r} 0 0 1 ${B[0] + nx},${B[1] + ny} Z`;
};

// Written outwards from the peak where the meteor lands.
const LEG = `M${B[0]},${B[1]} L${A[0]},${A[1]}`;
const REST = `M${B[0]},${B[1]} L${C[0]},${C[1]} L${D[0]},${D[1]} L${E[0]},${E[1]}`;
const LEG_LEN = 412;
const REST_LEN = Math.hypot(188, 230) * 2 + 412;

/** progress 0..1 writes the M; `meteor` 0..1 flies the head in along the tail. */
export const AnimatedMark: React.FC<{ size: number; color: string; start?: number }> = ({ size, color, start = 0 }) => {
  const f = useCurrentFrame() - start;
  const meteor = interpolate(f, [0, 22], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.bezier(0.5, 0, 0.75, 0) });
  const write = interpolate(f, [20, 58], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.bezier(0.16, 1, 0.3, 1) });
  const tailOpacity = interpolate(f, [0, 8], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  // The head travels from the far end of the trail to the peak.
  const headX = TIP[0] + (B[0] - TIP[0]) * meteor, headY = TIP[1] + (B[1] - TIP[1]) * meteor;
  const id = `g${start}`;
  return (
    <svg width={size} height={size} viewBox="0 0 1024 1024">
      <defs>
        <linearGradient id={id} gradientUnits="userSpaceOnUse" x1={B[0]} y1={B[1]} x2={TIP[0]} y2={TIP[1]}>
          <stop offset="0" stopColor={color} />
          <stop offset="0.30" stopColor={nacre[0]} stopOpacity={0.95} />
          <stop offset="0.55" stopColor={nacre[1]} stopOpacity={0.75} />
          <stop offset="0.78" stopColor={nacre[2]} stopOpacity={0.45} />
          <stop offset="1" stopColor={nacre[3]} stopOpacity={0} />
        </linearGradient>
        <clipPath id={`${id}c`}>
          {/* reveal the trail behind the moving head */}
          <circle cx={headX} cy={headY} r={TAIL * 1.15 * Math.max(0.0001, meteor)} />
        </clipPath>
      </defs>
      <g opacity={tailOpacity}>
        <path d={tailPath()} fill={`url(#${id})`} clipPath={meteor < 1 ? `url(#${id}c)` : undefined} />
        {meteor < 1 ? <circle cx={headX} cy={headY} r={STROKE / 2} fill={color} /> : null}
      </g>
      {[[LEG, LEG_LEN], [REST, REST_LEN]].map(([d, len]) => (
        <path key={d as string} d={d as string} fill="none" stroke={color} strokeWidth={STROKE} strokeLinecap="round" strokeLinejoin="round"
          strokeDasharray={len as number} strokeDashoffset={(len as number) * (1 - write)} opacity={write > 0 ? 1 : 0} />
      ))}
    </svg>
  );
};
