-- =====================================================================
-- NEQST — Sprint 3
-- 18. Perfil e busca de parceiro
--
-- A fila é desenhada como uma pilha de raquetes, uma por time, com as
-- cores que o jogador escolhe no perfil. Sem isso, a tela principal não
-- consegue desenhar a pilha.
-- =====================================================================

alter table public.profiles add column if not exists racket_frame_color text not null default '#C49051';
alter table public.profiles add column if not exists racket_grip_color  text not null default '#F1ECEF';
alter table public.profiles add column if not exists avatar_tone        smallint not null default 0;

do $$ begin
  alter table public.profiles
    add constraint profiles_racket_colors
    check (racket_frame_color ~ '^#[0-9A-Fa-f]{6}$' and racket_grip_color ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.profiles
    add constraint profiles_avatar_tone_range check (avatar_tone between 0 and 2);
exception when duplicate_object then null; end $$;

comment on column public.profiles.racket_frame_color is 'Cor do aro da raquete na pilha da fila.';
comment on column public.profiles.racket_grip_color  is 'Cor do grip da raquete na pilha da fila.';
comment on column public.profiles.avatar_tone        is 'Índice do tom de fundo do avatar (0-2).';

-- Paleta do protótipo. Fica no banco para o app e o backend não
-- divergirem, e para a validação recusar cor fora do conjunto.
create table if not exists public.racket_palette (
  color       text primary key check (color ~ '^#[0-9A-Fa-f]{6}$'),
  name        text not null,
  for_frame   boolean not null default true,
  for_grip    boolean not null default true,
  sort_order  smallint not null default 0
);

insert into public.racket_palette (color, name, sort_order) values
  ('#C49051', 'Ocre',        1),
  ('#F1ECEF', 'Giz',         2),
  ('#B13F16', 'Ferrugem',    3),
  ('#6D9CB7', 'Azul névoa',  4),
  ('#D0C0C9', 'Malva',       5),
  ('#74B69D', 'Sálvia',      6)
on conflict (color) do update set name = excluded.name, sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- Atualizar o próprio perfil
-- ---------------------------------------------------------------------
create or replace function public.update_my_profile(
  p_full_name   text default null,
  p_frame_color text default null,
  p_grip_color  text default null,
  p_avatar_tone smallint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.profiles%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if p_frame_color is not null
     and not exists (select 1 from public.racket_palette rp
                     where rp.color = upper(p_frame_color) and rp.for_frame) then
    raise exception 'Cor de aro fora da paleta: %', p_frame_color using errcode = 'NQ019';
  end if;

  if p_grip_color is not null
     and not exists (select 1 from public.racket_palette rp
                     where rp.color = upper(p_grip_color) and rp.for_grip) then
    raise exception 'Cor de grip fora da paleta: %', p_grip_color using errcode = 'NQ019';
  end if;

  update public.profiles p
     set full_name          = coalesce(nullif(trim(p_full_name), ''), p.full_name),
         racket_frame_color = coalesce(upper(p_frame_color), p.racket_frame_color),
         racket_grip_color  = coalesce(upper(p_grip_color), p.racket_grip_color),
         avatar_tone        = coalesce(p_avatar_tone, p.avatar_tone)
   where p.id = v_user
  returning * into v_row;

  return jsonb_build_object(
    'user_id',            v_row.id,
    'username',           v_row.username,
    'full_name',          v_row.full_name,
    'initials',           public.initials_of(v_row.full_name),
    'avatar_tone',        v_row.avatar_tone,
    'racket_frame_color', v_row.racket_frame_color,
    'racket_grip_color',  v_row.racket_grip_color
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Buscar parceiro, com disponibilidade
--
-- O protótipo mostra cada candidato como "Disponível · @handle" ou
-- "Na fila · Quadra 04 — indisponível", e bloqueia a seleção. A
-- disponibilidade vem junto para a tela não fazer N consultas.
-- ---------------------------------------------------------------------
create or replace function public.search_partners(
  p_query text default null,
  p_limit integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with needle as (
    select regexp_replace(lower(trim(coalesce(p_query, ''))), '^@', '') as q
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',            s.id,
        'username',           s.username,
        'handle',             '@' || s.username,
        'full_name',          s.full_name,
        'initials',           public.initials_of(coalesce(s.full_name, s.username::text)),
        'avatar_tone',        s.avatar_tone,
        'racket_frame_color', s.racket_frame_color,
        'racket_grip_color',  s.racket_grip_color,
        'state',              s.st ->> 'state',
        'available',          (s.st ->> 'state') = 'free',
        'where',              s.st ->> 'where'
      )
      order by (s.st ->> 'state') = 'free' desc, s.full_name, s.username
    ),
    '[]'::jsonb
  )
  from (
    select p.id, p.username, p.full_name, p.avatar_tone,
           p.racket_frame_color, p.racket_grip_color,
           public.player_state(p.id) as st
    from public.profiles p, needle n
    where p.id <> auth.uid()
      and p.role = 'player'
      and (
        n.q = ''
        or p.username ilike '%' || n.q || '%'
        or p.full_name ilike '%' || n.q || '%'
      )
    order by p.full_name, p.username
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
  ) s;
$$;

comment on function public.search_partners(text, integer) is
  'Candidatos a parceiro de dupla, com disponibilidade (free/queued/playing).';

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
alter table public.racket_palette enable row level security;

drop policy if exists "paleta: leitura pública" on public.racket_palette;
create policy "paleta: leitura pública"
  on public.racket_palette for select
  to anon, authenticated
  using (true);

revoke all on public.racket_palette from anon, authenticated;
grant select on public.racket_palette to anon, authenticated;

grant execute on function public.update_my_profile(text, text, text, smallint) to authenticated;
grant execute on function public.search_partners(text, integer)                to authenticated;
