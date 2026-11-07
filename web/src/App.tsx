import { lazy, Suspense } from "react";
import { Navigate, Route, Routes, useLocation, useParams } from "react-router-dom";
import { Parks } from "./screens/Parks";
import { Park } from "./screens/Park";
import { Court } from "./screens/Court";
import { Profile } from "./screens/Profile";
import { Login } from "./screens/Login";
import { ScanLanding } from "./screens/ScanLanding";
import { AuthCallback } from "./screens/AuthCallback";
import { ErrorState, Loading } from "./components/ui";
import { useAuth } from "./hooks/useAuth";
import { useMe } from "./hooks/useMe";
import { rememberAfterLogin } from "./lib/after-login";
import type { ReactElement } from "react";

// A administração não interessa a quem só quer jogar: fica num pedaço
// separado do bundle, baixado apenas por quem abre /admin.
const Admin = lazy(() =>
  import("./screens/Admin").then((module) => ({ default: module.Admin })),
);

// A tela do totem não interessa a quem está com o celular na mão, e
// carrega o motor de som e o CSS próprio dela: fica fora do bundle de
// quem só quer entrar na fila.
// A fila no celular: tela pequena, sem conta, e a primeira que muita
// gente vai ver.
const Fila = lazy(() =>
  import("./screens/Fila").then((module) => ({ default: module.Fila })),
);

const Totem = lazy(() =>
  import("./screens/Totem").then((module) => ({ default: module.Totem })),
);

/** Parâmetros que pertencem ao fluxo de login, não à rota. */
const AUTH_PARAMS = ["code", "error", "error_code", "error_description", "state", "type"];

function Protected({ children }: { children: ReactElement }) {
  const { session, loading } = useAuth();
  const location = useLocation();

  if (loading) return <Loading what="Carregando" />;

  if (!session) {
    const params = new URLSearchParams(location.search);
    const cameFromEmailLink = AUTH_PARAMS.some((key) => params.has(key));
    AUTH_PARAMS.forEach((key) => params.delete(key));

    // Sem os parâmetros do link: voltar para cá com um `code` já gasto
    // só repetiria a falha.
    const query = params.toString();
    rememberAfterLogin(location.pathname + (query ? `?${query}` : ""));

    // Chegou com um código de e-mail e mesmo assim não há sessão: o
    // link não pôde ser trocado neste navegador. Vale explicar.
    return <Navigate to={cameFromEmailLink ? "/entrar?motivo=link" : "/entrar"} replace />;
  }

  return children;
}

/**
 * Só o administrador entra. A checagem de verdade é no banco (toda RPC
 * de admin verifica o papel); aqui é para não mostrar uma tela que a
 * pessoa não tem como usar.
 */
function AdminOnly() {
  const profile = useMe();

  if (!profile) return <Loading what="Verificando o seu acesso" />;

  if (profile.profile?.role !== "admin") {
    return (
      <ErrorState
        title="Esta área é do administrador"
        detail="Sua conta não tem acesso à administração do NEQST."
      />
    );
  }

  return (
    <Suspense fallback={<Loading what="Carregando a administração" />}>
      <Admin />
    </Suspense>
  );
}

/** QR antigo (/q/<quadra>?v&s) → o link da fila daquela quadra. */
function QrToFila() {
  const { courtId } = useParams<{ courtId: string }>();
  return <Navigate to={`/fila/${courtId}`} replace />;
}

export function App() {
  return (
    <Routes>
      <Route path="/entrar" element={<Login />} />
      <Route path="/auth/callback" element={<AuthCallback />} />
      {/*
        O QR da placa levava para cá e a tela tentava validar scan,
        assinatura e GPS antes de deixar entrar. Desde a Sprint 10 o QR
        só leva ao link da fila — então esta rota existe para que os QRs
        JÁ IMPRESSOS continuem valendo, redirecionando para lá. A
        assinatura (?v&s) deixa de ser conferida porque não gateia mais
        nada: entrar na fila é público.

        /q/h/:code é outra coisa e continua como era — é o convite de
        quem abriu a fila no modo anfitrião, que depende de conta.
      */}
      <Route path="/q/:courtId" element={<QrToFila />} />
      <Route path="/q/h/:code" element={<ScanLanding />} />

      {/*
        A fila da quadra pelo link: a MESMA tela do totem, sem os
        comandos de operação. É onde o QR da placa cai e é o que o
        tablet abre, cada um com a sua credencial.
      */}
      <Route
        path="/fila/:quadra"
        element={
          <Suspense fallback={<Loading what="Carregando a quadra" />}>
            <Totem />
          </Suspense>
        }
      />

      {/*
        O totem da quadra. Sem Protected de propósito: a credencial é o
        token do link, não uma conta — um aparelho que fica num parque
        público não pode carregar a sessão de ninguém.

        /tablet continua valendo porque é o caminho dos links já
        gerados, e o que identifica o aparelho é o token, não a rota.
      */}
      <Route
        path="/totem/:token"
        element={
          <Suspense fallback={<Loading what="Carregando a quadra" />}>
            <Totem />
          </Suspense>
        }
      />
      <Route
        path="/tablet/:token"
        element={
          <Suspense fallback={<Loading what="Carregando a quadra" />}>
            <Totem />
          </Suspense>
        }
      />

      {/*
        A fila de quem entrou pelo QR, no celular. Sem Protected: o que
        liga a pessoa à vaga é o segredo guardado no navegador dela, não
        uma conta.
      */}
      <Route path="/fila" element={<Fila />} />

      {/*
        Ler a fila não pede conta nenhuma.

        É a fase 1 do app no handoff: acompanhar a quadra de qualquer
        lugar. Quem ESCREVE na fila é o totem e o QR da quadra, então
        estas três telas abrem para quem passar — e, sem sessão, elas
        mesmas escondem as ações que exigiriam uma.
      */}
      <Route path="/" element={<Parks />} />
      <Route path="/parque/:parkId" element={<Park />} />
      <Route path="/quadra/:courtId" element={<Court />} />

      {/* Perfil e administração continuam sendo de quem tem conta. */}
      <Route path="/perfil" element={<Protected><Profile /></Protected>} />
      <Route path="/admin" element={<Protected><AdminOnly /></Protected>} />

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
