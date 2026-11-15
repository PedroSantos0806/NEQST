import type { PostgrestError } from '@supabase/supabase-js'
import { toast } from 'sonner'

const UNIQUE_MESSAGES: Record<string, string> = {
  contacts_email_key: 'Já existe um contato com este e-mail.',
  contacts_phone_key: 'Já existe um contato com este telefone.',
  contacts_meta_lead_id_key: 'Este lead do Meta já foi importado.',
  companies_cnpj_key: 'Já existe uma empresa com este CNPJ.',
}

export function friendlyError(error: unknown): string {
  const e = error as Partial<PostgrestError> | undefined
  if (e?.code === '23505') {
    const hit = Object.keys(UNIQUE_MESSAGES).find((k) => e.message?.includes(k) || e.details?.includes(k))
    return hit ? UNIQUE_MESSAGES[hit] : 'Registro duplicado.'
  }
  if (e?.code === '23503') return 'Este registro está ligado a outros dados e não pode ser alterado assim.'
  if (e?.code === '23514') return 'Algum valor não passou na validação do banco.'
  if (e?.code === '42501') return 'Sem permissão para esta ação.'
  return e?.message ?? 'Erro inesperado.'
}

export function toastError(title: string) {
  return (error: unknown) => toast.error(title, { description: friendlyError(error) })
}

/** Lança o erro do Supabase para o TanStack Query tratar. */
export function unwrap<T>({ data, error }: { data: T; error: PostgrestError | null }): T {
  if (error) throw error
  return data
}
