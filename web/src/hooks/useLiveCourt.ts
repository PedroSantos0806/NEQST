import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "../lib/supabase";
import { courtScreen } from "../lib/api";
import type { CourtScreen } from "../lib/types";

/**
 * Estado da quadra ao vivo.
 *
 * O Realtime avisa que algo mudou; quem recalcula posição e tempo é o
 * backend (court_screen). Assim a tela nunca monta a fila a partir de
 * um evento parcial — e, ao reconectar, um refetch basta para voltar ao
 * estado correto.
 */
export function useLiveCourt(courtId: string | undefined) {
  const [data, setData] = useState<CourtScreen | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [loading, setLoading] = useState(true);
  const pending = useRef<Promise<CourtScreen | null> | null>(null);

  /**
   * Devolve o estado recém-lido: quem acabou de entrar na fila precisa
   * dele na hora para mostrar a tela de sucesso com a posição certa.
   *
   * Chamadas simultâneas (Realtime + ação do usuário) compartilham a
   * mesma ida ao servidor em vez de uma delas voltar de mãos vazias.
   */
  const refresh = useCallback((): Promise<CourtScreen | null> => {
    if (!courtId) return Promise.resolve(null);
    if (pending.current) return pending.current;

    const run = courtScreen(courtId)
      .then((fresh) => {
        setData(fresh);
        setError(null);
        return fresh;
      })
      .catch((cause: Error) => {
        setError(cause);
        return null;
      })
      .finally(() => {
        pending.current = null;
        setLoading(false);
      });

    pending.current = run;
    return run;
  }, [courtId]);

  useEffect(() => {
    if (!courtId) return;
    void refresh();

    const channel = supabase
      .channel(`court:${courtId}`)
      .on("postgres_changes", {
        event: "*",
        schema: "public",
        table: "queue_entries",
        filter: `court_id=eq.${courtId}`,
      }, () => void refresh())
      .on("postgres_changes", {
        event: "*",
        schema: "public",
        table: "matches",
        filter: `court_id=eq.${courtId}`,
      }, () => void refresh())
      .on("postgres_changes", {
        event: "UPDATE",
        schema: "public",
        table: "courts",
        filter: `id=eq.${courtId}`,
      }, () => void refresh())
      .subscribe();

    // Rede de segurança: se o WebSocket cair sem avisar, o estado ainda
    // anda. A fila muda de minuto em minuto, não de segundo em segundo.
    const poll = setInterval(() => void refresh(), 25000);

    // Voltar para o app depois de minutos fora precisa de dado fresco.
    const onVisible = () => {
      if (document.visibilityState === "visible") void refresh();
    };
    document.addEventListener("visibilitychange", onVisible);

    return () => {
      void supabase.removeChannel(channel);
      clearInterval(poll);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [courtId, refresh]);

  return { data, error, loading, refresh };
}

/** Relógio de 1s para cronômetros e contagens regressivas. */
export function useTicker(active = true): number {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!active) return;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [active]);
  return tick;
}
