/**
 * Os ícones do protótipo, traçados linha a linha a partir do arquivo do
 * designer. Ficam juntos aqui para que uma correção de desenho valha
 * para todas as telas de uma vez.
 */
import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Svg({ size = 20, children, ...rest }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      aria-hidden="true"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const ChevronRight = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" {...p}>
    <path d="M9 6l6 6-6 6" />
  </Svg>
);

export const ChevronLeft = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" {...p}>
    <path d="M15 6l-6 6 6 6" />
  </Svg>
);

export const Pin = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" {...p}>
    <path d="M12 21s-7-6.5-7-12a7 7 0 0 1 14 0c0 5.5-7 12-7 12z" />
    <circle cx="12" cy="9" r="2.5" />
  </Svg>
);

export const Camera = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinejoin="round" {...p}>
    <path d="M4 8h3l2-3h6l2 3h3v11H4z" />
    <circle cx="12" cy="13" r="3.5" />
  </Svg>
);

export const Clock = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <circle cx="12" cy="12" r="9" />
    <path d="M12 7v5l3 2" />
  </Svg>
);

export const RacketIcon = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <ellipse cx="9" cy="9" rx="5.5" ry="6.5" transform="rotate(-45 9 9)" />
    <path d="M13 13l7 7" />
  </Svg>
);

export const Check = (p: IconProps) => (
  <Svg strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" {...p}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Svg>
);

export const Warn = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" {...p}>
    <path d="M12 3l10 18H2z" />
    <path d="M12 10v5M12 18h.01" />
  </Svg>
);

export const Close = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" {...p}>
    <path d="M6 6l12 12M18 6L6 18" />
  </Svg>
);

export const Lock = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <rect x="5" y="11" width="14" height="10" rx="2" />
    <path d="M8 11V8a4 4 0 0 1 8 0v3" />
  </Svg>
);

export const Search = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <circle cx="11" cy="11" r="7" />
    <path d="M20 20l-4-4" />
  </Svg>
);

export const Players = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <circle cx="9" cy="8" r="3" />
    <circle cx="16.5" cy="9" r="2.5" />
    <path d="M3 19c0-3 3-5 6-5s6 2 6 5M15 14c3 0 6 1.5 6 4.5" />
  </Svg>
);

export const Arrow = (p: IconProps) => (
  <Svg strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" {...p}>
    <path d="M5 12h14M13 6l6 6-6 6" />
  </Svg>
);

export const QrIcon = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" {...p}>
    <rect x="3" y="3" width="7" height="7" rx="1" />
    <rect x="14" y="3" width="7" height="7" rx="1" />
    <rect x="3" y="14" width="7" height="7" rx="1" />
    <path d="M14 14h3v3M21 14v.01M14 21h7M18 18h3" />
  </Svg>
);

/** O quadro de leitura (cantos recortados), usado no botão de check-in. */
export const ScanFrame = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" {...p}>
    <path d="M3 8V4.5A1.5 1.5 0 0 1 4.5 3H8M16 3h3.5A1.5 1.5 0 0 1 21 4.5V8M21 16v3.5a1.5 1.5 0 0 1-1.5 1.5H16M8 21H4.5A1.5 1.5 0 0 1 3 19.5V16" />
    <rect x="7" y="7" width="4" height="4" />
    <rect x="13" y="13" width="4" height="4" />
  </Svg>
);

export const NfcIcon = (p: IconProps) => (
  <Svg strokeWidth="2.2" strokeLinecap="round" {...p}>
    <path d="M6 8.5a5 5 0 0 1 0 7M10 6a9 9 0 0 1 0 12M14 3.5a13 13 0 0 1 0 17" />
  </Svg>
);

export const CourtsTab = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <rect x="4" y="3" width="16" height="18" rx="1.5" />
    <path d="M4 12h16M8 3v18M16 3v18M8 7.5h8M8 16.5h8" />
  </Svg>
);

export const BoardTab = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <rect x="3" y="5" width="18" height="14" rx="1.5" />
    <path d="M12 5v14M7 10v4M17 10v4" />
  </Svg>
);

export const ProfileTab = (p: IconProps) => (
  <Svg strokeWidth="2" strokeLinecap="round" {...p}>
    <circle cx="12" cy="8" r="4" />
    <path d="M4 21c0-4 4-6 8-6s8 2 8 6" />
  </Svg>
);

/** Ícone do piso: saibro, rápida ou grama. */
export function SurfaceIcon({ surface, size = 13 }: { surface: string; size?: number }) {
  if (surface === "clay") {
    return (
      <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <circle cx="6" cy="6" r="2" />
        <circle cx="12" cy="9" r="2" />
        <circle cx="18" cy="6" r="2" />
        <circle cx="6" cy="16" r="2" />
        <circle cx="12" cy="19" r="2" />
        <circle cx="18" cy="16" r="2" />
      </svg>
    );
  }
  if (surface === "grass") {
    return (
      <Svg size={size} strokeWidth="2.4" strokeLinecap="round">
        <path d="M5 20c0-9 6-14 15-15-1 9-6 15-15 15z" />
        <path d="M5 20l8-8" />
      </Svg>
    );
  }
  return (
    <Svg size={size} strokeWidth="2.4">
      <rect x="3" y="4" width="18" height="16" rx="1" />
      <path d="M12 4v16M3 12h18" />
    </Svg>
  );
}
