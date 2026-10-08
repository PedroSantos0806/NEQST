import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { buttonStyle } from "../components/ui";

type Mode = "signin" | "signup" | "reset";

const inputStyle = {
  width: "100%",
  minHeight: 48,
  padding: "12px 14px",
  background: "var(--chalk)",
  border: "1.5px solid rgba(47,70,41,.3)",
  borderRadius: 10,
  fontSize: 15,
  color: "var(--ink)",
};

export function Login() {
  const [mode, setMode] = useState<Mode>("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ tone: "ok" | "error"; text: string } | null>(null);

  const redirectTo = `${window.location.origin}/auth/callback`;

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setMessage(null);

    try {
      if (mode === "reset") {
        const { error } = await supabase.auth.resetPasswordForEmail(email, {
          redirectTo: `${window.location.origin}/auth/callback?reset=1`,
        });
        if (error) throw error;
        setMessage({ tone: "ok", text: "Enviamos um link de redefinição para o seu e-mail." });
      } else if (mode === "signup") {
        const { error } = await supabase.auth.signUp({
          email,
          password,
          options: { data: { full_name: name.trim() }, emailRedirectTo: redirectTo },
        });
        if (error) throw error;
        setMessage({
          tone: "ok",
          text: "Conta criada. Se pedirmos confirmação, o link está no seu e-mail.",
        });
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
      }
    } catch (cause) {
      setMessage({ tone: "error", text: (cause as Error).message });
    } finally {
      setBusy(false);
    }
  }

  async function google() {
    setBusy(true);
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo },
    });
    if (error) {
      setMessage({ tone: "error", text: error.message });
      setBusy(false);
    }
  }

  return (
    <div className="screen" style={{ padding: "40px 20px 32px", display: "flex", flexDirection: "column", gap: 22 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span className="script" style={{ fontSize: 44, lineHeight: 1, color: "var(--green)" }}>Neqst</span>
        <span
          style={{
            width: 10,
            height: 10,
            borderRadius: "50%",
            background: "var(--ocre)",
            border: "1.5px solid var(--green)",
          }}
        />
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <h1 className="bb" style={{ margin: 0, fontSize: 46, lineHeight: 0.92 }}>
          {mode === "signup" ? "Criar conta" : mode === "reset" ? "Recuperar acesso" : "Entrar na fila"}
        </h1>
        <p style={{ margin: 0, fontSize: 14, lineHeight: 1.45, color: "var(--green)" }}>
          {mode === "reset"
            ? "Informe o e-mail da conta e enviamos um link para criar uma senha nova."
            : "Escaneie o QR da quadra, entre na fila e acompanhe a sua vez em tempo real."}
        </p>
      </div>

      <form onSubmit={submit} style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        {mode === "signup" && (
          <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <span style={{ fontSize: 13, fontWeight: 700, color: "var(--green)" }}>Nome</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoComplete="name"
              required
              minLength={2}
              style={inputStyle}
            />
          </label>
        )}

        <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <span style={{ fontSize: 13, fontWeight: 700, color: "var(--green)" }}>E-mail</span>
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            autoComplete="email"
            required
            style={inputStyle}
          />
        </label>

        {mode !== "reset" && (
          <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <span style={{ fontSize: 13, fontWeight: 700, color: "var(--green)" }}>Senha</span>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === "signup" ? "new-password" : "current-password"}
              required
              minLength={8}
              style={inputStyle}
            />
            {mode === "signup" && (
              <span style={{ fontSize: 12, color: "var(--muted)" }}>Pelo menos 8 caracteres.</span>
            )}
          </label>
        )}

        {message && (
          <p
            role={message.tone === "error" ? "alert" : "status"}
            style={{
              margin: 0,
              padding: "10px 12px",
              borderRadius: 8,
              fontSize: 13,
              lineHeight: 1.4,
              background: message.tone === "error" ? "rgba(177,63,22,.1)" : "rgba(116,182,157,.18)",
              color: message.tone === "error" ? "var(--rust)" : "var(--green)",
            }}
          >
            {message.text}
          </p>
        )}

        <button type="submit" className="press" disabled={busy} style={buttonStyle("primary", busy)}>
          {busy ? "Aguarde…" : mode === "signup" ? "Criar conta" : mode === "reset" ? "Enviar link" : "Entrar"}
        </button>
      </form>

      {mode !== "reset" && (
        <>
          <div style={{ display: "flex", alignItems: "center", gap: 10, color: "var(--muted)", fontSize: 12 }}>
            <span style={{ flex: 1, height: 1, background: "rgba(47,70,41,.2)" }} />
            ou
            <span style={{ flex: 1, height: 1, background: "rgba(47,70,41,.2)" }} />
          </div>

          <button type="button" className="press" onClick={google} disabled={busy} style={buttonStyle("ghost")}>
            <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
              <path fill="#4285F4" d="M21.6 12.2c0-.7-.1-1.4-.2-2H12v3.9h5.4a4.6 4.6 0 0 1-2 3v2.5h3.2c1.9-1.7 3-4.3 3-7.4z" />
              <path fill="#34A853" d="M12 22c2.7 0 5-.9 6.6-2.4l-3.2-2.5c-.9.6-2 1-3.4 1-2.6 0-4.8-1.8-5.6-4.1H3.1v2.6A10 10 0 0 0 12 22z" />
              <path fill="#FBBC05" d="M6.4 14c-.2-.6-.3-1.3-.3-2s.1-1.4.3-2V7.4H3.1a10 10 0 0 0 0 9.2L6.4 14z" />
              <path fill="#EA4335" d="M12 5.9c1.5 0 2.8.5 3.8 1.5l2.8-2.8A10 10 0 0 0 3.1 7.4L6.4 10c.8-2.3 3-4.1 5.6-4.1z" />
            </svg>
            Continuar com Google
          </button>
        </>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "flex-start" }}>
        {mode !== "signin" && (
          <button type="button" onClick={() => { setMode("signin"); setMessage(null); }} style={linkButton}>
            Já tenho conta
          </button>
        )}
        {mode !== "signup" && (
          <button type="button" onClick={() => { setMode("signup"); setMessage(null); }} style={linkButton}>
            Criar uma conta
          </button>
        )}
        {mode !== "reset" && (
          <button type="button" onClick={() => { setMode("reset"); setMessage(null); }} style={linkButton}>
            Esqueci minha senha
          </button>
        )}
      </div>
    </div>
  );
}

const linkButton = {
  minHeight: 44,
  padding: 0,
  background: "none",
  border: "none",
  color: "var(--green)",
  fontSize: 14,
  fontWeight: 600,
  textDecoration: "underline",
} as const;
