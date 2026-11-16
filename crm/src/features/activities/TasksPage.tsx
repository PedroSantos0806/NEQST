import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { CircleAlert, Plus } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { EmptyState, PageHeader, actionButtonClass } from '@/components/common'
import { friendlyError } from '@/lib/errors'
import { useAuth } from '@/features/auth/auth-context'
import { useDealsWithoutNext } from '@/features/deals/api'
import { useBoardRealtime } from '@/features/deals/useBoardRealtime'
import { useTasks, type ActivityItem } from './api'
import { ActivityList } from './ActivityList'
import { ActivityFormDialog } from './ActivityFormDialog'

type Scope = 'mine' | 'team'

function startOfDay(d = new Date()) {
  const x = new Date(d)
  x.setHours(0, 0, 0, 0)
  return x.getTime()
}

export function TasksPage() {
  const { user } = useAuth()
  const [scope, setScope] = useState<Scope>('mine')
  const tasks = useTasks(scope === 'mine' ? (user?.id ?? null) : null)
  const withoutNext = useDealsWithoutNext()
  useBoardRealtime()

  const [form, setForm] = useState<
    { activity?: ActivityItem; dealId?: string; dealTitle?: string; next?: { reason: string } } | null
  >(null)

  const groups = useMemo(() => {
    const today = startOfDay()
    const tomorrow = today + 86_400_000
    const in7 = today + 8 * 86_400_000
    const g = { overdue: [], today: [], week: [], later: [], noDate: [], done: [] } as Record<string, ActivityItem[]>
    for (const a of tasks.data ?? []) {
      if (a.done_at) g.done.push(a)
      else if (!a.due_at) g.noDate.push(a)
      else {
        const t = new Date(a.due_at).getTime()
        if (t < today) g.overdue.push(a)
        else if (t < tomorrow) g.today.push(a)
        else if (t < in7) g.week.push(a)
        else g.later.push(a)
      }
    }
    g.done.sort((a, b) => (b.done_at ?? '').localeCompare(a.done_at ?? ''))
    return g
  }, [tasks.data])

  const openCount = (tasks.data ?? []).filter((a) => !a.done_at).length

  const askNext = (dealId: string, dealTitle?: string) =>
    setForm({ dealId, dealTitle, next: { reason: 'Atividade concluída. Qual o próximo passo?' } })

  const section = (title: string, items: ActivityItem[], tone?: 'danger') =>
    items.length > 0 && (
      <div key={title}>
        <h2 className={cn('mb-2 text-2xl', tone === 'danger' ? 'text-destructive' : 'text-primary')}>
          {title} <span className="text-accent">{items.length}</span>
        </h2>
        <ActivityList items={items} onEdit={(a) => setForm({ activity: a })} onDealWithoutNext={askNext} />
      </div>
    )

  return (
    <section className="flex flex-col gap-6">
      <PageHeader
        title={scope === 'mine' ? 'Minhas tarefas' : 'Tarefas do time'}
        count={openCount}
        actions={
          <>
            <div role="group" aria-label="De quem" className="flex rounded-lg border border-border bg-card p-0.5">
              {(['mine', 'team'] as const).map((s) => (
                <button
                  key={s}
                  type="button"
                  aria-pressed={scope === s}
                  onClick={() => setScope(s)}
                  className={cn(
                    'rounded-md px-3 py-1 text-sm font-medium',
                    scope === s ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground',
                  )}
                >
                  {s === 'mine' ? 'Minhas' : 'Do time'}
                </button>
              ))}
            </div>
            <Button className={actionButtonClass} onClick={() => setForm({})}>
              <Plus aria-hidden /> Nova tarefa
            </Button>
          </>
        }
      />

      {(withoutNext.data?.length ?? 0) > 0 && (
        <div className="rounded-xl border border-destructive/30 bg-destructive/10 p-4">
          <p className="mb-2 flex items-center gap-2 text-sm font-semibold text-destructive">
            <CircleAlert className="size-4" aria-hidden />
            {withoutNext.data!.length} {withoutNext.data!.length === 1 ? 'negócio aberto sem' : 'negócios abertos sem'} próxima atividade
          </p>
          <ul className="flex flex-wrap gap-2">
            {withoutNext.data!.map((d) => (
              <li key={d.id} className="flex items-center gap-1 rounded-lg bg-card px-2 py-1 text-sm">
                <Link to={`/negocios/${d.id}`} className="font-medium underline-offset-4 hover:underline">
                  {d.title}
                </Link>
                {d.company && <span className="text-muted-foreground">· {d.company.name}</span>}
                <button
                  type="button"
                  className="ml-1 text-xs font-semibold text-primary underline underline-offset-4"
                  onClick={() => askNext(d.id, d.title)}
                >
                  Agendar
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {tasks.error ? (
        <EmptyState title="Erro ao carregar" description={friendlyError(tasks.error)} />
      ) : tasks.isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando…</p>
      ) : openCount === 0 && groups.done.length === 0 ? (
        <EmptyState title="Nenhuma tarefa" description="As atividades dos negócios aparecem aqui." />
      ) : (
        <>
          {section('Atrasadas', groups.overdue, 'danger')}
          {section('Hoje', groups.today)}
          {section('Próximos 7 dias', groups.week)}
          {section('Mais tarde', groups.later)}
          {section('Sem data', groups.noDate)}
          {openCount === 0 && <p className="text-sm text-muted-foreground">Tudo em dia. Nenhuma tarefa em aberto.</p>}
          {section('Concluídas nos últimos 7 dias', groups.done)}
        </>
      )}

      <ActivityFormDialog
        open={form !== null}
        onOpenChange={(o) => !o && setForm(null)}
        activity={form?.activity}
        dealId={form?.dealId}
        dealTitle={form?.dealTitle ?? form?.activity?.deal?.title}
        next={form?.next}
      />
    </section>
  )
}
