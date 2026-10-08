-- =====================================================================
-- NEQST — Sprint 2
-- 10. Histórico do usuário (quadras visitadas, partidas jogadas)
--
-- Não precisa de tabela nova: a Sprint 1 já grava started_at/ended_at
-- em queue_entries. O histórico é uma leitura sobre esses dados.
-- =====================================================================

-- Índice que sustenta a paginação do histórico por jogador.
create index if not exists queue_entries_history_idx
  on public.queue_entries (court_id, ended_at desc)
  where status = 'done';

create index if not exists queue_entry_members_history_idx
  on public.queue_entry_members (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- Partidas jogadas pelo usuário logado, mais recentes primeiro.
--
-- p_before: cursor de paginação — passe o ended_at da última linha da
-- página anterior (keyset pagination, estável mesmo com novas partidas).
-- ---------------------------------------------------------------------
create or replace function public.my_match_history(
  p_limit  integer default 20,
  p_before timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with played as (
    select
      e.id          as entry_id,
      e.court_id,
      c.name        as court_name,
      c.slug        as court_slug,
      c.photo_url   as court_photo_url,
      e.mode,
      e.joined_at,
      e.started_at,
      e.ended_at,
      m.role        as my_role,
      greatest(
        round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer,
        0
      )             as duration_minutes
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    join public.courts c        on c.id = e.court_id
    where m.user_id = auth.uid()
      and e.status = 'done'
      and e.ended_at is not null
      and (p_before is null or e.ended_at < p_before)
    order by e.ended_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',         p.entry_id,
        'court_id',         p.court_id,
        'court_name',       p.court_name,
        'court_slug',       p.court_slug,
        'court_photo_url',  p.court_photo_url,
        'mode',             p.mode,
        'joined_at',        p.joined_at,
        'started_at',       p.started_at,
        'ended_at',         p.ended_at,
        'duration_minutes', p.duration_minutes,
        'my_role',          p.my_role,
        -- Com quem joguei (vazio quando foi individual).
        'teammates', (
          select coalesce(
            jsonb_agg(jsonb_build_object(
              'user_id',    pr.id,
              'username',   pr.username,
              'full_name',  pr.full_name,
              'avatar_url', pr.avatar_url
            )),
            '[]'::jsonb
          )
          from public.queue_entry_members om
          join public.profiles pr on pr.id = om.user_id
          where om.entry_id = p.entry_id and om.user_id <> auth.uid()
        )
      )
      order by p.ended_at desc
    ),
    '[]'::jsonb
  )
  from played p;
$$;

comment on function public.my_match_history(integer, timestamptz) is
  'Partidas concluídas do usuário logado, com paginação por cursor (p_before = ended_at da última linha).';

-- ---------------------------------------------------------------------
-- Quadras visitadas pelo usuário logado, com contagem e última visita.
-- ---------------------------------------------------------------------
create or replace function public.my_visited_courts(p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'court_id',       v.court_id,
        'court_name',     v.court_name,
        'court_slug',     v.court_slug,
        'photo_url',      v.photo_url,
        'latitude',       v.latitude,
        'longitude',      v.longitude,
        'matches_played', v.matches_played,
        'minutes_played', v.minutes_played,
        'first_visit_at', v.first_visit_at,
        'last_visit_at',  v.last_visit_at
      )
      order by v.last_visit_at desc
    ),
    '[]'::jsonb
  )
  from (
    select
      c.id        as court_id,
      c.name      as court_name,
      c.slug      as court_slug,
      c.photo_url,
      c.latitude,
      c.longitude,
      count(*)::integer as matches_played,
      coalesce(sum(
        greatest(round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer, 0)
      ), 0)::integer   as minutes_played,
      min(e.ended_at)  as first_visit_at,
      max(e.ended_at)  as last_visit_at
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    join public.courts c        on c.id = e.court_id
    where m.user_id = auth.uid()
      and e.status = 'done'
      and e.ended_at is not null
    group by c.id, c.name, c.slug, c.photo_url, c.latitude, c.longitude
    order by max(e.ended_at) desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) v;
$$;

comment on function public.my_visited_courts(integer) is
  'Quadras onde o usuário logado já jogou, com partidas, minutos e última visita.';

-- ---------------------------------------------------------------------
-- Resumo para a tela de perfil (US-01 + histórico da Sprint 2).
-- ---------------------------------------------------------------------
create or replace function public.my_profile_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'profile', (
      select jsonb_build_object(
        'user_id',    p.id,
        'username',   p.username,
        'full_name',  p.full_name,
        'email',      p.email,
        'avatar_url', p.avatar_url,
        'role',       p.role,
        'created_at', p.created_at
      )
      from public.profiles p where p.id = auth.uid()
    ),
    'stats', (
      select jsonb_build_object(
        'matches_played', count(*)::integer,
        'minutes_played', coalesce(sum(
          greatest(round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer, 0)
        ), 0)::integer,
        'courts_visited', count(distinct e.court_id)::integer,
        'last_match_at',  max(e.ended_at)
      )
      from public.queue_entry_members m
      join public.queue_entries e on e.id = m.entry_id
      where m.user_id = auth.uid() and e.status = 'done' and e.ended_at is not null
    ),
    'active_entries', public.my_active_entries()
  );
$$;

comment on function public.my_profile_summary() is
  'Uma chamada para a tela de perfil: dados, estatísticas e filas ativas.';

revoke all on function public.my_match_history(integer, timestamptz) from public;
revoke all on function public.my_visited_courts(integer)             from public;
revoke all on function public.my_profile_summary()                   from public;

grant execute on function public.my_match_history(integer, timestamptz) to authenticated;
grant execute on function public.my_visited_courts(integer)             to authenticated;
grant execute on function public.my_profile_summary()                   to authenticated;
