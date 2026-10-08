import { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { BoardTab, CourtsTab, ProfileTab, QrIcon } from "./icons";
import { lastCourt } from "../lib/nav";

export type NavTab = "home" | "court" | "profile";

/**
 * A barra inferior do protótipo: só aparece dentro de um parque, com o
 * botão de leitura saltando do meio. Os 84px de altura são compensados
 * pelo padding do Shell, para nada ficar escondido atrás dela.
 */
export function BottomNav({
  parkId,
  tab,
  courtId,
  onScan,
}: {
  parkId: string;
  tab: NavTab;
  courtId?: string;
  onScan?: () => void;
}) {
  const navigate = useNavigate();
  const board = courtId ?? lastCourt(parkId);

  // A barra é fixa; a folga no fim da página sai daqui, para a tela não
  // precisar saber se ela existe.
  useEffect(() => {
    document.body.classList.add("has-nav");
    return () => document.body.classList.remove("has-nav");
  }, []);

  return (
    <nav
      aria-label="Navegação principal"
      style={{
        position: "fixed",
        left: "50%",
        transform: "translateX(-50%)",
        bottom: 0,
        width: "100%",
        maxWidth: 480,
        height: "calc(84px + env(safe-area-inset-bottom, 0px))",
        paddingBottom: "calc(12px + env(safe-area-inset-bottom, 0px))",
        background: "var(--green)",
        display: "grid",
        gridTemplateColumns: "repeat(4, minmax(0, 1fr))",
        padding: "0 6px 12px",
        zIndex: 5,
      }}
    >
      <Tab
        label="Quadras"
        active={tab === "home"}
        onClick={() => navigate(`/parque/${parkId}`)}
        icon={<CourtsTab size={22} />}
      />
      <Tab
        label="Placar"
        active={tab === "court"}
        disabled={!board}
        onClick={() => board && navigate(`/quadra/${board}`)}
        icon={<BoardTab size={22} />}
      />

      <div style={{ display: "flex", justifyContent: "center" }}>
        <button
          type="button"
          className="press"
          onClick={onScan}
          disabled={!onScan}
          aria-label="Escanear QR ou NFC da quadra"
          style={{
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: 2,
            width: 72,
            height: 72,
            marginTop: -20,
            background: "var(--chalk)",
            color: "var(--green)",
            border: "3px solid var(--green)",
            borderRadius: 14,
            fontSize: 10,
            fontWeight: 800,
            letterSpacing: ".06em",
            boxShadow: "0 0 0 3px var(--chalk)",
            opacity: onScan ? 1 : 0.45,
          }}
        >
          <QrIcon size={26} />
          QR / NFC
        </button>
      </div>

      <Tab
        label="Perfil"
        active={tab === "profile"}
        onClick={() => navigate("/perfil")}
        icon={<ProfileTab size={22} />}
      />
    </nav>
  );
}

function Tab({
  label,
  icon,
  active,
  disabled,
  onClick,
}: {
  label: string;
  icon: React.ReactNode;
  active: boolean;
  disabled?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="press"
      onClick={onClick}
      disabled={disabled}
      aria-current={active ? "page" : undefined}
      style={{
        position: "relative",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 4,
        background: "transparent",
        border: 0,
        fontSize: 11,
        fontWeight: 700,
        letterSpacing: ".04em",
        color: active ? "var(--chalk)" : "var(--mauve)",
        opacity: disabled ? 0.5 : 1,
      }}
    >
      <span
        style={{
          position: "absolute",
          top: 0,
          left: "22%",
          right: "22%",
          height: 3,
          borderRadius: "0 0 3px 3px",
          background: active ? "var(--ocre)" : "transparent",
        }}
      />
      {icon}
      {label}
    </button>
  );
}
