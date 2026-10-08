/**
 * O Supabase responde em inglês e com termos de quem escreveu o
 * servidor. Quem está na beira da quadra precisa saber o que fazer.
 */
const MESSAGES: Array<[RegExp, string]> = [
  [/email not confirmed/i, "Confirme o seu cadastro no e-mail antes de entrar."],
  [/invalid login credentials/i, "E-mail ou senha não conferem."],
  [/user already registered|already been registered/i, "Já existe uma conta com esse e-mail. Faça login."],
  [/password should be at least/i, "A senha precisa de pelo menos 8 caracteres."],
  [/unable to validate email|invalid email/i, "Esse e-mail não parece válido."],
  [/email rate limit exceeded|over_email_send_rate_limit/i,
   "Muitos e-mails enviados em sequência. Espere alguns minutos e tente de novo."],
  [/for security purposes|request this after/i,
   "Aguarde alguns segundos antes de tentar de novo."],
  [/token has expired|otp_expired|expired/i,
   "Esse link expirou. Peça um novo na tela de login."],
  [/code verifier|both auth code and code verifier/i,
   "O link precisa ser aberto no mesmo navegador em que a conta foi criada. Se você já confirmou o cadastro, é só entrar com e-mail e senha."],
  [/failed to fetch|network/i, "Sem conexão com o servidor. Verifique a internet e tente de novo."],
];

/**
 * Nenhuma chamada de auth pode ficar pendurada para sempre.
 *
 * O `signUp` dispara o e-mail de confirmação, e quando o provedor de
 * e-mail do Supabase engasga a resposta demora — ou não vem. Sem um
 * limite, o botão fica em "Aguarde…" indefinidamente e a pessoa não
 * tem como saber se funcionou.
 */
export async function withTimeout<T>(
  work: Promise<T>,
  seconds = 20,
  what = "O servidor não respondeu a tempo. Tente de novo em um minuto.",
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;

  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new TimeoutError(what)), seconds * 1000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export class TimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TimeoutError";
  }
}

export function authMessage(error: { message?: string } | string | null | undefined): string {
  const raw = typeof error === "string" ? error : error?.message ?? "";
  for (const [pattern, text] of MESSAGES) {
    if (pattern.test(raw)) return text;
  }
  return raw || "Não foi possível concluir. Tente de novo.";
}

/**
 * Erros que o Supabase devolve na própria URL (link expirado, link já
 * usado). Chegam em `?error_description=` ou no fragmento `#`.
 */
export function urlAuthError(url: string = window.location.href): string | null {
  const parsed = new URL(url);
  const hash = new URLSearchParams(parsed.hash.replace(/^#/, ""));
  const raw = parsed.searchParams.get("error_description")
    ?? parsed.searchParams.get("error")
    ?? hash.get("error_description")
    ?? hash.get("error");
  return raw ? authMessage(raw.replace(/\+/g, " ")) : null;
}

/** Tira da URL o que é do fluxo de auth, para não sobrar na barra. */
export function stripAuthParams(): void {
  const url = new URL(window.location.href);
  let touched = false;
  for (const key of ["code", "error", "error_code", "error_description", "state", "type"]) {
    if (url.searchParams.has(key)) {
      url.searchParams.delete(key);
      touched = true;
    }
  }
  if (url.hash.includes("access_token") || url.hash.includes("error")) {
    url.hash = "";
    touched = true;
  }
  if (touched) window.history.replaceState({}, "", url.pathname + url.search);
}
