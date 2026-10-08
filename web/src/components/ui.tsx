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

/** Folha que sobe de baixo — o padrão de modal do protótipo. */
export function Sheet({
  title,
  onClose,
  children,
  labelledBy = "sheet-title",
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  labelledBy?: string;
}) {
  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 40,
        display: "flex",
        alignItems: "flex-end",
        justifyContent: "center",
        background: "rgba(10,14,11,.5)",
      }}
      onClick={onClose}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        className="sheet scroll"
        onClick={(event) => event.stopPropagation()}
        style={{
          width: "100%",
          maxWidth: 480,
          maxHeight: "92dvh",
          overflowY: "auto",
          background: "var(--bg)",
          borderRadius: "16px 16px 0 0",
          padding: "16px 18px 24px",
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 12,
            marginBottom: 14,
          }}
        >
          <h2 id={labelledBy} className="bb" style={{ margin: 0, fontSize: 26, color: "var(--green)" }}>
            {title}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Fechar"
            className="press"
            style={{
              width: 44,
              height: 44,
              display: "grid",
              placeItems: "center",
              background: "transparent",
              border: "1.5px solid rgba(47,70,41,.3)",
              borderRadius: 10,
              color: "var(--green)",
            }}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
        {children}
      </div>
    </div>
  );
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
