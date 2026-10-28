import React from "react";
import { Composition, Folder } from "remotion";
import { FramesClip, IntroClip, ListenClip, OpenClip } from "./Clips";
import { ClipProps } from "./theme";

const clips: { id: string; component: React.FC<ClipProps>; frames: number }[] = [
  { id: "intro", component: IntroClip, frames: 110 },
  { id: "open", component: OpenClip, frames: 150 },
  { id: "listen", component: ListenClip, frames: 150 },
  { id: "frames", component: FramesClip, frames: 120 },
];

export const RemotionRoot: React.FC = () => (
  <>
    {(["light", "dark"] as const).map((mode) => (
      <Folder key={mode} name={mode}>
        {clips.map((c) => (
          <Composition key={c.id} id={`${c.id}-${mode}`} component={c.component} durationInFrames={c.frames}
            fps={30} width={960} height={560} defaultProps={{ mode }} />
        ))}
      </Folder>
    ))}
  </>
);
