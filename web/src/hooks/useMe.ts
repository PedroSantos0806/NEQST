import { useEffect, useState } from "react";
import { me } from "../lib/me";
import type { ProfileSummary } from "../lib/types";

/** O perfil do jogador logado, sem uma ida ao servidor por tela. */
export function useMe(): ProfileSummary | null {
  const [data, setData] = useState<ProfileSummary | null>(null);

  useEffect(() => {
    let alive = true;
    me().then((value) => { if (alive) setData(value); }).catch(() => {});
    return () => { alive = false; };
  }, []);

  return data;
}
