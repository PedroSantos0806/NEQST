import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  adminOverview,
  adminSetRole,
  adminUpsertPark,
  adminUsers,
  courtQr,
} from "../lib/api";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { ChevronLeft, Close, Pin, Search, SurfaceIcon, Warn } from "../components/icons";
import { SURFACE_COLOR, surfaceTextColor } from "../lib/format";
import { AdminPilot } from "./AdminPilot";
import { CourtForm, ParkForm, field } from "./admin-forms";
import type { AdminCourt, AdminOverview, AdminPark, AdminUser, CourtQr } from "../lib/types";

type Tab = "quadras" | "pessoas" | "piloto";

export function Admin() {
  const navigate = useNavigate();
  const [tab, setTab] = useState<Tab>("quadras");
  const [data, setData] = useState<AdminOverview | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      setData(await adminOverview());
    } catch (cause) {
      setError(cause as Error);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  if (error) {
    return (
      <ErrorState
        title="Não conseguimos abrir a administração"
        detail={error.message}
        onRetry={load}
      />
    );
  }
  if (!data) return <Loading what="Carregando a administração" />;

  return (
    <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 16, paddingBottom: 32 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: "20px 18px 18px", background: "var(--ink)", color: "var(--chalk)", borderRadius: "0 0 16px 16px" }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <button
            type="button"
            className="press"
            onClick={() => navigate("/")}
            aria-label="Voltar para os parques"
            style={{ display: "flex", alignItems: "center", gap: 4, minHeight: 44, padding: 0, background: "transparent", border: 0, color: "var(--chalk)" }}
          >
            <ChevronLeft size={20} />
            <span className="bb" style={{ fontSize: 26, lineHeight: 1 }}>Administração</span>
          </button>
          <span style={{ padding: "4px 8px", background: "var(--ocre)", color: "var(--ink)", borderRadius: 6, fontSize: 10, fontWeight: 800, letterSpacing: ".1em" }}>
            ADMIN
          </span>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", border: "1.5px solid rgba(241,236,239,.3)", borderRadius: 8 }}>
          <Stat value={data.totals.parks} label="Parques" divider />
          <Stat value={data.totals.courts} label="Quadras" divider />
          <Stat value={data.totals.users} label="Pessoas" />
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", padding: 4, background: "rgba(241,236,239,.1)", borderRadius: 10 }}>
          {(["quadras", "pessoas", "piloto"] as const).map((option) => (
            <button
              key={option}
              type="button"
              className="press"
              onClick={() => setTab(option)}
              aria-pressed={tab === option}
              style={{
                minHeight: 44,
                border: 0,
                borderRadius: 8,
                fontSize: 14,
                fontWeight: 700,
                textTransform: "capitalize",
                background: tab === option ? "var(--chalk)" : "transparent",
                color: tab === option ? "var(--ink)" : "var(--chalk)",
              }}
            >
              {option}
            </button>
          ))}
        </div>
      </div>

      {notice && (
        <p role="status" style={{ margin: "0 16px", padding: "10px 12px", borderRadius: 8, fontSize: 13, background: "rgba(116,182,157,.18)", color: "var(--green)" }}>
          {notice}
        </p>
      )}

      {tab === "quadras" && <Courts data={data} onChanged={load} onNotice={setNotice} />}
      {tab === "pessoas" && <People onNotice={setNotice} />}
      {tab === "piloto" && <AdminPilot data={data} />}
    </div>
  );
}

// =====================================================================
// Parques e quadras
// =====================================================================

function Courts({
  data,
  onChanged,
  onNotice,
}: {
  data: AdminOverview;
  onChanged: () => Promise<void>;
  onNotice: (text: string) => void;
}) {
  const [newPark, setNewPark] = useState(false);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, margin: "0 16px" }}>
      {data.parks.map((park) => (
        <ParkCard key={park.id} park={park} onChanged={onChanged} onNotice={onNotice} />
      ))}

      {data.parks.length === 0 && !newPark && (
        <p style={{ margin: 0, fontSize: 14, lineHeight: 1.5, color: "var(--muted)" }}>
          Nenhum parque ainda. Cadastre o primeiro para que o app tenha o que mostrar.
        </p>
      )}

      {newPark
        ? (
          <ParkForm
            onCancel={() => setNewPark(false)}
            onSaved={async () => {
              setNewPark(false);
              onNotice("Parque criado.");
              await onChanged();
            }}
          />
        )
        : (
          <button type="button" className="press" onClick={() => setNewPark(true)} style={buttonStyle("primary")}>
            Novo parque
          </button>
        )}
    </div>
  );
}

function ParkCard({
  park,
  onChanged,
  onNotice,
}: {
  park: AdminPark;
  onChanged: () => Promise<void>;
  onNotice: (text: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState(false);
  const [addingCourt, setAddingCourt] = useState(false);
  const [busy, setBusy] = useState(false);
  const [blocked, setBlocked] = useState(false);

  // Recolher o parque desmonta o formulário aberto, e com ele tudo o
  // que já foi digitado — nome, endereço e o alfinete marcado no mapa.
  // Um toque sem querer no cabeçalho jogava fora um minuto de trabalho
  // sem perguntar nada. Agora o cabeçalho avisa em vez de obedecer.
  const formOpen = editing || addingCourt;

  function toggleOpen() {
    if (open && formOpen) {
      setBlocked(true);
      return;
    }
    setBlocked(false);
    setOpen((value) => !value);
  }

  async function toggleActive() {
    setBusy(true);
    try {
      await adminUpsertPark({ id: park.id, isActive: !park.is_active });
      onNotice(park.is_active ? "Parque desativado." : "Parque reativado.");
      await onChanged();
    } catch (cause) {
      onNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ background: "var(--chalk)", border: "1px solid rgba(47,70,41,.2)", borderRadius: 12, overflow: "hidden" }}>
      <button
        type="button"
        className="press"
        onClick={toggleOpen}
        aria-expanded={open}
        style={{ display: "flex", alignItems: "center", gap: 10, width: "100%", padding: 14, background: "transparent", border: 0, textAlign: "left", color: "var(--ink)" }}
      >
        <span style={{ display: "flex", flexDirection: "column", gap: 3, flexGrow: 1, minWidth: 0 }}>
          <span className="bb" style={{ fontSize: 24, lineHeight: 1 }}>{park.name}</span>
          <span style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 12, fontWeight: 600, color: "var(--green)" }}>
            <Pin size={13} />
            {park.district ?? park.city ?? "sem bairro"} · {park.courts.length}{" "}
            {park.courts.length === 1 ? "quadra" : "quadras"}
          </span>
        </span>
        {!park.is_active && (
          <span style={{ padding: "3px 7px", background: "var(--mauve)", color: "var(--muted)", borderRadius: 4, fontSize: 10, fontWeight: 800 }}>
            INATIVO
          </span>
        )}
      </button>

      {open && (
        <div className="fade" style={{ display: "flex", flexDirection: "column", gap: 10, padding: "0 14px 14px" }}>
          {blocked && (
            <p role="alert" style={{ margin: 0, padding: "10px 12px", background: "rgba(196,144,81,.18)", border: "1.5px solid var(--ocre)", borderRadius: 8, fontSize: 12, lineHeight: 1.45, color: "var(--ink)" }}>
              Há um formulário aberto aqui dentro. <strong>Salve ou cancele</strong> antes de
              fechar o parque — fechar agora descartaria o que você já preencheu.
            </p>
          )}
          {editing
            ? (
              <ParkForm
                park={park}
                onCancel={() => { setEditing(false); setBlocked(false); }}
                onSaved={async () => {
                  setEditing(false);
                  setBlocked(false);
                  onNotice("Parque atualizado.");
                  await onChanged();
                }}
              />
            )
            : (
              <div style={{ display: "flex", gap: 8 }}>
                <button type="button" className="press" onClick={() => setEditing(true)} style={{ ...buttonStyle("ghost"), minHeight: 40, fontSize: 13 }}>
                  Editar parque
                </button>
                <button type="button" className="press" disabled={busy} onClick={() => void toggleActive()} style={{ ...buttonStyle("ghost"), minHeight: 40, fontSize: 13 }}>
                  {park.is_active ? "Desativar" : "Reativar"}
                </button>
              </div>
            )}

          {park.courts.map((court) => (
            <CourtRow key={court.id} court={court} park={park} onChanged={onChanged} onNotice={onNotice} />
          ))}

          {addingCourt
            ? (
              <CourtForm
                park={park}
                nextNumber={Math.max(0, ...park.courts.map((c) => c.court_number)) + 1}
                onCancel={() => { setAddingCourt(false); setBlocked(false); }}
                onSaved={async () => {
                  setAddingCourt(false);
                  setBlocked(false);
                  onNotice("Quadra criada.");
                  await onChanged();
                }}
              />
            )
            : (
              <button type="button" className="press" onClick={() => setAddingCourt(true)} style={{ ...buttonStyle("dark"), minHeight: 44, fontSize: 14 }}>
                Adicionar quadra
              </button>
            )}
        </div>
      )}
    </div>
  );
}

function CourtRow({
  court,
  park,
  onChanged,
  onNotice,
}: {
  court: AdminCourt;
  park: AdminPark;
  onChanged: () => Promise<void>;
  onNotice: (text: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [qr, setQr] = useState<CourtQr | null>(null);
  const [busy, setBusy] = useState(false);

  async function showQr() {
    setBusy(true);
    try {
      setQr(await courtQr(court.id));
    } catch (cause) {
      onNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--bg)", border: "1px solid rgba(47,70,41,.15)", borderRadius: 10 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 5, padding: "4px 7px", borderRadius: 5, fontSize: 10, fontWeight: 700, letterSpacing: ".06em", textTransform: "uppercase", background: SURFACE_COLOR[court.surface] ?? "var(--green)", color: surfaceTextColor(court.surface) }}>
          <SurfaceIcon surface={court.surface} size={11} />
          {court.surface_label}
        </span>
        <span style={{ fontSize: 14, fontWeight: 700, flexGrow: 1, minWidth: 0 }}>{court.name}</span>
        {!court.is_active && (
          <span style={{ fontSize: 10, fontWeight: 800, color: "var(--muted)" }}>INATIVA</span>
        )}
      </div>

      <span style={{ fontSize: 12, color: "var(--green)" }}>
        Slot de {court.slot_minutes} min · tolerância {Math.round((court.call_window_seconds ?? 120) / 6) / 10} min
        · {court.queue_length} na fila
        {court.has_nfc_tag ? " · NFC" : ""}
        {typeof court.max_distance_meters === "number"
          && court.max_distance_meters !== 1000
          && ` · raio ${court.max_distance_meters} m`}
      </span>

      {court.queue_mode === "host" && (
        <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 8px", background: "rgba(196,144,81,.16)", border: "1px solid var(--ocre)", borderRadius: 6, fontSize: 11, fontWeight: 700, color: "var(--ink)" }}>
          Modo anfitrião (piloto) · {court.host_session_open ? "fila aberta agora" : "sem fila aberta"}
        </span>
      )}

      {court.enforce_proximity === false && (
        <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 8px", background: "rgba(177,63,22,.12)", border: "1px solid var(--rust)", borderRadius: 6, fontSize: 11, fontWeight: 700, color: "var(--rust)" }}>
          <Warn size={13} />
          Sem verificação de distância — só para testes
        </span>
      )}

      {editing
        ? (
          <CourtForm
            court={court}
            park={park}
            onCancel={() => setEditing(false)}
            onSaved={async () => {
              setEditing(false);
              onNotice("Quadra atualizada.");
              await onChanged();
            }}
          />
        )
        : (
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" className="press" onClick={() => setEditing(true)} style={{ ...buttonStyle("ghost"), minHeight: 38, fontSize: 12 }}>
              Editar
            </button>
            <button type="button" className="press" disabled={busy} onClick={() => void showQr()} style={{ ...buttonStyle("ghost"), minHeight: 38, fontSize: 12 }}>
              {busy ? "Gerando…" : "QR para imprimir"}
            </button>
          </div>
        )}

      {qr && <QrPanel qr={qr} onClose={() => setQr(null)} />}
    </div>
  );
}

/** O QR assinado, pronto para imprimir e colar no poste da rede. */
function QrPanel({ qr, onClose }: { qr: CourtQr; onClose: () => void }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let alive = true;
    // Carregado sob demanda: quem nunca abre a administração não baixa
    // o gerador de QR.
    void import("qrcode")
      .then(({ default: QRCode }) => {
        if (!alive || !canvas.current) return;
        return QRCode.toCanvas(canvas.current, qr.printUrl, {
          width: 240,
          margin: 1,
          color: { dark: "#0A0E0B", light: "#FFFFFF" },
          errorCorrectionLevel: "M",
        });
      })
      .catch(() => { if (alive) setFailed(true); });
    return () => { alive = false; };
  }, [qr.printUrl]);

  return (
    <div className="fade" style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, padding: 14, background: "var(--chalk)", border: "1.5px solid var(--green)", borderRadius: 10 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: "100%" }}>
        <span style={{ fontSize: 13, fontWeight: 700 }}>{qr.name} · versão {qr.version}</span>
        <button type="button" className="press" onClick={onClose} aria-label="Fechar" style={{ display: "flex", width: 32, height: 32, alignItems: "center", justifyContent: "center", background: "transparent", border: "1.5px solid rgba(10,14,11,.25)", borderRadius: 8, color: "var(--ink)" }}>
          <Close size={16} />
        </button>
      </div>

      {failed
        ? <p style={{ margin: 0, fontSize: 12, color: "var(--rust)" }}>Não foi possível desenhar o QR aqui. Use o endereço abaixo.</p>
        : <canvas ref={canvas} style={{ background: "#FFFFFF", borderRadius: 8 }} />}

      <code style={{ fontSize: 10, lineHeight: 1.4, wordBreak: "break-all", color: "var(--muted)", textAlign: "center" }}>
        {qr.printUrl}
      </code>

      {/*
        A mesma quadra, pelo caminho da tag NFC. Quem for gravar a tag
        escreve este conteúdo como registro de URL — a leitura cai no
        mesmo lugar do QR, só que por aproximação.
      */}
      <div style={{ width: "100%", paddingTop: 10, borderTop: "1px dashed rgba(47,70,41,.3)" }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, marginBottom: 6 }}>
          <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--green)" }}>
            Para gravar na tag NFC
          </span>
          <button
            type="button"
            className="press"
            onClick={() => void navigator.clipboard?.writeText(`${qr.printUrl}&m=nfc`)}
            style={{ minHeight: 30, padding: "0 8px", background: "transparent", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 6, fontSize: 11, fontWeight: 700, color: "var(--green)" }}
          >
            Copiar
          </button>
        </div>
        <code style={{ display: "block", fontSize: 10, lineHeight: 1.4, wordBreak: "break-all", color: "var(--muted)" }}>
          {qr.printUrl}&amp;m=nfc
        </code>
      </div>

      <div style={{ display: "flex", gap: 8, width: "100%" }}>
        <button
          type="button"
          className="press"
          onClick={() => void navigator.clipboard?.writeText(qr.printUrl)}
          style={{ ...buttonStyle("ghost"), minHeight: 38, fontSize: 12 }}
        >
          Copiar endereço
        </button>
        <button type="button" className="press" onClick={() => window.print()} style={{ ...buttonStyle("ghost"), minHeight: 38, fontSize: 12 }}>
          Imprimir
        </button>
      </div>

      <p style={{ margin: 0, fontSize: 11, lineHeight: 1.4, color: "var(--muted)", textAlign: "center" }}>
        Cole na quadra. A câmera do celular abre o app direto nesta quadra.
      </p>
    </div>
  );
}


// =====================================================================
// Pessoas
// =====================================================================

function People({ onNotice }: { onNotice: (text: string) => void }) {
  const [query, setQuery] = useState("");
  const [users, setUsers] = useState<AdminUser[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  async function load(search: string) {
    try {
      setUsers(await adminUsers(search));
    } catch (cause) {
      onNotice((cause as Error).message);
    }
  }

  useEffect(() => {
    const id = setTimeout(() => void load(query), 250);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query]);

  async function setRole(user: AdminUser, role: "player" | "staff") {
    setBusy(user.user_id);
    try {
      await adminSetRole(user.user_id, role);
      onNotice(
        role === "staff"
          ? `${user.full_name ?? user.username} agora pode moderar quadras.`
          : `${user.full_name ?? user.username} voltou a ser jogador.`,
      );
      await load(query);
    } catch (cause) {
      onNotice((cause as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12, margin: "0 16px" }}>
      <div style={{ position: "relative" }}>
        <span style={{ position: "absolute", left: 13, top: 13, color: "var(--green)", display: "flex" }}>
          <Search size={18} />
        </span>
        <input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Buscar por nome, @usuário ou e-mail"
          style={{ ...field, height: 46, paddingLeft: 40 }}
        />
      </div>

      {!users
        ? <Loading what="Carregando pessoas" />
        : users.length === 0
          ? <p style={{ margin: 0, fontSize: 13, color: "var(--muted)" }}>Ninguém encontrado.</p>
          : users.map((user) => (
            <div key={user.user_id} style={{ display: "flex", alignItems: "center", gap: 10, padding: 10, background: "var(--chalk)", border: "1px solid rgba(47,70,41,.18)", borderRadius: 10 }}>
              <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 38, height: 38, flexShrink: 0, background: "var(--green)", color: "var(--chalk)", borderRadius: 8, fontSize: 18 }}>
                {user.initials}
              </span>
              <span style={{ display: "flex", flexDirection: "column", gap: 1, flexGrow: 1, minWidth: 0 }}>
                <span style={{ fontSize: 14, fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {user.full_name ?? user.username}
                </span>
                <span style={{ fontSize: 11, color: "var(--muted)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {user.email}
                </span>
                <span style={{ fontSize: 11, fontWeight: 700, color: "var(--green)" }}>
                  {user.role === "admin" ? "Administrador" : user.role === "staff" ? "Moderador" : "Jogador"}
                  {user.state !== "free" ? ` · ${user.state === "playing" ? "em quadra" : "na fila"}` : ""}
                </span>
              </span>

              {user.role !== "admin" && (
                <button
                  type="button"
                  className="press"
                  disabled={busy === user.user_id}
                  onClick={() => void setRole(user, user.role === "staff" ? "player" : "staff")}
                  style={{ minHeight: 38, padding: "0 10px", flexShrink: 0, background: "transparent", border: "1.5px solid rgba(47,70,41,.35)", borderRadius: 8, fontSize: 12, fontWeight: 700, color: "var(--green)" }}
                >
                  {user.role === "staff" ? "Rebaixar" : "Moderador"}
                </button>
              )}
            </div>
          ))}

      <p style={{ margin: 0, fontSize: 11, lineHeight: 1.5, color: "var(--muted)" }}>
        <strong>Moderador</strong> pode encerrar partidas travadas, chamar o próximo e aprovar
        fotos. O <strong>administrador</strong> é um só — para trocar, é preciso mexer no banco.
      </p>
    </div>
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
