import type { CSSProperties, ReactNode } from "react";

export function Spinner({ label = "Carregando" }: { label?: string }) {
  return (
    <span
      role="status"
      aria-label={label}
      className="spin"
      style={{
        display: "inline-block",
        width: 20,
        height: 20,
        border: "2.5px solid rgba(47,70,41,.25)",
        borderTopColor: "var(--green)",
        borderRadius: "50%",
      }}
    />
  );
}

export function Loading({ what }: { what: string }) {
  return (
    <div
      className="fade"
      style={{ display: "flex", alignItems: "center", gap: 10, padding: 28, color: "var(--green)" }}
    >
      <Spinner />
      <span style={{ fontSize: 14, fontWeight: 600 }}>{what}</span>
    </div>
  );
}

/**
 * Erro sempre com saída: o critério da US-04 pede feedback claro, e em
 * conexão instável "tentar de novo" é o que o usuário precisa.
 */
export function ErrorState({
  title,
  detail,
  onRetry,
}: {
  title: string;
  detail?: string;
  onRetry?: () => void;
}) {
  return (
    <div
      role="alert"
      className="fade"
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 10,
        margin: 18,
        padding: 16,
        background: "var(--chalk)",
        border: "1.5px solid rgba(177,63,22,.4)",
        borderRadius: 12,
      }}
    >
      <strong style={{ fontSize: 15, color: "var(--rust)" }}>{title}</strong>
      {detail && <span style={{ fontSize: 13, lineHeight: 1.45, color: "var(--muted)" }}>{detail}</span>}
      {onRetry && (
        <button type="button" className="press tap" onClick={onRetry} style={buttonStyle("ghost")}>
          Tentar de novo
        </button>
      )}
    </div>
  );
}

/**
 * O campo de texto do app. Vivia dentro da tela de administração e foi
 * recopiado à mão dentro do mapa — duas definições do mesmo controle,
 * que já tinham começado a divergir na altura.
 */
export function fieldStyle(height = 44): CSSProperties {
  return {
    width: "100%",
    height,
    padding: height >= 44 ? "0 12px" : "0 10px",
    background: height >= 44 ? "var(--chalk)" : "var(--bg)",
    border: "1.5px solid rgba(47,70,41,.3)",
    borderRadius: 8,
    fontSize: height >= 44 ? 14 : 13,
    color: "var(--ink)",
  };
}

export type ButtonTone = "primary" | "dark" | "ghost" | "danger";

export function buttonStyle(tone: ButtonTone = "primary", disabled = false): CSSProperties {
  const base: CSSProperties = {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    minHeight: 48,
    padding: "12px 16px",
    borderRadius: 10,
    fontSize: 15,
    fontWeight: 700,
    width: "100%",
  };

  if (disabled) {
    return { ...base, background: "var(--mauve)", color: "var(--muted)", border: "2px solid transparent" };
  }

  switch (tone) {
    case "dark":
      return { ...base, background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--green)" };
    case "ghost":
      return {
        ...base,
        background: "transparent",
        color: "var(--green)",
        border: "1.5px solid rgba(47,70,41,.35)",
      };
    case "danger":
      return { ...base, background: "transparent", color: "var(--rust)", border: "1.5px solid rgba(177,63,22,.45)" };
    default:
      return { ...base, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)" };
  }
}

export function Badge({
  children,
  background,
  color = "#FFFFFF",
}: {
  children: ReactNode;
  background: string;
  color?: string;
}) {
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 5,
        padding: "4px 8px",
        background,
        color,
        borderRadius: 6,
        fontSize: 11,
        fontWeight: 700,
        letterSpacing: ".06em",
        textTransform: "uppercase",
      }}
    >
      {children}
    </span>
  );
}
