import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { profileSummary, racketPalette, updateProfile } from "../lib/api";
import { enablePush, isIos, isStandalone, pushSupported } from "../lib/push";
import { invalidateMe, toneStyle } from "../lib/me";
import { lastCourt, lastPark } from "../lib/nav";
import { Racket, stackStyle } from "../components/Racket";
import { BottomNav } from "../components/BottomNav";
import { Camera, Check, ChevronLeft, ChevronRight, Lock } from "../components/icons";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { initialsOf } from "../lib/format";
import { authMessage } from "../lib/auth-messages";
import { supabase } from "../lib/supabase";
import { useAuth } from "../hooks/useAuth";
import type { PaletteColor, ProfileSummary } from "../lib/types";

export function Profile() {
  const { signOut } = useAuth();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const parkId = lastPark();
  // Quem chegou pelo link de "esqueci minha senha" tem uma sessão de
  // recuperação: é a única janela em que dá para definir a senha nova.
  const recovering = params.get("reset") === "1";
  const [data, setData] = useState<ProfileSummary | null>(null);
  const [palette, setPalette] = useState<PaletteColor[]>([]);
  const [frame, setFrame] = useState("#C49051");
  const [grip, setGrip] = useState("#F1ECEF");
  const [tone, setTone] = useState(0);
  const [name, setName] = useState("");
  const [error, setError] = useState<Error | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pwOpen, setPwOpen] = useState(false);
  const [pwSent, setPwSent] = useState(false);
  const [newPassword, setNewPassword] = useState("");

  async function load() {
    setError(null);
    try {
      const [summary, colors] = await Promise.all([profileSummary(), racketPalette()]);
      setData(summary);
      setPalette(colors);
      setName(summary.profile?.full_name ?? "");
      setFrame(summary.profile?.racket_frame_color ?? "#C49051");
      setGrip(summary.profile?.racket_grip_color ?? "#F1ECEF");
      setTone(summary.profile?.avatar_tone ?? 0);
    } catch (cause) {
      setError(cause as Error);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  useEffect(() => {
    if (recovering) setPwOpen(true);
  }, [recovering]);

  // Cada escolha vale na hora: é assim que o jogador vê a raquete dele
  // mudar na pilha sem passar por um botão de salvar.
  async function persist(patch: {
    fullName?: string;
    frameColor?: string;
    gripColor?: string;
    avatarTone?: number;
  }) {
    setBusy(true);
    setNotice(null);
    try {
      await updateProfile(patch);
      invalidateMe();
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

  async function savePassword() {
    if (newPassword.length < 8) {
      setNotice("A senha precisa de pelo menos 8 caracteres.");
      return;
    }
    setBusy(true);
    const { error: cause } = await supabase.auth.updateUser({ password: newPassword });
    setBusy(false);
    setNewPassword("");
    if (cause) {
      setNotice(authMessage(cause));
      return;
    }
    setNotice("Senha atualizada. Da próxima vez, entre com ela.");
    setPwOpen(false);
    params.delete("reset");
    setParams(params, { replace: true });
  }

  async function resetPassword() {
    const email = data?.profile?.email;
    if (!email) return;
    setBusy(true);
    const { error: cause } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/callback?reset=1`,
    });
    setBusy(false);
    setPwSent(!cause);
    setNotice(cause ? authMessage(cause) : "Enviamos um link de troca de senha para o seu e-mail.");
  }

  if (error) return <ErrorState title="Não conseguimos carregar o perfil" detail={error.message} onRetry={load} />;
  if (!data) return <Loading what="Carregando perfil" />;

  const avatar = toneStyle(tone);
  const queued = data.active_entries.length > 0;
  const frameName = palette.find((c) => c.color === frame)?.name ?? "";
  const gripName = palette.find((c) => c.color === grip)?.name ?? "";
  const preview: Array<[string, string]> = [
    ["#6D9CB7", "#F1ECEF"],
    ["#B13F16", "#D0C0C9"],
    ["#F1ECEF", "#74B69D"],
    [frame, grip],
  ];

  return (
    <>
      <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 18, paddingBottom: 28 }}>
        {/* ----------------------------- topo ----------------------------- */}
        <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: "22px 18px 20px", background: "var(--green)", color: "var(--chalk)", borderRadius: "0 0 16px 16px" }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            {/*
              Sem o parque na sessão (quem veio direto da lista) a barra
              inferior não aparece — então a volta tem de estar sempre
              aqui, ou a tela vira um beco sem saída.
            */}
            <button
              type="button"
              className="press"
              onClick={() => navigate(parkId ? `/parque/${parkId}` : "/")}
              aria-label={parkId ? "Voltar para as quadras" : "Voltar para os parques"}
              style={{ display: "flex", alignItems: "center", gap: 4, minHeight: 44, padding: "0 10px 0 0", background: "transparent", border: 0, color: "var(--chalk)" }}
            >
              <ChevronLeft size={20} />
              <span className="bb" style={{ fontSize: 26, lineHeight: 1 }}>Perfil</span>
            </button>
            <span style={{ fontSize: 12, fontWeight: 600, color: "var(--mauve)" }}>{data.profile?.email}</span>
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
            <div className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 76, height: 76, borderRadius: 12, border: "2px solid var(--chalk)", fontSize: 38, flexShrink: 0, ...avatar }}>
              {initialsOf(name || data.profile?.username)}
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 0 }}>
              <span className="bb" style={{ fontSize: 34, lineHeight: 0.95 }}>{name || data.profile?.username}</span>
              <span style={{ fontSize: 14, color: "var(--mauve)" }}>@{data.profile?.username}</span>
            </div>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: 10 }}>
            <button
              type="button"
              className="press"
              disabled={busy}
              onClick={() => {
                const next = (tone + 1) % 3;
                setTone(next);
                void persist({ avatarTone: next });
              }}
              style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8, minHeight: 44, background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 13, fontWeight: 600 }}
            >
              <Camera size={16} />
              Trocar o tom
            </button>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 6, minHeight: 44, background: "rgba(241,236,239,.1)", borderRadius: 8, fontSize: 13, fontWeight: 600 }}>
              {queued
                ? <><span className="dot" style={{ background: "var(--ocre)" }} />Na fila</>
                : "Fora de fila"}
            </div>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", border: "1.5px solid rgba(241,236,239,.3)", borderRadius: 8 }}>
            <Stat value={data.stats.matches_played} label="Partidas" divider />
            <Stat value={data.stats.courts_visited} label="Quadras" divider />
            <Stat value={Math.round(data.stats.minutes_played / 60)} label="Horas" />
          </div>
        </div>

        {/* -------------------------- minha raquete -------------------------- */}
        <div style={{ display: "flex", flexDirection: "column", gap: 14, margin: "0 16px", padding: 16, background: "var(--chalk)", border: "1px solid rgba(47,70,41,.18)", borderRadius: 12 }}>
          <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between" }}>
            <h2 className="bb" style={{ margin: 0, fontSize: 26, lineHeight: 1, color: "var(--green)" }}>Minha Raquete</h2>
            <span style={{ fontSize: 12, fontWeight: 600, color: "var(--green)" }}>Avatar digital</span>
          </div>

          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", height: 120, background: "var(--green)", borderRadius: 10, position: "relative", overflow: "hidden" }}>
            <span style={{ position: "absolute", left: 14, right: 14, top: "50%", height: 1, background: "rgba(241,236,239,.18)" }} />
            <Racket
              frame={frame}
              grip={grip}
              face="#2F4629"
              strung
              width={286}
              height={98}
              style={{ position: "relative", maxWidth: "100%" }}
            />
          </div>

          <Swatches
            label="Cor do aro"
            current={frame}
            currentName={frameName}
            colors={palette}
            kind="Aro"
            onPick={(color) => { setFrame(color); void persist({ frameColor: color }); }}
          />
          <Swatches
            label="Grip e encordoamento"
            current={grip}
            currentName={gripName}
            colors={palette}
            kind="Grip"
            onPick={(color) => { setGrip(color); void persist({ gripColor: color }); }}
          />

          <div style={{ display: "flex", alignItems: "center", gap: 12, paddingTop: 12, borderTop: "1px dashed rgba(47,70,41,.3)" }}>
            <div
              role="img"
              aria-label="Sua raquete no topo de uma pilha de espera"
              style={{ position: "relative", flexShrink: 0, width: 88, height: 66, background: "var(--green)", borderRadius: 8, overflow: "hidden" }}
            >
              <span style={{ position: "absolute", left: 6, right: 6, bottom: 5, height: 2, background: "rgba(241,236,239,.35)" }} />
              {preview.map(([f, g], index) => (
                <span key={index} style={stackStyle(index)}>
                  <Racket frame={f} grip={g} face="#2F4629" />
                </span>
              ))}
            </div>
            <span style={{ fontSize: 13, lineHeight: 1.4, color: "var(--green)" }}>
              É assim que você aparece no topo da pilha quando entra na fila.
            </span>
          </div>
        </div>

        {/* ------------------------------ conta ------------------------------ */}
        <div style={{ display: "flex", flexDirection: "column", gap: 12, margin: "0 16px" }}>
          <h2 className="bb" style={{ margin: 0, fontSize: 26, lineHeight: 1, color: "var(--green)", borderBottom: "2px solid var(--green)", paddingBottom: 6 }}>
            Conta
          </h2>

          <label style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 13, fontWeight: 700 }}>
            Nome
            <input
              type="text"
              value={name}
              onChange={(event) => setName(event.target.value)}
              onBlur={() => void persist({ fullName: name })}
              style={{ height: 48, padding: "0 14px", background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.35)", borderRadius: 8, fontSize: 15, fontWeight: 500, color: "var(--ink)" }}
            />
          </label>

          <Row
            icon={<Lock size={18} />}
            label={recovering ? "Defina a senha nova" : "Alterar senha"}
            hint={recovering ? "Agora" : pwSent ? "Link enviado" : "Por e-mail"}
            expanded={pwOpen}
            onClick={() => setPwOpen((value) => !value)}
          />
          {pwOpen && (
            <div className="fade" style={{ display: "flex", flexDirection: "column", gap: 10, padding: 14, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.2)", borderRadius: 8 }}>
              {recovering
                ? (
                  <>
                    <span style={{ fontSize: 13, lineHeight: 1.45, color: "var(--muted)" }}>
                      Você entrou pelo link do e-mail. Escolha a senha nova agora — o link só
                      vale uma vez.
                    </span>
                    <label style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 13, fontWeight: 700 }}>
                      Senha nova
                      <input
                        type="password"
                        value={newPassword}
                        onChange={(event) => setNewPassword(event.target.value)}
                        autoComplete="new-password"
                        minLength={8}
                        style={{ height: 46, padding: "0 12px", background: "var(--bg)", border: "1.5px solid rgba(47,70,41,.35)", borderRadius: 8, fontSize: 15 }}
                      />
                      <span style={{ fontSize: 12, fontWeight: 500, color: "var(--muted)" }}>
                        Pelo menos 8 caracteres.
                      </span>
                    </label>
                    <button type="button" className="press" disabled={busy} onClick={() => void savePassword()} style={{ minHeight: 46, background: "var(--green)", color: "var(--chalk)", border: 0, borderRadius: 8, fontSize: 14, fontWeight: 700 }}>
                      Salvar nova senha
                    </button>
                  </>
                )
                : (
                  <>
                    <span style={{ fontSize: 13, lineHeight: 1.45, color: "var(--muted)" }}>
                      Mandamos um link para <strong>{data.profile?.email}</strong>. Trocar a senha
                      por lá evita que alguém com o celular na mão mude a sua.
                    </span>
                    <button type="button" className="press" disabled={busy} onClick={() => void resetPassword()} style={{ minHeight: 46, background: "var(--green)", color: "var(--chalk)", border: 0, borderRadius: 8, fontSize: 14, fontWeight: 700 }}>
                      Enviar link de troca de senha
                    </button>
                  </>
                )}
            </div>
          )}

          <Row
            icon={<Check size={18} strokeWidth="2.4" />}
            label="Avisos da fila"
            hint={pushSupported() ? (isIos() && !isStandalone() ? "Adicione à tela de início" : "Ligar") : "Indisponível"}
            onClick={() => void notifications()}
            disabled={busy || !pushSupported()}
          />

          {notice && (
            <p role="status" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, lineHeight: 1.4, background: "rgba(116,182,157,.18)", color: "var(--green)" }}>
              {notice}
            </p>
          )}

          <button type="button" className="press" onClick={() => void signOut()} style={buttonStyle("danger")}>
            Sair da conta
          </button>
        </div>
      </div>

      {parkId && <BottomNav parkId={parkId} tab="profile" courtId={lastCourt(parkId) ?? undefined} />}
    </>
  );
}

function Swatches({
  label,
  currentName,
  colors,
  current,
  kind,
  onPick,
}: {
  label: string;
  currentName: string;
  colors: PaletteColor[];
  current: string;
  kind: string;
  onPick: (color: string) => void;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <span style={{ display: "flex", justifyContent: "space-between", fontSize: 13, fontWeight: 700 }}>
        {label}
        <span style={{ fontWeight: 500, color: "var(--green)" }}>{currentName}</span>
      </span>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(6, minmax(0, 1fr))", gap: 8 }}>
        {colors.map((option) => {
          const selected = option.color === current;
          return (
            <button
              key={option.color}
              type="button"
              className="press"
              onClick={() => onPick(option.color)}
              aria-label={`${kind} ${option.name}`}
              aria-pressed={selected}
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                height: 44,
                borderRadius: 8,
                background: option.color,
                border: selected ? "3px solid var(--ink)" : "1.5px solid rgba(10,14,11,.3)",
              }}
            >
              {selected && <span style={{ color: "var(--ink)", display: "flex" }}><Check size={18} /></span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function Row({
  icon,
  label,
  hint,
  onClick,
  expanded,
  disabled,
}: {
  icon: React.ReactNode;
  label: string;
  hint: string;
  onClick: () => void;
  expanded?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className="press"
      onClick={onClick}
      disabled={disabled}
      aria-expanded={expanded}
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        minHeight: 52,
        padding: "0 14px",
        background: "var(--chalk)",
        border: "1.5px solid rgba(47,70,41,.2)",
        borderRadius: 8,
        color: "var(--ink)",
        fontSize: 14,
        fontWeight: 600,
        opacity: disabled ? 0.55 : 1,
      }}
    >
      <span style={{ display: "flex", alignItems: "center", gap: 10 }}>{icon}{label}</span>
      <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--green)" }}>
        {hint}
        <ChevronRight size={18} />
      </span>
    </button>
  );
}

function Stat({ value, label, divider }: { value: number; label: string; divider?: boolean }) {
  return (
    <span style={{ display: "flex", flexDirection: "column", padding: "8px 10px", borderRight: divider ? "1px solid rgba(241,236,239,.2)" : undefined }}>
      <span className="bb" style={{ fontSize: 26, lineHeight: 1 }}>{String(value).padStart(2, "0")}</span>
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--mauve)" }}>{label}</span>
    </span>
  );
}
