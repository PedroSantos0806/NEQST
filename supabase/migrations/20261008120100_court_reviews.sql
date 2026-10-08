-- =====================================================================
-- NEQST — Sprint 2
-- 11. Sistema de avaliação da quadra
--
-- Só avalia quem jogou: exigir uma partida concluída na quadra é o que
-- separa avaliação de opinião aleatória, e não custa nada verificar —
-- o histórico da migration 10 já tem esse dado.
-- =====================================================================

create table if not exists public.court_reviews (
  id          uuid primary key default gen_random_uuid(),
  court_id    uuid not null references public.courts (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- Uma avaliação por jogador por quadra (editável).
  unique (court_id, user_id),

  constraint court_reviews_comment_length
    check (comment is null or char_length(comment) <= 1000)
);

comment on table public.court_reviews is
  'Avaliação de 1 a 5 por jogador por quadra, com comentário opcional.';

create index if not exists court_reviews_court_idx on public.court_reviews (court_id, created_at desc);
create index if not exists court_reviews_user_idx  on public.court_reviews (user_id, created_at desc);

drop trigger if exists court_reviews_set_updated_at on public.court_reviews;
create trigger court_reviews_set_updated_at
  before update on public.court_reviews
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Agregados desnormalizados na quadra (a tela de lista não faz join)
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists rating_avg   numeric(3,2);
alter table public.courts add column if not exists rating_count integer not null default 0;

comment on column public.courts.rating_avg is
  'Média das avaliações, mantida por trigger. Null quando ainda não há avaliação.';

create or replace function public.refresh_court_rating(p_court_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.courts c
     set rating_avg   = agg.avg_rating,
         rating_count = agg.total
    from (
      select round(avg(r.rating)::numeric, 2) as avg_rating,
             count(*)::integer                as total
      from public.court_reviews r
      where r.court_id = p_court_id
    ) agg
   where c.id = p_court_id;
$$;

create or replace function public.court_reviews_sync_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.refresh_court_rating(coalesce(new.court_id, old.court_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists court_reviews_sync on public.court_reviews;
create trigger court_reviews_sync
  after insert or update or delete on public.court_reviews
  for each row execute function public.court_reviews_sync_rating();

-- ---------------------------------------------------------------------
-- Pode avaliar? (precisa de pelo menos uma partida concluída na quadra)
-- ---------------------------------------------------------------------
create or replace function public.can_review_court(p_court_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    where m.user_id = auth.uid()
      and e.court_id = p_court_id
      and e.status = 'done'
  );
$$;

-- ---------------------------------------------------------------------
-- Criar ou atualizar a própria avaliação
--   NQ010 — ainda não jogou nesta quadra
-- ---------------------------------------------------------------------
create or replace function public.rate_court(
  p_court_id uuid,
  p_rating   smallint,
  p_comment  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_review public.court_reviews%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'A nota deve ficar entre 1 e 5' using errcode = 'NQ011';
  end if;

  if not exists (select 1 from public.courts c where c.id = p_court_id) then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  if not public.can_review_court(p_court_id) then
    raise exception 'Jogue nesta quadra antes de avaliá-la' using errcode = 'NQ010';
  end if;

  insert into public.court_reviews (court_id, user_id, rating, comment)
  values (p_court_id, v_user, p_rating, nullif(trim(coalesce(p_comment, '')), ''))
  on conflict (court_id, user_id) do update
    set rating  = excluded.rating,
        comment = excluded.comment
  returning * into v_review;

  return jsonb_build_object(
    'review_id',    v_review.id,
    'court_id',     v_review.court_id,
    'rating',       v_review.rating,
    'comment',      v_review.comment,
    'created_at',   v_review.created_at,
    'updated_at',   v_review.updated_at,
    'court_rating', (
      select jsonb_build_object('average', c.rating_avg, 'count', c.rating_count)
      from public.courts c where c.id = p_court_id
    )
  );
end;
$$;

create or replace function public.delete_my_court_review(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_deleted integer;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  delete from public.court_reviews
  where court_id = p_court_id and user_id = auth.uid();
  get diagnostics v_deleted = row_count;

  return jsonb_build_object('court_id', p_court_id, 'deleted', v_deleted > 0);
end;
$$;

-- ---------------------------------------------------------------------
-- Avaliações de uma quadra (lista pública, paginada)
-- ---------------------------------------------------------------------
create or replace function public.court_reviews_page(
  p_court_id uuid,
  p_limit    integer default 20,
  p_before   timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'court_id', p_court_id,
    'summary', (
      select jsonb_build_object(
        'average', c.rating_avg,
        'count',   c.rating_count,
        'distribution', (
          select coalesce(jsonb_object_agg(d.rating::text, d.total), '{}'::jsonb)
          from (
            select r.rating, count(*)::integer as total
            from public.court_reviews r
            where r.court_id = p_court_id
            group by r.rating
          ) d
        )
      )
      from public.courts c where c.id = p_court_id
    ),
    'my_review', (
      select jsonb_build_object('rating', r.rating, 'comment', r.comment, 'updated_at', r.updated_at)
      from public.court_reviews r
      where r.court_id = p_court_id and r.user_id = auth.uid()
    ),
    'can_review', public.can_review_court(p_court_id),
    'reviews', (
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'review_id',  s.id,
          'rating',     s.rating,
          'comment',    s.comment,
          'created_at', s.created_at,
          'updated_at', s.updated_at,
          'author', jsonb_build_object(
            'user_id',    s.user_id,
            'username',   s.username,
            'full_name',  s.full_name,
            'avatar_url', s.avatar_url
          )
        ) order by s.created_at desc),
        '[]'::jsonb
      )
      from (
        select r.id, r.rating, r.comment, r.created_at, r.updated_at,
               r.user_id, p.username, p.full_name, p.avatar_url
        from public.court_reviews r
        left join public.profiles p on p.id = r.user_id
        where r.court_id = p_court_id
          and (p_before is null or r.created_at < p_before)
        order by r.created_at desc
        limit least(greatest(coalesce(p_limit, 20), 1), 100)
      ) s
    )
  );
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.court_reviews enable row level security;

drop policy if exists "reviews: leitura pública" on public.court_reviews;
create policy "reviews: leitura pública"
  on public.court_reviews for select
  to anon, authenticated
  using (true);

drop policy if exists "reviews: dono gerencia" on public.court_reviews;
create policy "reviews: dono gerencia"
  on public.court_reviews for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "reviews: staff remove abuso" on public.court_reviews;
create policy "reviews: staff remove abuso"
  on public.court_reviews for delete
  to authenticated
  using (public.is_staff());

revoke all on public.court_reviews from anon, authenticated;
grant select on public.court_reviews to anon, authenticated;

revoke all on function public.refresh_court_rating(uuid)        from public;
revoke all on function public.rate_court(uuid, smallint, text)  from public;
revoke all on function public.delete_my_court_review(uuid)      from public;

grant execute on function public.rate_court(uuid, smallint, text)                    to authenticated;
grant execute on function public.delete_my_court_review(uuid)                        to authenticated;
grant execute on function public.can_review_court(uuid)                              to authenticated;
grant execute on function public.court_reviews_page(uuid, integer, timestamptz)      to anon, authenticated;
