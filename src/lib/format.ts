import type { Enums } from '@/types/database'

// ---------------------------------------------------------------------------
// Rótulos pt-BR dos enums do banco
// ---------------------------------------------------------------------------
export const COMPANY_TYPE_LABEL: Record<Enums<'company_type'>, string> = {
  public_operator: 'Operador público',
  club: 'Clube',
  condo: 'Condomínio',
  builder: 'Construtora',
  brand: 'Marca / anunciante',
}

export const LOCATION_STATUS_LABEL: Record<Enums<'location_status'>, string> = {
  prospect: 'Prospect',
  pilot: 'Piloto',
  client: 'Cliente',
}

export const LIFECYCLE_LABEL: Record<Enums<'lifecycle_stage'>, string> = {
  lead: 'Lead',
  qualified_lead: 'Lead qualificado',
  opportunity: 'Oportunidade',
  customer: 'Cliente',
}

export function options<T extends string>(labels: Record<T, string>) {
  return (Object.keys(labels) as T[]).map((value) => ({ value, label: labels[value] }))
}

// ---------------------------------------------------------------------------
// Telefone (E.164) — padrão Brasil quando vier sem DDI
// ---------------------------------------------------------------------------
export function normalizePhone(input: string | null | undefined): string | null {
  const raw = (input ?? '').trim()
  if (!raw) return null
  const digits = raw.replace(/\D/g, '')
  if (!digits) return null
  if (raw.startsWith('+')) return `+${digits}`
  if (digits.length === 10 || digits.length === 11) return `+55${digits}` // DDD + número
  if ((digits.length === 12 || digits.length === 13) && digits.startsWith('55')) return `+${digits}`
  return `+${digits}`
}

export const E164 = /^\+[1-9]\d{7,14}$/

export function formatPhone(e164: string | null | undefined) {
  if (!e164) return ''
  const m = /^\+55(\d{2})(\d{4,5})(\d{4})$/.exec(e164)
  return m ? `(${m[1]}) ${m[2]}-${m[3]}` : e164
}

// ---------------------------------------------------------------------------
// CNPJ
// ---------------------------------------------------------------------------
export function onlyDigits(value: string | null | undefined) {
  return (value ?? '').replace(/\D/g, '')
}

export function isValidCnpj(value: string) {
  const c = onlyDigits(value)
  if (c.length !== 14 || /^(\d)\1+$/.test(c)) return false
  const calc = (len: number) => {
    const weights = len === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    const sum = weights.reduce((acc, w, i) => acc + Number(c[i]) * w, 0)
    const rest = sum % 11
    return rest < 2 ? 0 : 11 - rest
  }
  return calc(12) === Number(c[12]) && calc(13) === Number(c[13])
}

export function formatCnpj(value: string | null | undefined) {
  const c = onlyDigits(value)
  if (c.length !== 14) return value ?? ''
  return `${c.slice(0, 2)}.${c.slice(2, 5)}.${c.slice(5, 8)}/${c.slice(8, 12)}-${c.slice(12)}`
}

// ---------------------------------------------------------------------------
// Dinheiro / misc
// ---------------------------------------------------------------------------
const brl = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })
export const formatBRL = (value: number | null | undefined) => (value == null ? '—' : brl.format(value))

export function emptyToNull(value: string | null | undefined) {
  const v = (value ?? '').trim()
  return v === '' ? null : v
}

export function profileLabel(p: { full_name: string | null; email: string | null } | null | undefined) {
  return p?.full_name || p?.email || '—'
}
