import { useState } from "react";
import { adminUpsertCourt, adminUpsertPark } from "../lib/api";
import { buttonStyle, fieldStyle } from "../components/ui";
import { Check, SurfaceIcon } from "../components/icons";
import { MapPicker, type MapPosition } from "../components/MapPicker";
import { SURFACE_COLOR, surfaceTextColor } from "../lib/format";
import { LIMITS, rangeHint, readNumber } from "../lib/limits";
import type { AdminCourt, AdminPark } from "../lib/types";

/**
 * Os dois formulários da administração — parque e quadra — com os
 * controles que só eles usam.
 *
 * Moravam dentro de `Admin.tsx`, que passou de 900 linhas e doze
 * componentes num arquivo só. Aqui está o que se edita quando um campo
 * do cadastro muda; lá ficou a navegação, a listagem e o QR.
 */

const SURFACES = [
  { value: "clay", label: "Saibro" },
  { value: "hard", label: "Rápida" },
  { value: "grass", label: "Grama" },
];

export const field = fieldStyle();

export function Field({
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

/**
 * Mesmo rótulo do `Field`, mas sem o `<label>` em volta: serve para
 * blocos que já têm botões e campos próprios dentro — um `<label>`
 * envolvendo controles rouba o clique do primeiro deles.
 */
function Group({
  label,
  children,
  hint,
}: {
  label: string;
  children: React.ReactNode;
  hint?: string;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 5 }}>
      <span style={{ fontSize: 12, fontWeight: 700 }}>{label}</span>
      {children}
      {hint && <span style={{ fontSize: 12, color: "var(--muted)" }}>{hint}</span>}
    </div>
  );
}

export function ParkForm({
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
  const [address, setAddress] = useState(park?.address ?? "");
  const [position, setPosition] = useState<MapPosition | null>(
    park ? { latitude: park.latitude, longitude: park.longitude } : null,
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    // O nome é conferido aqui pelo mesmo motivo que a posição: ir ao
    // servidor para descobrir que um campo está vazio é uma viagem
    // desnecessária, e a tela já sabe a resposta.
    if (name.trim() === "") {
      setError("Informe o nome do parque.");
      return;
    }
    if (!position) {
      setError("Marque no mapa onde fica o parque — arraste o alfinete ou use a sua localização.");
      return;
    }

    setBusy(true);
    setError(null);
    try {
      await adminUpsertPark({
        id: park?.id,
        name,
        district,
        city,
        address: address.trim(),
        latitude: position.latitude,
        longitude: position.longitude,
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

      <Field label="Endereço" hint="Rua e número da entrada do parque. É a referência de quem vai chegar.">
        <input
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          placeholder="Av. Exemplo, 1000 — Bairro"
          autoComplete="off"
          maxLength={200}
          style={field}
        />
      </Field>

      <Group label="Posição no mapa">
        <MapPicker
          latitude={position?.latitude ?? null}
          longitude={position?.longitude ?? null}
          onChange={setPosition}
          subject="parque"
          query={[address, district, city].filter(Boolean).join(", ")}
        />
      </Group>

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

export function CourtForm({
  court,
  park,
  nextNumber,
  onCancel,
  onSaved,
}: {
  court?: AdminCourt;
  park: AdminPark;
  nextNumber?: number;
  onCancel: () => void;
  onSaved: () => Promise<void>;
}) {
  const [name, setName] = useState(court?.name ?? "");
  const [surface, setSurface] = useState(court?.surface ?? "clay");
  const [slot, setSlot] = useState(String(court?.slot_minutes ?? 40));
  const [tolerance, setTolerance] = useState(String((court?.call_window_seconds ?? 120) / 60));
  const [nfc, setNfc] = useState(court?.has_nfc_tag ?? false);
  const [active, setActive] = useState(court?.is_active ?? true);
  const [radius, setRadius] = useState(String(court?.max_distance_meters ?? 1000));
  const [checkDistance, setCheckDistance] = useState(court?.enforce_proximity ?? true);
  const [address, setAddress] = useState(court?.address ?? park.address ?? "");
  const [position, setPosition] = useState<MapPosition | null>(
    court ? { latitude: court.latitude, longitude: court.longitude } : null,
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    if (!position) {
      setError("Marque no mapa onde fica a quadra — arraste o alfinete, use a sua localização "
        + "ou toque em “Usar a posição do parque”.");
      return;
    }

    /*
     * Os números são conferidos aqui, contra as mesmas faixas que o
     * banco impõe. Antes isto era `Number(campo) || padrão`: "abc"
     * virava 40 e "0" virava 1000, sem dizer nada a ninguém; e um 10
     * no slot ia até o banco só para voltar como erro em inglês.
     */
    const parsedSlot = readNumber(slot, LIMITS.slotMinutes);
    if (!parsedSlot.ok) { setError(parsedSlot.message); return; }

    const parsedTolerance = readNumber(tolerance, LIMITS.callWindowMinutes);
    if (!parsedTolerance.ok) { setError(parsedTolerance.message); return; }

    let parsedRadius = { ok: true, value: 1000 } as const as { ok: true; value: number };
    if (checkDistance) {
      const read = readNumber(radius, LIMITS.maxDistanceMeters);
      if (!read.ok) { setError(read.message); return; }
      parsedRadius = read;
    }

    setBusy(true);
    setError(null);
    try {
      await adminUpsertCourt({
        id: court?.id,
        parkId: court ? undefined : park.id,
        name: name || undefined,
        surface,
        address: address.trim(),
        latitude: position.latitude,
        longitude: position.longitude,
        slotMinutes: parsedSlot.value,
        callWindowSeconds: Math.round(parsedTolerance.value * 60),
        hasNfcTag: nfc,
        isActive: active,
        maxDistanceMeters: parsedRadius.value,
        enforceProximity: checkDistance,
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

      <Field
        label="Slot de jogo (minutos)"
        hint={`É o relógio que dispara a próxima da fila. ${rangeHint(LIMITS.slotMinutes)}`}
      >
        <input value={slot} onChange={(e) => setSlot(e.target.value)} inputMode="numeric" style={field} />
      </Field>

      <Field
        label="Tolerância do check-in (minutos)"
        hint={"Depois de chamado, o grupo tem esse tempo para escanear a quadra. Passou, a vez é "
          + `do próximo. Padrão: 2. ${rangeHint(LIMITS.callWindowMinutes)}`}
      >
        <input value={tolerance} onChange={(e) => setTolerance(e.target.value)} inputMode="decimal" style={field} />
      </Field>

      <Field label="Endereço de referência" hint="Onde se chega de carro. Em parque grande não é onde fica a quadra — para isso é o mapa abaixo.">
        <input
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          placeholder="Av. Exemplo, 1000 — Bairro"
          autoComplete="off"
          maxLength={200}
          style={field}
        />
      </Field>

      <Group
        label="Onde exatamente fica a quadra"
        hint="O ponto vermelho é a entrada do parque; o círculo é o raio do check-in."
      >
        <MapPicker
          latitude={position?.latitude ?? null}
          longitude={position?.longitude ?? null}
          onChange={setPosition}
          radiusMeters={checkDistance ? Number(radius) || null : null}
          reference={{ latitude: park.latitude, longitude: park.longitude, label: park.name }}
          query={[address, park.district, park.city].filter(Boolean).join(", ")}
        />
      </Group>

      <Toggle label="Exigir estar perto da quadra" checked={checkDistance} onChange={setCheckDistance} />

      {checkDistance
        ? (
          <Field
            label="Raio de proximidade (metros)"
            hint={"Distância máxima da quadra para a leitura do QR valer. O padrão é 1000. "
              + rangeHint(LIMITS.maxDistanceMeters)}
          >
            <input value={radius} onChange={(e) => setRadius(e.target.value)} inputMode="numeric" style={field} />
          </Field>
        )
        : (
          <p style={{ margin: 0, padding: "10px 12px", background: "rgba(177,63,22,.1)", border: "1.5px solid var(--rust)", borderRadius: 8, fontSize: 12, lineHeight: 1.45, color: "var(--rust)" }}>
            <strong>Esta quadra aceita leitura de qualquer lugar.</strong> Serve para o time
            testar sem sair da mesa. Ligue de volta antes de abrir a quadra ao público — é esta
            verificação que impede alguém de entrar na fila de casa.
          </p>
        )}

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

export function Toggle({
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
