import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { COMPANY_TYPE_LABEL, E164, emptyToNull, normalizePhone, options } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import type { Enums, TablesInsert } from '@/types/database'
import { useAddProspect, useImportProspects } from './api'

type CompanyType = Enums<'company_type'>

const toUrl = (v: string) => {
  const s = v.trim()
  if (!s) return null
  return /^https?:\/\//i.test(s) ? s : `https://${s}`
}

// ---------------------------------------------------------------------------
// Lead manual
// ---------------------------------------------------------------------------
const schema = z.object({
  name: z.string().trim().min(2, 'Informe o nome'),
  company_type: z.string(),
  city: z.string().trim().min(2, 'Informe a cidade'),
  state: z
    .string()
    .trim()
    .refine((v) => v === '' || /^[A-Za-z]{2}$/.test(v), 'Sigla (ex.: SP)'),
  address: z.string(),
  website: z.string(),
  instagram: z.string(),
  phone: z
    .string()
    .trim()
    .refine((v) => v === '' || E164.test(normalizePhone(v) ?? ''), 'Telefone inválido'),
})
type FormValues = z.infer<typeof schema>

export function AddProspectDialog({ open, onOpenChange, onAdded }: { open: boolean; onOpenChange: (o: boolean) => void; onAdded: (id: string) => void }) {
  const add = useAddProspect()
  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { name: '', company_type: 'club', city: '', state: '', address: '', website: '', instagram: '', phone: '' },
  })

  const onSubmit = (v: FormValues) =>
    add
      .mutateAsync({
        name: v.name,
        company_type: (v.company_type || null) as CompanyType | null,
        city: v.city,
        state: emptyToNull(v.state.toUpperCase()),
        address: emptyToNull(v.address),
        website: toUrl(v.website),
        instagram: emptyToNull(v.instagram),
        phone: normalizePhone(v.phone),
      })
      .then(({ id }) => {
        toast.success('Lead adicionado')
        reset()
        onOpenChange(false)
        onAdded(id)
      })
      .catch((err) => toast.error('Não foi possível adicionar', { description: friendlyError(err) }))

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Adicionar lead</DialogTitle>
          <DialogDescription>Indicação, evento, lista própria. O site ajuda muito no dossiê.</DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit(onSubmit)} className="grid gap-4" noValidate>
          <div className="grid gap-4 sm:grid-cols-6">
            <Field label="Nome" htmlFor="ap-name" error={errors.name?.message} className="sm:col-span-4">
              <Input id="ap-name" autoFocus aria-invalid={!!errors.name} {...register('name')} />
            </Field>
            <Field label="Tipo" htmlFor="ap-type" className="sm:col-span-2">
              <NativeSelect id="ap-type" {...register('company_type')}>
                {options(COMPANY_TYPE_LABEL).map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </NativeSelect>
            </Field>
            <Field label="Cidade" htmlFor="ap-city" error={errors.city?.message} className="sm:col-span-4">
              <Input id="ap-city" aria-invalid={!!errors.city} {...register('city')} />
            </Field>
            <Field label="UF" htmlFor="ap-state" error={errors.state?.message} className="sm:col-span-2">
              <Input id="ap-state" maxLength={2} className="uppercase" aria-invalid={!!errors.state} {...register('state')} />
            </Field>
            <Field label="Endereço" htmlFor="ap-address" className="sm:col-span-6">
              <Input id="ap-address" {...register('address')} />
            </Field>
            <Field label="Site" htmlFor="ap-site" className="sm:col-span-3">
              <Input id="ap-site" placeholder="https://" {...register('website')} />
            </Field>
            <Field label="Instagram" htmlFor="ap-ig" className="sm:col-span-3">
              <Input id="ap-ig" placeholder="@perfil" {...register('instagram')} />
            </Field>
            <Field label="Telefone / WhatsApp" htmlFor="ap-phone" error={errors.phone?.message} className="sm:col-span-3">
              <Input id="ap-phone" type="tel" aria-invalid={!!errors.phone} {...register('phone')} />
            </Field>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isSubmitting} className={actionButtonClass}>
              {isSubmitting ? 'Salvando…' : 'Adicionar'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

// ---------------------------------------------------------------------------
// Importar planilha (CSV)
// ---------------------------------------------------------------------------
const strip = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim()

/** CSV simples com aspas; separador , ou ; detectado pelo cabeçalho. */
function parseCsv(text: string): string[][] {
  const firstLine = text.split(/\r?\n/, 1)[0] ?? ''
  const sep = (firstLine.match(/;/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? ';' : ','
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        cell += '"'
        i++
      } else if (ch === '"') quoted = false
      else cell += ch
    } else if (ch === '"') quoted = true
    else if (ch === sep) {
      row.push(cell)
      cell = ''
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++
      row.push(cell)
      if (row.some((c) => c.trim())) rows.push(row)
      row = []
      cell = ''
    } else cell += ch
  }
  row.push(cell)
  if (row.some((c) => c.trim())) rows.push(row)
  return rows
}

const COLUMN: Record<string, keyof TablesInsert<'prospects'>> = {
  nome: 'name', name: 'name', empresa: 'name', local: 'name',
  cidade: 'city', city: 'city', municipio: 'city',
  uf: 'state', estado: 'state', state: 'state',
  endereco: 'address', address: 'address',
  site: 'website', website: 'website', url: 'website',
  telefone: 'phone', phone: 'phone', whatsapp: 'phone', celular: 'phone',
  instagram: 'instagram',
  tipo: 'company_type', type: 'company_type',
}

function companyTypeOf(v: string): CompanyType | null {
  const s = strip(v)
  if (!s) return null
  if (/parque|operador|public|praca|prefeitura|concession/.test(s)) return 'public_operator'
  if (/condo/.test(s)) return 'condo'
  if (/constru|incorpora/.test(s)) return 'builder'
  if (/marca|anunc|brand|patroc/.test(s)) return 'brand'
  if (/clube|club|arena|academ/.test(s)) return 'club'
  return null
}

function toProspects(rows: string[][]) {
  const [header, ...body] = rows
  const cols = (header ?? []).map((h) => COLUMN[strip(h)] ?? null)
  if (!cols.includes('name')) return { error: 'A planilha precisa de uma coluna "nome".', items: [] }
  const items = body
    .map((r) => {
      const o: Record<string, string> = {}
      cols.forEach((c, i) => {
        if (c && r[i]?.trim()) o[c] = r[i].trim()
      })
      return o
    })
    .filter((o) => o.name)
    .map((o) => ({
      name: o.name,
      city: o.city ?? null,
      state: /^[A-Za-z]{2}$/.test(o.state ?? '') ? o.state!.toUpperCase() : null,
      address: o.address ?? null,
      website: o.website ? toUrl(o.website) : null,
      phone: normalizePhone(o.phone),
      instagram: o.instagram ?? null,
      company_type: companyTypeOf(o.company_type ?? ''),
    }))
  return { error: null, items }
}

export function ImportProspectsDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const importer = useImportProspects()
  const [items, setItems] = useState<ReturnType<typeof toProspects>['items']>([])
  const [error, setError] = useState<string | null>(null)
  const [fileName, setFileName] = useState('')

  const close = () => {
    setItems([])
    setError(null)
    setFileName('')
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={(o) => (o ? onOpenChange(true) : close())}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Importar planilha</DialogTitle>
          <DialogDescription>
            CSV com cabeçalho. Colunas aceitas: <strong>nome</strong> (obrigatória), cidade, uf, endereço, site, telefone,
            instagram, tipo (parque, clube, condomínio, construtora, marca). No Excel/Sheets: Arquivo → Salvar como → CSV.
          </DialogDescription>
        </DialogHeader>
        <input
          type="file"
          accept=".csv,text/csv"
          aria-label="Arquivo CSV"
          className="text-sm file:mr-3 file:rounded-lg file:border-0 file:bg-secondary file:px-3 file:py-1.5 file:text-sm"
          onChange={async (e) => {
            const file = e.target.files?.[0]
            if (!file) return
            setFileName(file.name)
            const parsed = toProspects(parseCsv(await file.text()))
            setError(parsed.error)
            setItems(parsed.items)
          }}
        />
        {error && <p className="text-sm text-destructive">{error}</p>}
        {fileName && !error && (
          <div className="text-sm">
            <p>
              <span className="font-display text-2xl text-primary">{items.length}</span> leads em {fileName}
            </p>
            {items.length > 0 && (
              <ul className="mt-2 max-h-40 overflow-y-auto rounded-lg bg-muted p-2 text-xs">
                {items.slice(0, 50).map((it, i) => (
                  <li key={i}>
                    {it.name}
                    {it.city && <span className="text-muted-foreground"> · {it.city}{it.state ? `/${it.state}` : ''}</span>}
                  </li>
                ))}
                {items.length > 50 && <li className="text-muted-foreground">… e mais {items.length - 50}</li>}
              </ul>
            )}
            <p className="mt-2 text-xs text-muted-foreground">Quem já estiver na fila (mesmo nome e cidade) é pulado.</p>
          </div>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={close}>
            Cancelar
          </Button>
          <Button
            className={actionButtonClass}
            disabled={!items.length || importer.isPending}
            onClick={() =>
              importer.mutate(items, {
                onSuccess: (r) => {
                  toast.success(`${r.inserted} leads importados`, {
                    description: r.skipped ? `${r.skipped} já estavam na fila e foram pulados.` : undefined,
                  })
                  close()
                },
                onError: (err) => toast.error('A importação falhou', { description: friendlyError(err) }),
              })
            }
          >
            {importer.isPending ? 'Importando…' : `Importar ${items.length || ''}`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
