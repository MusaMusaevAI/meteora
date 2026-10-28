import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

export type Mode = "light" | "dark";
export type ClipProps = { mode: Mode };

// Mirrors Sources/Meteora/Theme.swift.
export const palette = (mode: Mode) =>
  mode === "light"
    ? {
        bg: "#FBFBFA", ground: "#F3F2EF", sunken: "#E6E6E3", hairline: "#DAD9D5",
        text: "#16181B", secondary: "#5B6068", tertiary: "#8A9098",
        accent: "#33506B", accentSoft: "#E1E8EF",
        stage: "#1B1E22", stageRaised: "#24282D",
      }
    : {
        bg: "#1D2024", ground: "#141619", sunken: "#101215", hairline: "#2A2E34",
        text: "#ECEDEF", secondary: "#9BA2AB", tertiary: "#6A717A",
        accent: "#9DB8D3", accentSoft: "#1E2A36",
        stage: "#0C0E11", stageRaised: "#16191D",
      };

export const stageText = "#E9EBEE";
export const stageSecondary = "#8F97A1";
export const stageAccent = "#9DB8D3";
export const nacre = ["#BCD4EC", "#D6CDEE", "#EBC6D6", "#F1E2CC", "#C9E3E4"];
export const FONT = "Inter";

let loaded = false;
export const ensureFonts = () => {
  if (loaded) return;
  loaded = true;
  for (const w of ["400", "500", "600"]) {
    for (const s of ["latin", "cyrillic"]) {
      loadFont({ family: FONT, url: staticFile(`fonts/inter-${s}-${w}-normal.woff2`), weight: w });
    }
  }
};

export const EASE_OUT: [number, number, number, number] = [0.16, 1, 0.3, 1];
