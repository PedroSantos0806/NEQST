import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { profileSummary, racketPalette, updateProfile } from "../lib/api";
import { enablePush, isIos, isStandalone, pushSupported } from "../lib/push";
import { Racket } from "../components/Racket";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { initialsOf } from "../lib/format";
import { supabase } from "../lib/supabase";
import { useAuth } from "../hooks/useAuth";
import type { PaletteColor, ProfileSummary } from "../lib/types";

const TONES = [
  { background: "#B13F16", color: "#FFFFFF" },
  { background: "#39678C", color: "#FFFFFF" },
  { background: "#C49051", color: "#0A0E0B" },
];

export function Profile() {
  const { signOut } = useAuth();
  const [data, setData] = useState<ProfileSummary | null>(null);
  const [palette, setPalette] = useState<PaletteColor[]>([]);
  const [frame, setFrame] = useState("#C49051");
  const [grip, setGrip] = useState("#F1ECEF");
  const [tone, setTone] = useState(0);
  const [name, setName] = useState("");
  const [error, setError] = useState<Error | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    try {
      const [summary, colors] = await Promise.all([profileSummary(), racketPalette()]);
      setData(summary);
      setPalette(colors);
      setName(summary.profile?.full_name ?? "");
    } catch (cause) {
      setError(cause as Error);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  async function save() {
    setBusy(true);
    setNotice(null);
    try {
      await updateProfile({ fullName: name, frameColor: frame, gripColor: grip, avatarTone: tone });
      setNotice("Perfil salvo.");
    } catch (cause) {
      setNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function notifications() {
    setBusy(true);
    const result = await enablePush();
    setBusy(false);
    setNotice({
      subscribed: "Notificações ligadas. Avisamos quando for a sua vez.",
      denied: "Você bloqueou as notificações no navegador. Libere nas configurações do site.",
      unsupported: "Este navegador não suporta notificações.",
      "needs-install": "No iPhone, adicione o NEQST à tela de início para receber avisos.",
      "no-vapid": "As notificações ainda não estão configuradas no servidor.",
    }[result]);
  }

  async function resetPassword() {
    const email = data?.profile?.email;
    if (!email) return;
    setBusy(true);
    const { error: cause } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/callback?reset=1`,
    });
    setBusy(false);
    setNotice(cause ? cause.message : "Enviamos um link de troca de senha para o seu e-mail.");
  }

  if (error) return <ErrorState title="Não conseguimos carregar o perfil" detail={error.message} onRetry={load} />;
  if (!data) return <Loading what="Carregando perfil" />;

  const toneStyle = TONES[tone % TONES.length];

  return (
    <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 18, padding: "22px 18px 40px" }}>
      <Link to="/" style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 13, fontWeight: 700, color: "var(--green)", textDecoration: "none", minHeight: 44 }}>
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M15 6l-6 6 6 6" />
        </svg>
        Parques
      </Link>

      <header style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <button
          type="button"
          onClick={() => setTone((value) => (value + 1) % TONES.length)}
          aria-label="Trocar a cor do avatar"
          className="press"
          style={{
            width: 64,
            height: 64,
            borderRadius: 14,
            border: "2px solid var(--ink)",
            display: "grid",
            placeItems: "center",
            fontSize: 22,
            fontWeight: 800,
            ...toneStyle,
          }}
        >
          {initialsOf(name || data.profile?.username)}
        </button>
        <div style={{ display: "flex", flexDirection: "column", gap: 2, minWidth: 0 }}>
          <span className="bb" style={{ fontSize: 32, lineHeight: 1 }}>{name || data.profile?.username}</span>
          <span style={{ fontSize: 13, color: "var(--green)" }}>@{data.profile?.username}</span>
          <span style={{ fontSize: 12, color: "var(--muted)" }}>{data.profile?.email}</span>
        </div>
      </header>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", background: "var(--green)", borderRadius: 10, color: "var(--chalk)" }}>
        <Stat value={data.stats.matches_played} label="Partidas" divider />
        <Stat value={data.stats.courts_visited} label="Quadras" divider />
        <Stat value={Math.round(data.stats.minutes_played / 60)} label="Horas" />
      </div>

      <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <span style={{ fontSize: 13, fontWeight: 700, color: "var(--green)" }}>Nome</span>
        <input
          value={name}
          onChange={(event) => setName(event.target.value)}
          style={{ minHeight: 48, padding: "12px 14px", background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 10, fontSize: 15 }}
        />
      </label>

      <section style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <h2 className="bb" style={{ margin: 0, fontSize: 24, color: "var(--green)" }}>Sua raquete</h2>
        <p style={{ margin: 0, fontSize: 13, color: "var(--muted)", lineHeight: 1.45 }}>
          É ela que aparece na pilha da fila, para você se achar de longe.
        </p>

        <div style={{ display: "grid", placeItems: "center", padding: 16, background: "var(--green)", borderRadius: 12 }}>
          <Racket frame={frame} grip={grip} face="var(--ink)" style={{ width: 128, height: 44 }} />
        </div>

        <Swatches label="Aro" colors={palette} current={frame} onPick={setFrame} />
        <Swatches label="Grip" colors={palette} current={grip} onPick={setGrip} />
      </section>

      {notice && (
        <p role="status" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, background: "rgba(116,182,157,.18)", color: "var(--green)" }}>
          {notice}
        </p>
      )}

      <button type="button" className="press" disabled={busy} onClick={() => void save()} style={buttonStyle("primary", busy)}>
        Salvar perfil
      </button>

      <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <h2 className="bb" style={{ margin: 0, fontSize: 24, color: "var(--green)" }}>Avisos</h2>
        <p style={{ margin: 0, fontSize: 13, color: "var(--muted)", lineHeight: 1.45 }}>
          {pushSupported()
            ? isIos() && !isStandalone()
              ? "No iPhone, toque em Compartilhar › Adicionar à Tela de Início para poder receber avisos."
              : "Avisamos quando faltar um time para a sua vez e quando chegar a hora."
            : "Este navegador não suporta notificações."}
        </p>
        <button type="button" className="press" disabled={busy || !pushSupported()} onClick={() => void notifications()} style={buttonStyle("ghost")}>
          Ligar notificações
        </button>
      </section>

      <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <button type="button" className="press" disabled={busy} onClick={() => void resetPassword()} style={buttonStyle("ghost")}>
          Trocar a senha
        </button>
        <button type="button" className="press" onClick={() => void signOut()} style={buttonStyle("danger")}>
          Sair da conta
        </button>
      </section>
    </div>
  );
}

function Swatches({
  label,
  colors,
  current,
  onPick,
}: {
  label: string;
  colors: PaletteColor[];
  current: string;
  onPick: (color: string) => void;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <span style={{ fontSize: 13, fontWeight: 700, color: "var(--green)" }}>{label}</span>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {colors.map((option) => (
          <button
            key={option.color}
            type="button"
            onClick={() => onPick(option.color)}
            aria-label={`${label} ${option.name}`}
            aria-pressed={option.color === current}
            className="press"
            style={{
              width: 44,
              height: 44,
              borderRadius: 10,
              background: option.color,
              border: option.color === current ? "3px solid var(--ink)" : "1.5px solid rgba(10,14,11,.3)",
            }}
          />
        ))}
      </div>
    </div>
  );
}

function Stat({ value, label, divider }: { value: number; label: string; divider?: boolean }) {
  return (
    <span style={{ display: "flex", flexDirection: "column", padding: "10px 12px", borderRight: divider ? "1px solid rgba(241,236,239,.2)" : undefined }}>
      <span className="bb" style={{ fontSize: 28, lineHeight: 1 }}>{String(value).padStart(2, "0")}</span>
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--mauve)" }}>{label}</span>
    </span>
  );
}
