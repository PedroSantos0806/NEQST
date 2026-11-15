type Props = {
  title: string
  sprint: string
  description: string
}

export function PagePlaceholder({ title, sprint, description }: Props) {
  return (
    <section>
      <h1 className="text-5xl leading-none text-primary">{title}</h1>
      <div className="mt-6 max-w-xl rounded-xl border border-border bg-card p-5">
        <p className="font-display text-xl tracking-wide text-accent">{sprint}</p>
        <p className="mt-1 text-sm text-muted-foreground">{description}</p>
      </div>
    </section>
  )
}
