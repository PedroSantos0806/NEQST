import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  adminOverview,
  adminSetRole,
  adminUpsertCourt,
  adminUpsertPark,
  adminUsers,
  courtQr,
} from "../lib/api";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { Check, ChevronLeft, Close, Pin, Search, SurfaceIcon } from "../components/icons";
import { SURFACE_COLOR, surfaceTextColor } from "../lib/format";
import type { AdminCourt, AdminOverview, AdminPark, AdminUser, CourtQr } from "../lib/types";

const SURFACES = [
  { value: "clay", label: "Saibro" },
  { value: "hard", label: "Rápida" },
  { value: "grass", label: "Grama" },
];

type Tab = "quadras" | "pessoas";

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

        <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", padding: 4, background: "rgba(241,236,239,.1)", borderRadius: 10 }}>
          {(["quadras", "pessoas"] as const).map((option) => (
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

      {tab === "quadras"
        ? <Courts data={data} onChanged={load} onNotice={setNotice} />
        : <People onNotice={setNotice} />}
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
        onClick={() => setOpen((value) => !value)}
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
          {editing
            ? (
              <ParkForm
                park={park}
                onCancel={() => setEditing(false)}
                onSaved={async () => {
                  setEditing(false);
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
            <CourtRow key={court.id} court={court} onChanged={onChanged} onNotice={onNotice} />
          ))}

          {addingCourt
            ? (
              <CourtForm
                parkId={park.id}
                nextNumber={Math.max(0, ...park.courts.map((c) => c.court_number)) + 1}
                onCancel={() => setAddingCourt(false)}
                onSaved={async () => {
                  setAddingCourt(false);
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
  onChanged,
  onNotice,
}: {
  court: AdminCourt;
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
        Slot de {court.slot_minutes} min · {court.queue_length} na fila
        {court.has_nfc_tag ? " · NFC" : ""}
      </span>

      {editing
        ? (
          <CourtForm
            court={court}
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
// Formulários
// =====================================================================

const field = {
  width: "100%",
  height: 44,
  padding: "0 12px",
  background: "var(--chalk)",
  border: "1.5px solid rgba(47,70,41,.3)",
  borderRadius: 8,
  fontSize: 14,
  color: "var(--ink)",
};

function Field({
  label,
  children,
  hint,
}: {
  label: string;
  children: React.ReactNode;
  hint?: string;
}) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 5, fontSize: 12, fontWeight: 700 }}>
      {label}
      {children}
      {hint && <span style={{ fontWeight: 500, color: "var(--muted)" }}>{hint}</span>}
    </label>
  );
}

function ParkForm({
  park,
  onCancel,
  onSaved,
}: {
  park?: AdminPark;
  onCancel: () => void;
  onSaved: () => Promise<void>;
}) {
  const [name, setName] = useState(park?.name ?? "");
  const [district, setDistrict] = useState(park?.district ?? "");
  const [city, setCity] = useState(park?.city ?? "");
  const [latitude, setLatitude] = useState(park ? String(park.latitude) : "");
  const [longitude, setLongitude] = useState(park ? String(park.longitude) : "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function useMyLocation() {
    const { getPosition } = await import("../lib/geo");
    try {
      const position = await getPosition();
      setLatitude(position.latitude.toFixed(6));
      setLongitude(position.longitude.toFixed(6));
    } catch (cause) {
      setError((cause as Error).message);
    }
  }

  async function save() {
    setBusy(true);
    setError(null);
    try {
      await adminUpsertPark({
        id: park?.id,
        name,
        district,
        city,
        latitude: latitude ? Number(latitude) : undefined,
        longitude: longitude ? Number(longitude) : undefined,
      });
      await onSaved();
    } catch (cause) {
      setError((cause as Error).message);
      setBusy(false);
    }
  }

  return (
    <div className="fade" style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--bg)", border: "1.5px solid var(--green)", borderRadius: 10 }}>
      <span className="bb" style={{ fontSize: 20, lineHeight: 1, color: "var(--green)" }}>
        {park ? "Editar parque" : "Novo parque"}
      </span>

      <Field label="Nome">
        <input value={name} onChange={(e) => setName(e.target.value)} style={field} />
      </Field>
      <Field label="Bairro / região" hint="Aparece sob o nome na lista.">
        <input value={district} onChange={(e) => setDistrict(e.target.value)} style={field} />
      </Field>
      <Field label="Cidade">
        <input value={city} onChange={(e) => setCity(e.target.value)} style={field} />
      </Field>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
        <Field label="Latitude">
          <input value={latitude} onChange={(e) => setLatitude(e.target.value)} inputMode="decimal" style={field} />
        </Field>
        <Field label="Longitude">
          <input value={longitude} onChange={(e) => setLongitude(e.target.value)} inputMode="decimal" style={field} />
        </Field>
      </div>

      <button type="button" className="press" onClick={() => void useMyLocation()} style={{ ...buttonStyle("ghost"), minHeight: 40, fontSize: 13 }}>
        Usar a minha localização agora
      </button>
      <p style={{ margin: 0, fontSize: 11, lineHeight: 1.4, color: "var(--muted)" }}>
        A posição é o que confirma que o jogador está na quadra ao escanear o QR. Estando no
        parque, o botão acima resolve.
      </p>

      {error && <p role="alert" style={{ margin: 0, fontSize: 12, color: "var(--rust)" }}>{error}</p>}

      <div style={{ display: "flex", gap: 8 }}>
        <button type="button" className="press" onClick={onCancel} style={{ ...buttonStyle("ghost"), minHeight: 42, fontSize: 13 }}>
          Cancelar
        </button>
        <button type="button" className="press" disabled={busy} onClick={() => void save()} style={{ ...buttonStyle("primary", busy), minHeight: 42, fontSize: 13 }}>
          {busy ? "Salvando…" : "Salvar"}
        </button>
      </div>
    </div>
  );
}

function CourtForm({
  court,
  parkId,
  nextNumber,
  onCancel,
  onSaved,
}: {
  court?: AdminCourt;
  parkId?: string;
  nextNumber?: number;
  onCancel: () => void;
  onSaved: () => Promise<void>;
}) {
  const [name, setName] = useState(court?.name ?? "");
  const [surface, setSurface] = useState(court?.surface ?? "clay");
  const [slot, setSlot] = useState(String(court?.slot_minutes ?? 40));
  const [nfc, setNfc] = useState(court?.has_nfc_tag ?? false);
  const [active, setActive] = useState(court?.is_active ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setError(null);
    try {
      await adminUpsertCourt({
        id: court?.id,
        parkId,
        name: name || undefined,
        surface,
        slotMinutes: Number(slot) || 40,
        hasNfcTag: nfc,
        isActive: active,
      });
      await onSaved();
    } catch (cause) {
      setError((cause as Error).message);
      setBusy(false);
    }
  }

  return (
    <div className="fade" style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--bg)", border: "1.5px solid var(--green)", borderRadius: 10 }}>
      <span className="bb" style={{ fontSize: 20, lineHeight: 1, color: "var(--green)" }}>
        {court ? "Editar quadra" : `Nova quadra${nextNumber ? ` · nº ${nextNumber}` : ""}`}
      </span>

      <Field label="Nome" hint={court ? undefined : "Em branco, vira “Quadra 0N”."}>
        <input value={name} onChange={(e) => setName(e.target.value)} style={field} />
      </Field>

      <Field label="Piso">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 6 }}>
          {SURFACES.map((option) => (
            <button
              key={option.value}
              type="button"
              className="press"
              onClick={() => setSurface(option.value as AdminCourt["surface"])}
              aria-pressed={surface === option.value}
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                gap: 5,
                minHeight: 44,
                borderRadius: 8,
                fontSize: 12,
                fontWeight: 700,
                background: surface === option.value ? SURFACE_COLOR[option.value] : "var(--chalk)",
                color: surface === option.value ? surfaceTextColor(option.value) : "var(--ink)",
                border: surface === option.value ? "2px solid var(--ink)" : "1.5px solid rgba(47,70,41,.25)",
              }}
            >
              <SurfaceIcon surface={option.value} size={12} />
              {option.label}
            </button>
          ))}
        </div>
      </Field>

      <Field label="Slot de jogo (minutos)" hint="É o relógio que dispara a próxima da fila.">
        <input value={slot} onChange={(e) => setSlot(e.target.value)} inputMode="numeric" style={field} />
      </Field>

      <Toggle label="Tem tag NFC" checked={nfc} onChange={setNfc} />
      {court && <Toggle label="Quadra ativa" checked={active} onChange={setActive} />}

      {error && <p role="alert" style={{ margin: 0, fontSize: 12, color: "var(--rust)" }}>{error}</p>}

      <div style={{ display: "flex", gap: 8 }}>
        <button type="button" className="press" onClick={onCancel} style={{ ...buttonStyle("ghost"), minHeight: 42, fontSize: 13 }}>
          Cancelar
        </button>
        <button type="button" className="press" disabled={busy} onClick={() => void save()} style={{ ...buttonStyle("primary", busy), minHeight: 42, fontSize: 13 }}>
          {busy ? "Salvando…" : "Salvar"}
        </button>
      </div>
    </div>
  );
}

function Toggle({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <button
      type="button"
      className="press"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        minHeight: 44,
        padding: "0 12px",
        background: "var(--chalk)",
        border: "1.5px solid rgba(47,70,41,.25)",
        borderRadius: 8,
        fontSize: 13,
        fontWeight: 600,
        color: "var(--ink)",
      }}
    >
      {label}
      <span style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 28, height: 28, borderRadius: 6, background: checked ? "var(--green)" : "transparent", border: checked ? "none" : "1.5px solid rgba(47,70,41,.35)", color: "var(--chalk)" }}>
        {checked && <Check size={16} />}
      </span>
    </button>
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
