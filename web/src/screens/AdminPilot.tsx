/**
 * Aba "Piloto" da administração: os números para apresentar à
 * organização do parque. Contagens, não nomes — o banco já devolve
 * assim (admin_pilot_stats).
 *
 * Gráficos em SVG à mão, sem biblioteca: são três formas simples, e o
 * bundle do admin já é separado. As duas cores passam no validador de
 * paleta (daltonismo, contraste contra o fundo --chalk):
 *   com app  #2a6fa3   sem app  #b3782f
 */
import { useEffect, useMemo, useState } from "react";
import { adminPilotStats } from "../lib/api";
import { ErrorState, Loading } from "../components/ui";
import type { AdminOverview, PilotStats } from "../lib/types";

const APP = "#2a6fa3";
const OFFLINE = "#b3782f";
const GRID = "rgba(47,70,41,.14)";

const PERIODS = [
  { days: 7, label: "7 dias" },
  { days: 30, label: "30 dias" },
  { days: 90, label: "90 dias" },
];

const ORIGIN_LABEL: Record<string, string> = {
  host_invite: "QR na tela de alguém da fila",
  host_open: "Abriu a fila (anfitrião)",
  qr: "QR da placa",
  nfc: "Totem NFC",
  unknown: "Sem registro",
};

const card = {
  display: "flex",
  flexDirection: "column" as const,
  gap: 10,
  padding: 14,
  background: "var(--chalk)",
  border: "1px solid rgba(47,70,41,.15)",
  borderRadius: 12,
};

function isoDay(date: Date): string {
  // O banco conta os dias de São Paulo; a data de hoje vem do navegador,
  // que no parque está no mesmo fuso.
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

const fmtDay = (day: string) => {
  const [, month, dd] = day.split("-");
  return `${dd}/${month}`;
};

// "QR mostrado" continua QR; o resto vira minúscula no meio da frase.
const lowerFirst = (text: string) =>
  /^[A-Z]{2}/.test(text) ? text : text.charAt(0).toLowerCase() + text.slice(1);

const fmtMin = (value: number | null) =>
  value === null ? "—" : `${String(value).replace(".", ",")} min`;

export function AdminPilot({ data }: { data: AdminOverview }) {
  const [parkId, setParkId] = useState<string>(() => {
    const withHost = data.parks.find((park) => park.courts.some((court) => court.queue_mode === "host"));
    return withHost?.id ?? "";
  });
  const [days, setDays] = useState(30);
  const [stats, setStats] = useState<PilotStats | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    let alive = true;
    setStats(null);
    setError(null);
    const to = new Date();
    const from = new Date(to.getTime() - (days - 1) * 86400000);
    adminPilotStats({ parkId: parkId || null, from: isoDay(from), to: isoDay(to) })
      .then((result) => { if (alive) setStats(result); })
      .catch((cause) => { if (alive) setError(cause as Error); });
    return () => { alive = false; };
  }, [parkId, days, retry]);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: "0 16px" }}>
      {/* Filtros numa linha só, acima de tudo */}
      <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
        <select
          value={parkId}
          onChange={(event) => setParkId(event.target.value)}
          aria-label="Parque"
          style={{ flex: "1 1 180px", minWidth: 0, height: 44, padding: "0 10px", background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 8, fontSize: 14, color: "var(--ink)" }}
        >
          <option value="">Todos os parques</option>
          {data.parks.map((park) => (
            <option key={park.id} value={park.id}>{park.name}</option>
          ))}
        </select>
        <div role="group" aria-label="Período" style={{ display: "flex", padding: 3, background: "rgba(47,70,41,.1)", borderRadius: 8 }}>
          {PERIODS.map((period) => (
            <button
              key={period.days}
              type="button"
              className="press"
              aria-pressed={days === period.days}
              onClick={() => setDays(period.days)}
              style={{ minHeight: 38, padding: "0 10px", border: 0, borderRadius: 6, fontSize: 12, fontWeight: 700, background: days === period.days ? "var(--chalk)" : "transparent", color: "var(--ink)" }}
            >
              {period.label}
            </button>
          ))}
        </div>
      </div>

      {error && <ErrorState title="Não conseguimos carregar os números" detail={error.message} onRetry={() => setRetry((n) => n + 1)} />}
      {!error && !stats && <Loading what="Somando o piloto" />}
      {stats && <Dashboard stats={stats} />}
    </div>
  );
}

function Dashboard({ stats }: { stats: PilotStats }) {
  const { totals, funnel, wait, calls, offline_hold: hold, spreaders } = stats;
  const realQueue = totals.app_entries + totals.offline_entries;
  const adoption = realQueue > 0 ? Math.round((totals.app_entries / realQueue) * 100) : null;
  const missedPct = calls.called > 0 ? Math.round((calls.missed / calls.called) * 100) : null;

  return (
    <>
      <p style={{ margin: 0, fontSize: 12, color: "var(--muted)" }}>
        {fmtDay(stats.period.from)} a {fmtDay(stats.period.to)} · dias de São Paulo
      </p>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: 10 }}>
        <Tile value={String(totals.people)} label="Pessoas na fila pelo app" />
        <Tile
          value={adoption === null ? "—" : `${adoption}%`}
          label="Adesão: vagas com app"
          detail={`${totals.app_entries} com app · ${totals.offline_entries} sem app`}
        />
        <Tile value={fmtMin(wait.median_min)} label="Espera mediana" detail={`p90 ${fmtMin(wait.p90_min)} · ${wait.samples} turnos`} />
        <Tile value={String(totals.hours_played).replace(".", ",")} label="Horas de quadra" detail={`${totals.turns} turnos com app · ${totals.sessions} filas abertas`} />
      </div>

      <DailyChart daily={stats.daily} />
      <Funnel funnel={funnel} />
      <HourChart byHour={stats.by_hour} />

      <div style={card}>
        <h3 style={{ margin: 0, fontSize: 15 }}>Como as pessoas entraram</h3>
        <BarList
          rows={Object.entries(stats.origins)
            .filter(([, n]) => (n ?? 0) > 0)
            .sort((a, b) => (b[1] ?? 0) - (a[1] ?? 0))
            .map(([key, n]) => ({ label: ORIGIN_LABEL[key] ?? key, value: n ?? 0 }))}
          empty="Ninguém entrou no período."
        />
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: 10 }}>
        <Tile
          value={missedPct === null ? "—" : `${missedPct}%`}
          label="Chamadas perdidas"
          detail={`${calls.missed} de ${calls.called} grupos chamados não vieram na tolerância`}
        />
        <Tile
          value={fmtMin(hold.avg_min)}
          label="Vaga sem app parada"
          detail={`média entre a chamada e o anfitrião marcar · máx. ${fmtMin(hold.max_min)}`}
        />
        <Tile
          value={String(spreaders.people)}
          label="Pessoas que trouxeram alguém"
          detail={spreaders.top.length ? `as que mais trouxeram: ${spreaders.top.join(", ")}` : "ninguém trouxe ainda"}
        />
        <Tile
          value={String(funnel.too_far)}
          label="QR recusado pela distância"
          detail="leituras longe da quadra — o print que não funcionou"
        />
      </div>

      <div style={card}>
        <h3 style={{ margin: 0, fontSize: 15 }}>Por quadra</h3>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: "left", color: "var(--muted)", fontSize: 11 }}>
              <th style={{ padding: "4px 0", fontWeight: 700 }}>Quadra</th>
              <th style={{ padding: 4, fontWeight: 700, textAlign: "right" }}>Pessoas</th>
              <th style={{ padding: 4, fontWeight: 700, textAlign: "right" }}>Com app</th>
              <th style={{ padding: "4px 0", fontWeight: 700, textAlign: "right" }}>Sem app</th>
            </tr>
          </thead>
          <tbody>
            {stats.courts.map((court) => (
              <tr key={court.court_id} style={{ borderTop: `1px solid ${GRID}` }}>
                <td style={{ padding: "6px 0" }}>{court.label}</td>
                <td style={{ padding: 6, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{court.people}</td>
                <td style={{ padding: 6, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{court.app_entries}</td>
                <td style={{ padding: "6px 0", textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{court.offline_entries}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

function Tile({ value, label, detail }: { value: string; label: string; detail?: string }) {
  return (
    <div style={{ ...card, gap: 4 }}>
      <span className="bb" style={{ fontSize: 36, lineHeight: 1, color: "var(--ink)" }}>{value}</span>
      <span style={{ fontSize: 12, fontWeight: 700, color: "var(--green)" }}>{label}</span>
      {detail && <span style={{ fontSize: 11, lineHeight: 1.35, color: "var(--muted)" }}>{detail}</span>}
    </div>
  );
}

/** Retângulo com só as pontas de cima arredondadas: o dado sai da linha de base. */
function topRounded(x: number, y: number, w: number, h: number, r = 4): string {
  const rr = Math.min(r, w / 2, h);
  return `M${x},${y + h}V${y + rr}Q${x},${y} ${x + rr},${y}H${x + w - rr}Q${x + w},${y} ${x + w},${y + rr}V${y + h}Z`;
}

function niceMax(value: number): number {
  if (value <= 4) return 4;
  const pow = 10 ** Math.floor(Math.log10(value));
  const step = [1, 2, 2.5, 5, 10].find((s) => s * pow * 4 >= value) ?? 10;
  return step * pow * 4;
}

function Legend({ items }: { items: Array<{ color: string; label: string }> }) {
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: 12, fontSize: 12, color: "var(--ink)" }}>
      {items.map((item) => (
        <span key={item.label} style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span aria-hidden="true" style={{ width: 10, height: 10, borderRadius: 2, background: item.color }} />
          {item.label}
        </span>
      ))}
    </div>
  );
}

/** Pessoas na fila por dia: com app × sem app, empilhado. */
function DailyChart({ daily }: { daily: PilotStats["daily"] }) {
  const [hover, setHover] = useState<number | null>(null);
  const [asTable, setAsTable] = useState(false);

  // A largura do SVG é a da tela do celular: o texto dos eixos sai no
  // tamanho em que foi escrito.
  const W = 340;
  const H = 170;
  const pad = { top: 10, right: 6, bottom: 22, left: 30 };
  const innerW = W - pad.left - pad.right;
  const innerH = H - pad.top - pad.bottom;
  const max = niceMax(Math.max(1, ...daily.map((d) => d.app_entries + d.offline_entries)));
  const band = innerW / Math.max(1, daily.length);
  const barW = Math.max(2, Math.min(22, band - 2));
  const y = (v: number) => (v / max) * innerH;
  const labelEvery = Math.ceil(daily.length / 7);
  const active = hover === null ? null : daily[hover];

  return (
    <div style={card}>
      <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", gap: 8 }}>
        <h3 style={{ margin: 0, fontSize: 15 }}>Vagas na fila por dia</h3>
        <button type="button" className="press" onClick={() => setAsTable((v) => !v)} style={{ minHeight: 32, padding: "0 8px", background: "transparent", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 6, fontSize: 11, fontWeight: 700, color: "var(--green)" }}>
          {asTable ? "Ver gráfico" : "Ver tabela"}
        </button>
      </div>
      <Legend items={[{ color: APP, label: "Com app" }, { color: OFFLINE, label: "Sem app (registrado pelo anfitrião)" }]} />

      {asTable
        ? (
          <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
            <thead>
              <tr style={{ textAlign: "left", color: "var(--muted)" }}>
                <th style={{ padding: "4px 0" }}>Dia</th>
                <th style={{ textAlign: "right" }}>Pessoas</th>
                <th style={{ textAlign: "right" }}>Com app</th>
                <th style={{ textAlign: "right" }}>Sem app</th>
              </tr>
            </thead>
            <tbody>
              {daily.map((d) => (
                <tr key={d.day} style={{ borderTop: `1px solid ${GRID}` }}>
                  <td style={{ padding: "4px 0" }}>{fmtDay(d.day)}</td>
                  <td style={{ textAlign: "right" }}>{d.people}</td>
                  <td style={{ textAlign: "right" }}>{d.app_entries}</td>
                  <td style={{ textAlign: "right" }}>{d.offline_entries}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )
        : (
          <div style={{ position: "relative" }}>
            <div aria-live="polite" style={{ minHeight: 18, fontSize: 12, color: "var(--ink)" }}>
              {active
                ? <><strong>{fmtDay(active.day)}</strong> · {active.app_entries} com app · {active.offline_entries} sem app · {active.people} pessoas</>
                : <span style={{ color: "var(--muted)" }}>Toque numa barra para ver o dia.</span>}
            </div>
            <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Vagas na fila por dia, com app e sem app" onMouseLeave={() => setHover(null)}>
              {[0, 0.5, 1].map((t) => (
                <g key={t}>
                  <line x1={pad.left} x2={W - pad.right} y1={pad.top + innerH - t * innerH} y2={pad.top + innerH - t * innerH} stroke={GRID} strokeWidth={1} />
                  <text x={pad.left - 6} y={pad.top + innerH - t * innerH + 4} textAnchor="end" fontSize={11} fill="var(--muted)">{Math.round(max * t)}</text>
                </g>
              ))}
              {daily.map((d, i) => {
                const x = pad.left + i * band + (band - barW) / 2;
                const base = pad.top + innerH;
                const hApp = y(d.app_entries);
                const hOff = y(d.offline_entries);
                const gap = hApp > 0 && hOff > 0 ? 2 : 0;
                const dim = hover !== null && hover !== i ? 0.45 : 1;
                return (
                  <g key={d.day} opacity={dim}>
                    {hApp > 0 && (
                      <path d={hOff > 0 ? `M${x},${base}V${base - hApp}H${x + barW}V${base}Z` : topRounded(x, base - hApp, barW, hApp)} fill={APP} />
                    )}
                    {hOff > 0 && <path d={topRounded(x, base - hApp - gap - hOff, barW, hOff)} fill={OFFLINE} />}
                    {i % labelEvery === 0 && (
                      <text x={x + barW / 2} y={H - 6} textAnchor="middle" fontSize={11} fill="var(--muted)">{fmtDay(d.day)}</text>
                    )}
                    {/* Alvo do toque: a coluna inteira, maior que a barra */}
                    <rect
                      x={pad.left + i * band}
                      y={pad.top}
                      width={band}
                      height={innerH}
                      fill="transparent"
                      tabIndex={0}
                      aria-label={`${fmtDay(d.day)}: ${d.app_entries} com app, ${d.offline_entries} sem app`}
                      onMouseEnter={() => setHover(i)}
                      onFocus={() => setHover(i)}
                      onClick={() => setHover(i)}
                    />
                  </g>
                );
              })}
            </svg>
          </div>
        )}
    </div>
  );
}

/** O caminho do convite: QR mostrado → aberto → validado na quadra → entrou. */
function Funnel({ funnel }: { funnel: PilotStats["funnel"] }) {
  // `of` aponta a etapa que serve de base para a porcentagem. "Conta
  // criada" é uma parte de "validado", não uma etapa depois dele.
  const steps = [
    { label: "QR mostrado", value: funnel.shown, hint: "vezes que alguém abriu o QR na tela", of: null, sub: false },
    { label: "Convite aberto", value: funnel.opened, hint: "celulares que leram o QR", of: 0, sub: false },
    { label: "Validado na quadra", value: funnel.scanned, hint: "pessoas que passaram pelo GPS", of: 1, sub: false },
    { label: "das quais criaram a conta agora", value: funnel.new_accounts, hint: "contas novas, criadas depois do QR", of: 2, sub: true },
    { label: "Entrou na fila", value: funnel.joined, hint: "pessoas que pegaram uma vaga", of: 2, sub: false },
  ];
  const top = Math.max(1, ...steps.map((s) => s.value));

  return (
    <div style={card}>
      <h3 style={{ margin: 0, fontSize: 15 }}>O caminho do convite</h3>
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {steps.map((step) => {
          const base = step.of === null ? null : steps[step.of].value;
          const rate = base ? Math.round((step.value / base) * 100) : null;
          return (
            <div key={step.label} title={step.hint} style={{ display: "flex", flexDirection: "column", gap: 4, paddingLeft: step.sub ? 14 : 0 }}>
              <span style={{ display: "flex", justifyContent: "space-between", gap: 8, fontSize: 12 }}>
                <span style={{ fontWeight: step.sub ? 500 : 700 }}>{step.label}</span>
                <span style={{ fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>
                  <strong>{step.value}</strong>
                  {rate !== null && step.of !== null && (
                    <span style={{ color: "var(--muted)" }}> · {rate}% de {lowerFirst(steps[step.of].label)}</span>
                  )}
                </span>
              </span>
              <span style={{ display: "block", height: 10, background: GRID, borderRadius: 4 }}>
                <span style={{ display: "block", width: `${(step.value / top) * 100}%`, minWidth: step.value > 0 ? 4 : 0, height: "100%", background: APP, borderRadius: 4 }} />
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** Turnos começados por hora do dia: o horário de pico. */
function HourChart({ byHour }: { byHour: PilotStats["by_hour"] }) {
  const [hover, setHover] = useState<number | null>(null);
  const hours = useMemo(() => byHour.filter((h) => h.hour >= 5 && h.hour <= 23), [byHour]);
  const W = 340;
  const H = 140;
  const pad = { top: 10, right: 6, bottom: 22, left: 30 };
  const innerW = W - pad.left - pad.right;
  const innerH = H - pad.top - pad.bottom;
  const max = niceMax(Math.max(1, ...hours.map((h) => h.turns)));
  const band = innerW / hours.length;
  const barW = Math.min(20, band - 2);
  const peak = hours.reduce((best, h) => (h.turns > best.turns ? h : best), hours[0]);
  const active = hover === null ? null : hours[hover];

  return (
    <div style={card}>
      <h3 style={{ margin: 0, fontSize: 15 }}>Turnos por horário</h3>
      <div aria-live="polite" style={{ minHeight: 18, fontSize: 12 }}>
        {active
          ? <><strong>{active.hour}h</strong> · {active.turns} turnos começaram</>
          : peak && peak.turns > 0
            ? <span style={{ color: "var(--muted)" }}>Pico às {peak.hour}h, com {peak.turns} turnos.</span>
            : <span style={{ color: "var(--muted)" }}>Nenhum turno no período.</span>}
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Turnos começados por hora do dia" onMouseLeave={() => setHover(null)}>
        {[0, 0.5, 1].map((t) => (
          <g key={t}>
            <line x1={pad.left} x2={W - pad.right} y1={pad.top + innerH - t * innerH} y2={pad.top + innerH - t * innerH} stroke={GRID} strokeWidth={1} />
            <text x={pad.left - 6} y={pad.top + innerH - t * innerH + 4} textAnchor="end" fontSize={11} fill="var(--muted)">{Math.round(max * t)}</text>
          </g>
        ))}
        {hours.map((h, i) => {
          const x = pad.left + i * band + (band - barW) / 2;
          const bh = (h.turns / max) * innerH;
          return (
            <g key={h.hour} opacity={hover !== null && hover !== i ? 0.45 : 1}>
              {bh > 0 && <path d={topRounded(x, pad.top + innerH - bh, barW, bh)} fill={APP} />}
              {h.hour % 3 === 0 && (
                <text x={x + barW / 2} y={H - 6} textAnchor="middle" fontSize={11} fill="var(--muted)">{h.hour}h</text>
              )}
              <rect
                x={pad.left + i * band}
                y={pad.top}
                width={band}
                height={innerH}
                fill="transparent"
                tabIndex={0}
                aria-label={`${h.hour}h: ${h.turns} turnos`}
                onMouseEnter={() => setHover(i)}
                onFocus={() => setHover(i)}
                onClick={() => setHover(i)}
              />
            </g>
          );
        })}
      </svg>
    </div>
  );
}

function BarList({ rows, empty }: { rows: Array<{ label: string; value: number }>; empty: string }) {
  if (rows.length === 0) return <p style={{ margin: 0, fontSize: 13, color: "var(--muted)" }}>{empty}</p>;
  const top = Math.max(...rows.map((r) => r.value));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      {rows.map((row) => (
        <div key={row.label} style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <span style={{ display: "flex", justifyContent: "space-between", gap: 8, fontSize: 12 }}>
            <span>{row.label}</span>
            <strong style={{ fontVariantNumeric: "tabular-nums" }}>{row.value}</strong>
          </span>
          <span style={{ display: "block", height: 8, background: GRID, borderRadius: 4 }}>
            <span style={{ display: "block", width: `${(row.value / top) * 100}%`, height: "100%", background: APP, borderRadius: 4 }} />
          </span>
        </div>
      ))}
    </div>
  );
}
