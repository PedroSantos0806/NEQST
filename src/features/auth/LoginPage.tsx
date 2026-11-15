import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import { useAuth } from './auth-context'

const schema = z.object({
  email: z.email('Informe um e-mail válido'),
})
type FormValues = z.infer<typeof schema>

const NOT_INVITED = 'Este e-mail não tem acesso. Peça um convite ao administrador.'

function isNotInvited(code?: string | null, message?: string | null) {
  return code === 'otp_disabled' || code === 'signup_disabled' || /signups? not allowed/i.test(message ?? '')
}

// Erro devolvido pelo Supabase na URL após o login com Google (ex.: e-mail não convidado).
function readRedirectError() {
  const params = new URLSearchParams(window.location.search)
  const hash = new URLSearchParams(window.location.hash.slice(1))
  const code = params.get('error_code') ?? hash.get('error_code')
  const description = params.get('error_description') ?? hash.get('error_description')
  if (!code && !description) return null
  window.history.replaceState(null, '', window.location.pathname)
  return isNotInvited(code, description) ? NOT_INVITED : (description ?? 'Falha no login')
}

export function LoginPage() {
  const { session } = useAuth()
  const [sentTo, setSentTo] = useState<string | null>(null)
  const [redirectError] = useState(readRedirectError)
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({ resolver: zodResolver(schema) })

  if (session) return <Navigate to="/" replace />

  const onMagicLink = async ({ email }: FormValues) => {
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      // Acesso só por convite: nunca cria conta a partir da tela de login.
      options: { emailRedirectTo: window.location.origin, shouldCreateUser: false },
    })
    if (error) {
      if (isNotInvited(error.code, error.message)) toast.error(NOT_INVITED)
      else toast.error('Não foi possível enviar o link', { description: error.message })
      return
    }
    setSentTo(email)
  }

  const onGoogle = async () => {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: window.location.origin },
    })
    if (error) toast.error('Falha no login com Google', { description: error.message })
  }

  return (
    <main className="grid min-h-svh place-items-center bg-background px-4">
      <div className="w-full max-w-sm">
        <p className="mb-6 text-center font-display text-6xl leading-none tracking-wider text-primary">
          NEQST
        </p>
        <Card>
          <CardHeader>
            <CardTitle className="font-display text-2xl tracking-wide">Entrar no CRM</CardTitle>
            <CardDescription>Acesso restrito ao time NEQST.</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-4">
            {redirectError && (
              <p role="alert" className="rounded-lg bg-destructive/10 p-3 text-sm text-destructive">
                {redirectError}
              </p>
            )}
            {sentTo ? (
              <p className="rounded-lg bg-muted p-3 text-sm">
                Enviamos um link de acesso para <strong>{sentTo}</strong>. Abra o e-mail e clique no link
                para entrar.
              </p>
            ) : (
              <form onSubmit={handleSubmit(onMagicLink)} className="flex flex-col gap-3" noValidate>
                <div className="flex flex-col gap-1.5">
                  <Label htmlFor="email">E-mail</Label>
                  <Input
                    id="email"
                    type="email"
                    autoComplete="email"
                    placeholder="voce@neqst.com.br"
                    aria-invalid={!!errors.email}
                    {...register('email')}
                  />
                  {errors.email && <p className="text-xs text-destructive">{errors.email.message}</p>}
                </div>
                <Button
                  type="submit"
                  disabled={isSubmitting}
                  className="h-10 bg-accent text-accent-foreground hover:bg-accent/85"
                >
                  {isSubmitting ? 'Enviando…' : 'Receber link de acesso'}
                </Button>
              </form>
            )}
            <div className="flex items-center gap-3 text-xs text-muted-foreground">
              <Separator className="flex-1" />
              ou
              <Separator className="flex-1" />
            </div>
            <Button type="button" variant="outline" className="h-10" onClick={onGoogle}>
              Entrar com Google
            </Button>
          </CardContent>
        </Card>
      </div>
    </main>
  )
}
