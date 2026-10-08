import type { CSSProperties } from "react";
import type { Racket as RacketColors } from "../lib/types";

/** A raquete do protótipo, com as cores que o jogador escolhe no perfil. */
export function Racket({
  frame,
  grip,
  face = "#2F4629",
  style,
  className,
}: RacketColors & { face?: string; style?: CSSProperties; className?: string }) {
  return (
    <svg
      width="64"
      height="22"
      viewBox="0 0 64 22"
      aria-hidden="true"
      style={style}
      className={className}
    >
      <ellipse cx="16" cy="11" rx="13.5" ry="9" fill={face} stroke={frame} strokeWidth="3" />
      <path
        d="M16 3v16M10 4.5v13M22 4.5v13M5 11h22M6.5 7h19M6.5 15h19"
        stroke={grip}
        strokeWidth="1"
        opacity=".8"
      />
      <path
        d="M29 9l8 1.2v1.6L29 13"
        fill="none"
        stroke={frame}
        strokeWidth="2.4"
        strokeLinejoin="round"
      />
      <rect x="37" y="8.4" width="23" height="5.2" rx="2" fill={grip} />
      <rect x="59" y="8" width="3.5" height="6" rx="1" fill={frame} />
    </svg>
  );
}

/** Rotação e deslocamento de cada raquete na pilha, como no protótipo. */
function stackStyle(index: number): CSSProperties {
  const rotations = [-3, 2, -1, 3, -2];
  return {
    position: "absolute",
    left: 10 + (index % 2) * 7,
    top: 38 - index * 7,
    width: 64,
    height: 22,
    display: "block",
    transform: `rotate(${rotations[index % 5]}deg)`,
    ["--r" as string]: `${rotations[index % 5]}deg`,
  };
}

/**
 * A pilha de raquetes — a metáfora física da fila: cada time deixa a
 * sua, e a sua fica por cima das que chegaram antes.
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
    <span
      role="img"
      aria-label={label ?? `Pilha com ${rackets.length} raquete(s)`}
      style={{ position: "relative", display: "block", width: 82, height: 62, flexShrink: 0 }}
    >
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
          aria-hidden="true"
          style={{
            position: "absolute",
            right: 0,
            bottom: 0,
            fontSize: 11,
            fontWeight: 700,
            color: "var(--muted)",
          }}
        >
          +{more}
        </span>
      )}
    </span>
  );
}
