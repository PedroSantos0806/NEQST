import type { CSSProperties } from "react";
import type { Racket as RacketColors } from "../lib/types";

/** A raquete do protótipo, com as cores que o jogador escolhe no perfil. */
export function Racket({
  frame,
  grip,
  face = "#2F4629",
  style,
  className,
  width = 64,
  height = 22,
  strung = false,
}: RacketColors & {
  face?: string;
  style?: CSSProperties;
  className?: string;
  width?: number;
  height?: number;
  /** Traços finos no grip: só a prévia grande do perfil os mostra. */
  strung?: boolean;
}) {
  const thin = strung ? 0.6 : 1;

  return (
    <svg
      width={width}
      height={height}
      viewBox="0 0 64 22"
      aria-hidden="true"
      style={style}
      className={className}
    >
      <ellipse cx="16" cy="11" rx="13.5" ry="9" fill={face} stroke={frame} strokeWidth={strung ? 2.4 : 3} />
      <path
        d="M16 3v16M10 4.5v13M22 4.5v13M5 11h22M6.5 7h19M6.5 15h19"
        stroke={grip}
        strokeWidth={thin}
        opacity={strung ? 0.85 : 0.8}
      />
      <path
        d="M29 9l8 1.2v1.6L29 13"
        fill="none"
        stroke={frame}
        strokeWidth={strung ? 2 : 2.4}
        strokeLinejoin="round"
      />
      <rect x="37" y="8.4" width="23" height="5.2" rx="2" fill={grip} />
      {strung && (
        <path
          d="M40 8.4l3 5.2M45 8.4l3 5.2M50 8.4l3 5.2M55 8.4l3 5.2"
          stroke={face}
          strokeWidth=".5"
          opacity=".35"
        />
      )}
      <rect x="59" y="8" width="3.5" height="6" rx="1" fill={frame} />
    </svg>
  );
}

/** Rotação e deslocamento de cada raquete na pilha, como no protótipo. */
export function stackStyle(index: number): CSSProperties {
  const rotation = [-3, 2, -1, 3, -2][index % 5];
  return {
    position: "absolute",
    left: 10 + (index % 2) * 7,
    top: 38 - index * 7,
    width: 64,
    height: 22,
    display: "block",
    transform: `rotate(${rotation}deg)`,
    ["--r" as string]: `${rotation}deg`,
  };
}

/**
 * A pilha de raquetes — a metáfora física da fila: cada time deixa a
 * sua, e a sua fica por cima das que chegaram antes. A moldura é a do
 * protótipo: 88×66, fundo de quadra e a linha da rede embaixo.
 */
export function RacketStack({
  rackets,
  more,
  highlightLast = false,
  face = "#2F4629",
  label,
}: {
  rackets: RacketColors[];
  more: number;
  highlightLast?: boolean;
  face?: string;
  label?: string;
}) {
  return (
    <div
      role="img"
      aria-label={
        label ??
        (more > 0
          ? `Pilha com as ${rackets.length} raquetes à sua frente, mais ${more} antes delas`
          : `Pilha com ${rackets.length} raquetes, a sua no topo`)
      }
      style={{
        position: "relative",
        flexShrink: 0,
        width: 88,
        height: 66,
        background: face,
        borderRadius: 8,
        overflow: "hidden",
        border: "1px solid rgba(241,236,239,.2)",
      }}
    >
      <span style={{ position: "absolute", left: 6, right: 6, bottom: 5, height: 2, background: "rgba(241,236,239,.35)" }} />
      {rackets.map((racket, index) => (
        <span
          key={index}
          className={highlightLast && index === rackets.length - 1 ? "drop" : undefined}
          style={stackStyle(index)}
        >
          <Racket frame={racket.frame} grip={racket.grip} face={face} />
        </span>
      ))}
      {more > 0 && (
        <span
          style={{
            position: "absolute",
            top: 4,
            right: 4,
            padding: "1px 5px",
            background: "var(--chalk)",
            color: "var(--ink)",
            borderRadius: 4,
            fontSize: 10,
            fontWeight: 800,
          }}
        >
          +{more}
        </span>
      )}
    </div>
  );
}
