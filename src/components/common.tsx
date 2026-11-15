import type { ReactNode } from 'react'
import { Trash2 } from 'lucide-react'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import { useState } from 'react'

export function PageHeader({ title, count, actions }: { title: string; count?: number; actions?: ReactNode }) {
  return (
    <header className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <h1 className="text-5xl leading-none text-primary">
        {title}
        {count != null && <span className="ml-3 text-3xl text-accent">{count}</span>}
      </h1>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </header>
  )
}

export function EmptyState({ title, description, action }: { title: string; description?: string; action?: ReactNode }) {
  return (
    <div className="rounded-xl border border-dashed border-border bg-card/60 px-6 py-10 text-center">
      <p className="font-display text-2xl tracking-wide text-primary">{title}</p>
      {description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
      {action && <div className="mt-4 flex justify-center">{action}</div>}
    </div>
  )
}

export function ConfirmDelete({
  title,
  description,
  onConfirm,
  label = 'Excluir',
  compact = false,
}: {
  title: string
  description: string
  onConfirm: () => Promise<unknown>
  label?: string
  /** Só o ícone (para linhas de tabela). */
  compact?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  return (
    <>
      {compact ? (
        <Button type="button" variant="ghost" size="icon-sm" aria-label={label} title={label} onClick={() => setOpen(true)}>
          <Trash2 aria-hidden className="text-destructive" />
        </Button>
      ) : (
        <Button type="button" variant="destructive" onClick={() => setOpen(true)}>
          <Trash2 aria-hidden />
          {label}
        </Button>
      )}
      <AlertDialog open={open} onOpenChange={setOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{title}</AlertDialogTitle>
            <AlertDialogDescription>{description}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy}>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={busy}
              onClick={async () => {
                setBusy(true)
                try {
                  await onConfirm()
                  setOpen(false)
                } finally {
                  setBusy(false)
                }
              }}
            >
              {busy ? 'Excluindo…' : 'Excluir'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}

export const actionButtonClass = 'bg-accent text-accent-foreground hover:bg-accent/85'
