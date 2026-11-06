/**
 * O segredo da party, guardado no navegador de quem entrou na fila.
 *
 * Sem conta, é isto que liga uma pessoa à vaga dela: o banco devolve o
 * token UMA vez, na entrada, e guarda só o hash. Quem tem o token pode
 * ver a posição, sair da fila e responder a pergunta de saída — e mais
 * nada. Perdeu o navegador, perdeu o controle da vaga, que então só sai
 * pelo totem da quadra ou pelo admin.
 *
 * localStorage e não cookie: nada disso vai para o servidor em toda
 * requisição, e um cookie de sessão morreria no fim do dia — a fila
 * pode atravessar o dia.
 */

const KEY = "neqst.party";

export interface SavedParty {
  token: string;
  courtId: string;
  name: string;
  size: number;
  joinedAt: string;
}

export function savedParty(): SavedParty | null {
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<SavedParty>;
    if (!parsed?.token || !parsed?.courtId) return null;
    return {
      token: parsed.token,
      courtId: parsed.courtId,
      name: parsed.name ?? "",
      size: parsed.size ?? 2,
      joinedAt: parsed.joinedAt ?? new Date().toISOString(),
    };
  } catch {
    // Navegador em modo privado, ou armazenamento bloqueado: a tela
    // segue funcionando, só não lembra da vaga.
    return null;
  }
}

export function rememberParty(party: Omit<SavedParty, "joinedAt">): void {
  try {
    window.localStorage.setItem(
      KEY,
      JSON.stringify({ ...party, joinedAt: new Date().toISOString() }),
    );
  } catch {
    // Sem memória: a pessoa ainda está na fila, só não acompanha daqui.
  }
}

export function forgetParty(): void {
  try {
    window.localStorage.removeItem(KEY);
  } catch {
    // Nada a fazer.
  }
}
