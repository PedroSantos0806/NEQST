-- =====================================================================
-- NEQST — Sprint 5
-- 29. A fila com anfitrião (docs/sprint5.md)
--
-- Um piloto sem nada colado no parque. A primeira pessoa com o app abre
-- a fila da quadra e vira o anfitrião: informa quem já está jogando e
-- quem espera sem app. Quem chega depois entra pelo QR na tela de
-- alguém da fila — um convite que troca a cada 30 s e vale 10 min —, e
-- a presença continua provada pelo GPS contra a coordenada da quadra,
-- conferido na Edge Function scan-court.
--
--   1. Cada quadra tem um modo: 'fixed_qr' (o de sempre) ou 'host'.
--      No modo anfitrião a distância não pode ser desligada.
--   2. Uma fila com anfitrião aberta por quadra.
--   3. Vagas sem app: na frente, só na abertura; depois, só no fim.
--      Só o anfitrião mexe nelas, e elas não seguem a tolerância.
--   4. O anfitrião que sai da fila passa o papel ao próximo com app.
--   5. Check-in pelo botão "Entrando na quadra" (scan token 'gps').
--   6. A fila esquecida encerra com 30 min sem ninguém e sem turno.
--   7. A origem de cada entrada fica gravada para o painel do piloto.
--
-- Códigos novos:
--   NQ030 a quadra não está no modo anfitrião
--   NQ031 já existe uma fila aberta nesta quadra
--   NQ032 dados da fila com anfitrião inválidos
--   NQ033 só quem organiza a fila faz isso
--   NQ034 a fila desta quadra não está aberta
--   NQ035 no modo anfitrião a distância não pode ser desligada
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. O modo da quadra
-- ---------------------------------------------------------------------
alter table public.courts
  add column if not exists queue_mode text not null default 'fixed_qr';

do $$ begin
  alter table public.courts
    add constraint courts_queue_mode_check check (queue_mode in ('fixed_qr', 'host'));
exception when duplicate_object then null; end $$;

-- Sem a distância, o print do QR mandado no WhatsApp funcionaria de casa.
do $$ begin
  alter table public.courts
    add constraint courts_host_mode_needs_proximity
    check (queue_mode <> 'host' or enforce_proximity);
exception when duplicate_object then null; end $$;

comment on column public.courts.queue_mode is
  'fixed_qr: entra pelo QR impresso ou NFC. host: piloto sem nada na placa — '
  'a primeira pessoa abre a fila e os próximos entram pelo QR na tela de quem já está nela.';

-- ---------------------------------------------------------------------
-- 2. A fila aberta por um anfitrião
-- ---------------------------------------------------------------------
create table if not exists public.host_sessions (
  id                 uuid primary key default gen_random_uuid(),
  court_id           uuid not null references public.courts (id) on delete cascade,
  opened_by          uuid not null references auth.users (id) on delete cascade,
  host_user_id       uuid references auth.users (id) on delete set null,
  playing_minutes    smallint,
  waiting_declared   smallint not null default 0,
  opened_at          timestamptz not null default clock_timestamp(),
  closed_at          timestamptz,
  close_reason       text
);

comment on table public.host_sessions is
  'Uma fila aberta pelo anfitrião numa quadra sem QR na placa. host_user_id é quem organiza agora.';
comment on column public.host_sessions.playing_minutes is
  'Quanto faltava para o turno de quem já estava jogando, como o anfitrião informou.';

-- Duas pessoas abrindo ao mesmo tempo: a segunda cai na fila da primeira.
create unique index if not exists host_sessions_one_open_per_court
  on public.host_sessions (court_id)
  where closed_at is null;

create index if not exists host_sessions_opened_idx on public.host_sessions (opened_at);

alter table public.host_sessions enable row level security;
revoke all on public.host_sessions from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Vagas sem app
--
-- Uma vaga sem membros: as pessoas que já estavam na fila antes do app.
-- created_by é o anfitrião que a registrou — ele não vira membro dela,
-- então continua livre para a própria vaga.
-- ---------------------------------------------------------------------
alter table public.queue_entries
  add column if not exists is_offline      boolean not null default false,
  add column if not exists offline_label   text,
  add column if not exists offline_kind    text,
  add column if not exists host_session_id uuid references public.host_sessions (id) on delete set null;

do $$ begin
  alter table public.queue_entries
    add constraint queue_entries_offline_label_check
    check (offline_label is null or char_length(offline_label) <= 40);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.queue_entries
    add constraint queue_entries_offline_kind_check
    check ((offline_kind is null) = (not is_offline)
           and (offline_kind is null or offline_kind in ('playing', 'waiting')));
exception when duplicate_object then null; end $$;

comment on column public.queue_entries.is_offline is
  'Vaga de quem está na fila sem o app. Só o anfitrião anda com ela; não segue a tolerância.';
comment on column public.queue_entries.offline_label is
  'Como o anfitrião reconhece o grupo ("dupla de boné azul"). Visível na fila.';
comment on column public.queue_entries.offline_kind is
  'playing: o turno de quem já jogava quando a fila abriu. waiting: um grupo sem app na fila.';

create index if not exists queue_entries_host_session_idx
  on public.queue_entries (host_session_id)
  where host_session_id is not null;

-- Toda vaga aberta numa quadra com fila de anfitrião pertence a ela.
create or replace function public.queue_entry_set_host_session()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.host_session_id is null then
    select s.id into new.host_session_id
    from public.host_sessions s
    where s.court_id = new.court_id and s.closed_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists queue_entries_set_host_session on public.queue_entries;
create trigger queue_entries_set_host_session
  before insert on public.queue_entries
  for each row execute function public.queue_entry_set_host_session();

-- ---------------------------------------------------------------------
-- 4. O convite do QR na tela
-- ---------------------------------------------------------------------
create table if not exists public.host_invites (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.host_sessions (id) on delete cascade,
  court_id    uuid not null references public.courts (id) on delete cascade,
  issued_by   uuid not null references auth.users (id) on delete cascade,
  -- Cada vez que alguém abre o QR na tela é uma exibição; o código
  -- troca a cada 30 s dentro dela.
  display_id  uuid not null,
  code_hash   text not null unique,
  issued_at   timestamptz not null default clock_timestamp(),
  expires_at  timestamptz not null
);

comment on table public.host_invites is
  'Códigos do QR mostrado na tela de quem está na fila. O banco guarda só o SHA-256.';
comment on column public.host_invites.expires_at is
  '10 min: o tempo de baixar o app e criar a conta. A presença é conferida depois, pelo GPS.';

create index if not exists host_invites_court_idx  on public.host_invites (court_id, issued_at desc);
create index if not exists host_invites_issuer_idx on public.host_invites (issued_by);

alter table public.host_invites enable row level security;
revoke all on public.host_invites from anon, authenticated;

alter table public.scan_tokens
  add column if not exists invite_id uuid references public.host_invites (id) on delete set null;

-- ---------------------------------------------------------------------
-- 5. A origem de cada entrada
--
-- scan_tokens é apagado depois de um dia, então a origem vai para a
-- própria linha do membro, que fica.
-- ---------------------------------------------------------------------
alter table public.queue_entry_members
  add column if not exists origin    text,
  add column if not exists invite_id uuid references public.host_invites (id) on delete set null;

comment on column public.queue_entry_members.origin is
  'Como a pessoa provou presença ao entrar: qr, nfc, host_invite (QR na tela de alguém) '
  'ou host_open (abriu a fila como anfitrião).';

-- O scan que trouxe a pessoa, na ordem em que dá para ter certeza:
--   1. quem abriu a vaga: o token gravado nela;
--   2. quem foi aceito: o token do pedido, gasto até 10 min antes;
--   3. quem entrou com o PIN: o token que a mesma transação ainda vai
--      gastar — o único dela nesta quadra que segue valendo.
create or replace function public.queue_member_set_origin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token  uuid;
  v_method public.scan_method;
  v_invite uuid;
begin
  if new.origin is not null then
    return new;
  end if;

  select e.scan_token_id into v_token
  from public.queue_entries e
  where e.id = new.entry_id and e.created_by = new.user_id;

  if v_token is null then
    select r.scan_token_id into v_token
    from public.queue_join_requests r
    where r.entry_id = new.entry_id and r.user_id = new.user_id and r.status = 'pending'
    order by r.created_at desc
    limit 1;
  end if;

  if v_token is not null then
    select t.method, t.invite_id into v_method, v_invite
    from public.scan_tokens t where t.id = v_token;
  else
    select t.method, t.invite_id into v_method, v_invite
    from public.scan_tokens t
    where t.user_id = new.user_id
      and t.court_id = new.court_id
      and t.created_at > now() - interval '30 minutes'
    order by (t.consumed_at is null) desc, (t.expires_at > now()) desc, t.created_at desc
    limit 1;
  end if;

  new.origin := case
                  when v_method is null  then 'unknown'
                  when v_method = 'gps'  then 'host_open'
                  else v_method::text
                end;
  new.invite_id := v_invite;
  return new;
end;
$$;

drop trigger if exists queue_entry_members_set_origin on public.queue_entry_members;
create trigger queue_entry_members_set_origin
  before insert on public.queue_entry_members
  for each row execute function public.queue_member_set_origin();

-- ---------------------------------------------------------------------
-- 6. O que acontece com o convite antes de virar uma entrada
-- ---------------------------------------------------------------------
create table if not exists public.pilot_events (
  id              bigint generated always as identity primary key,
  court_id        uuid references public.courts (id) on delete cascade,
  invite_id       uuid references public.host_invites (id) on delete set null,
  user_id         uuid references auth.users (id) on delete set null,
  visitor         text check (visitor is null or char_length(visitor) <= 64),
  event           text not null check (event in ('invite_opened', 'invite_scanned', 'invite_too_far')),
  distance_meters double precision,
  created_at      timestamptz not null default now()
);

comment on table public.pilot_events is
  'Funil do convite: aberto (antes do login), validado pelo GPS e recusado por distância.';

-- Recarregar a página não conta duas vezes.
create unique index if not exists pilot_events_open_once
  on public.pilot_events (invite_id, visitor)
  where event = 'invite_opened';

create index if not exists pilot_events_court_idx on public.pilot_events (court_id, created_at);

alter table public.pilot_events enable row level security;
revoke all on public.pilot_events from anon, authenticated;

-- ---------------------------------------------------------------------
-- Quem organiza a fila
-- ---------------------------------------------------------------------

-- Ainda tem alguém com o app nesta quadra (na fila ou jogando)?
create or replace function public.court_has_app_players(p_court_id uuid)
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
    where e.court_id = p_court_id
      and m.is_active
      and not e.is_offline
      and e.status in ('waiting', 'ready', 'playing')
  );
$$;

-- Esquecida: ninguém com o app, nenhum turno rolando e 30 min sem
-- nada acontecer. As vagas sem app não seguram a fila aberta — sem
-- ninguém com o app, não há quem ande com elas.
create or replace function public.host_session_is_idle(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.court_has_app_players(s.court_id)
     and not exists (
       select 1 from public.matches mt
       where mt.court_id = s.court_id and mt.ended_at is null and mt.expires_at > now()
     )
     and greatest(
           s.opened_at,
           (select max(greatest(e.joined_at, e.started_at, e.ended_at, e.left_at))
              from public.queue_entries e
             where e.host_session_id = s.id and not e.is_offline)
         ) < now() - interval '30 minutes'
  from public.host_sessions s
  where s.id = p_session_id;
$$;

-- A fila aberta desta quadra, se ainda estiver valendo.
create or replace function public.current_host_session(p_court_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select s.id
  from public.host_sessions s
  where s.court_id = p_court_id
    and s.closed_at is null
    and not public.host_session_is_idle(s.id);
$$;

-- Quem organiza agora: o anfitrião enquanto estiver na fila; saiu, o
-- dono da próxima vaga com app (quem espera antes de quem está jogando).
create or replace function public.effective_host(p_court_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select s.host_user_id
      from public.host_sessions s
      where s.id = public.current_host_session(p_court_id)
        and exists (
          select 1
          from public.queue_entry_members m
          join public.queue_entries e on e.id = m.entry_id
          where m.user_id = s.host_user_id
            and m.is_active
            and e.court_id = p_court_id
            and not e.is_offline
            and e.status in ('waiting', 'ready', 'playing')
        )
    ),
    (
      select m.user_id
      from public.queue_entry_members m
      join public.queue_entries e on e.id = m.entry_id
      where public.current_host_session(p_court_id) is not null
        and e.court_id = p_court_id
        and m.is_active
        and m.role = 'owner'
        and not e.is_offline
        and e.status in ('waiting', 'ready', 'playing')
      order by (e.status = 'playing'), e.queue_number, m.created_at
      limit 1
    )
  );
$$;

-- Confere que quem chama organiza a fila e grava a herança, se houve.
create or replace function public.require_host(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_session uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_session := public.current_host_session(p_court_id);
  if v_session is null then
    raise exception 'A fila desta quadra não está aberta' using errcode = 'NQ034';
  end if;

  perform 1 from public.host_sessions s where s.id = v_session for update;

  if public.effective_host(p_court_id) is distinct from v_user then
    raise exception 'Só quem organiza a fila desta quadra faz isso' using errcode = 'NQ033';
  end if;

  update public.host_sessions
     set host_user_id = v_user
   where id = v_session and host_user_id is distinct from v_user;

  return v_session;
end;
$$;

-- Fecha a fila: as vagas sem app que ainda esperavam saem junto.
create or replace function public.close_host_session(p_session_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.host_sessions%rowtype;
  v_called  boolean;
begin
  update public.host_sessions
     set closed_at = now(), close_reason = p_reason
   where id = p_session_id and closed_at is null
  returning * into v_session;

  if not found then
    return;
  end if;

  select exists (
    select 1 from public.queue_entries e
    where e.court_id = v_session.court_id and e.is_offline and e.status = 'ready'
  ) into v_called;

  update public.queue_entries
     set status = 'cancelled', left_at = now(), cancel_reason = 'session_closed'
   where court_id = v_session.court_id
     and is_offline
     and status in ('waiting', 'ready');

  if v_called then
    perform public.call_next_team(v_session.court_id);
  end if;
end;
$$;

create or replace function public.close_idle_host_sessions(p_court_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_closed  integer := 0;
begin
  for v_session in
    select s.id
    from public.host_sessions s
    where s.closed_at is null
      and (p_court_id is null or s.court_id = p_court_id)
      and public.host_session_is_idle(s.id)
  loop
    perform public.close_host_session(v_session.id, 'idle');
    v_closed := v_closed + 1;
  end loop;

  return v_closed;
end;
$$;

revoke all on function public.court_has_app_players(uuid)        from public, anon, authenticated;
revoke all on function public.host_session_is_idle(uuid)         from public, anon, authenticated;
revoke all on function public.current_host_session(uuid)         from public, anon, authenticated;
revoke all on function public.effective_host(uuid)               from public, anon, authenticated;
revoke all on function public.require_host(uuid)                 from public, anon, authenticated;
revoke all on function public.close_host_session(uuid, text)     from public, anon, authenticated;
revoke all on function public.close_idle_host_sessions(uuid)     from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Chamar o próximo: a vaga sem app não tem tolerância
--
-- Ninguém nela tem como fazer check-in. A fila espera o anfitrião marcar
-- que entraram (ou que desistiram), e é ele quem recebe o aviso.
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_next    public.queue_entries%rowtype;
  v_host    uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return null;
  end if;

  -- Só chama se a quadra estiver livre.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select e.* into v_next
  from public.queue_positions qp
  join public.queue_entries e on e.id = qp.entry_id
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next.id is null then
    return null;
  end if;

  update public.queue_entries
     set status          = 'ready',
         called_at       = coalesce(called_at, now()),
         call_expires_at = case
                             when is_offline then null
                             else now() + make_interval(secs => v_court.call_window_seconds)
                           end
   where id = v_next.id and status = 'waiting';

  if found and v_next.is_offline then
    v_host := public.effective_host(p_court_id);
    if v_host is not null then
      perform public.enqueue_user_notification(
        v_host, p_court_id, 'host_offline_called',
        'Vez do grupo sem app',
        format('%s pode entrar na %s. Marque no app quando entrarem.',
               coalesce(v_next.offline_label, 'O grupo sem app'),
               public.court_label(v_court.court_number)),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_next.id)
      );
    end if;
  end if;

  return v_next.id;
end;
$$;

revoke all on function public.call_next_team(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Prova de presença: o token 'gps' só serve para abrir a fila e para o
-- check-in. Entrar na fila de alguém continua exigindo o QR — o da
-- placa ou o da tela de quem já está nela.
-- ---------------------------------------------------------------------
drop function if exists public.take_scan_token(text, text);

create or replace function public.take_scan_token(
  p_scan_token text,
  p_message    text,
  p_allow_gps  boolean default false
)
returns public.scan_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
begin
  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id is distinct from auth.uid()
     or v_token.consumed_at is not null
     or v_token.expires_at <= now()
     or (v_token.method = 'gps' and not coalesce(p_allow_gps, false)) then
    raise exception '%', p_message using errcode = 'NQ002';
  end if;

  return v_token;
end;
$$;

revoke all on function public.take_scan_token(text, text, boolean) from public, anon, authenticated;

-- Check-in: igual ao da Sprint 4, aceitando o botão "Entrando na quadra".
create or replace function public.check_in_and_start(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_token public.scan_tokens%rowtype;
  v_entry public.queue_entries%rowtype;
  v_match uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Confirme na quadra que você chegou', true);

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active and e.court_id = v_token.court_id;

  if not found then
    raise exception 'Você não está na fila desta quadra' using errcode = 'NQ007';
  end if;

  if v_entry.status <> 'playing' then
    if v_entry.status = 'ready'
       and v_entry.call_expires_at is not null
       and v_entry.call_expires_at <= now() then
      raise exception 'O tempo para o check-in terminou' using errcode = 'NQ016';
    end if;

    -- O turno anterior pode ter vencido sem o cron ter passado ainda.
    perform public.advance_court(v_entry.court_id);
    perform public.open_match(v_entry.id);
  end if;

  update public.queue_entry_members
     set checked_in_at = coalesce(checked_in_at, now())
   where entry_id = v_entry.id and user_id = v_user and is_active;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  select mt.id into v_match
  from public.matches mt
  where mt.ended_at is null and v_entry.id in (mt.side_a_entry_id, mt.side_b_entry_id);

  return case when v_match is null then public.queue_entry_state(v_entry.id)
              else public.match_state(v_match) end;
end;
$$;

-- ---------------------------------------------------------------------
-- Abrir a fila
-- ---------------------------------------------------------------------
create or replace function public.open_host_queue(
  p_scan_token      text,
  p_playing_minutes integer default null,
  p_waiting_labels  text[]  default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_token    public.scan_tokens%rowtype;
  v_court    public.courts%rowtype;
  v_session  uuid;
  v_entry_id uuid;
  v_waiting  integer := coalesce(cardinality(p_waiting_labels), 0);
  v_label    text;
  v_state    jsonb;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Confirme a sua localização na quadra para abrir a fila', true);

  -- A trava da quadra serializa duas aberturas ao mesmo tempo.
  select * into v_court from public.courts c where c.id = v_token.court_id for update;

  if not found or not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;
  if v_court.queue_mode <> 'host' then
    raise exception 'Esta quadra usa o QR Code da placa' using errcode = 'NQ030';
  end if;

  perform public.close_idle_host_sessions(v_court.id);

  if exists (select 1 from public.host_sessions s
             where s.court_id = v_court.id and s.closed_at is null) then
    raise exception 'Alguém já abriu a fila desta quadra. Peça o QR para quem está nela.'
      using errcode = 'NQ031';
  end if;

  v_state := public.player_state(v_user);
  if v_state ->> 'state' <> 'free' then
    raise exception 'Você já está na fila da %', v_state ->> 'court_name'
      using errcode = 'NQ014';
  end if;

  if v_waiting > 10 then
    raise exception 'Informe até 10 grupos esperando' using errcode = 'NQ032';
  end if;

  perform public.advance_court(v_court.id);

  if p_playing_minutes is not null then
    if p_playing_minutes < 1 or p_playing_minutes > v_court.slot_minutes then
      raise exception 'O turno em andamento vai de 1 a % minutos', v_court.slot_minutes
        using errcode = 'NQ032';
    end if;
    if exists (select 1 from public.matches mt
               where mt.court_id = v_court.id and mt.ended_at is null) then
      raise exception 'A quadra já tem um turno em andamento no app' using errcode = 'NQ032';
    end if;
  end if;

  insert into public.host_sessions
    (court_id, opened_by, host_user_id, playing_minutes, waiting_declared)
  values
    (v_court.id, v_user, v_user, p_playing_minutes, v_waiting)
  returning id into v_session;

  -- Quem já estava jogando: um turno sem app que acaba sozinho.
  if p_playing_minutes is not null then
    insert into public.queue_entries
      (court_id, created_by, status, is_offline, offline_kind, offline_label, host_session_id,
       called_at, started_at)
    values
      (v_court.id, v_user, 'playing', true, 'playing', 'Já estavam jogando', v_session, now(), now())
    returning id into v_entry_id;

    insert into public.matches (court_id, side_a_entry_id, mode, slot_minutes, expires_at)
    values (v_court.id, v_entry_id, 'single', v_court.slot_minutes,
            now() + make_interval(mins => p_playing_minutes));

    update public.courts set status = 'in_game', holder_entry_id = null where id = v_court.id;
  end if;

  -- Quem já esperava sem app: na frente do anfitrião, na ordem dada.
  if v_waiting > 0 then
    foreach v_label in array p_waiting_labels loop
      insert into public.queue_entries
        (court_id, created_by, is_offline, offline_kind, offline_label, host_session_id)
      values
        (v_court.id, v_user, true, 'waiting', nullif(left(trim(coalesce(v_label, '')), 40), ''), v_session);
    end loop;
  end if;

  -- A vaga do próprio anfitrião, depois de todos os declarados.
  insert into public.queue_entries (court_id, created_by, scan_token_id, host_session_id)
  values (v_court.id, v_user, v_token.id, v_session)
  returning id into v_entry_id;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role, joined_via)
  values (v_entry_id, v_court.id, v_user, 'owner', 'owner');

  insert into public.queue_entry_pins (entry_id, pin)
  values (v_entry_id, public.new_group_pin(v_court.id));

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry_id
   where id = v_token.id;

  perform public.call_next_team(v_court.id);

  return public.court_screen(v_court.id);
end;
$$;

-- ---------------------------------------------------------------------
-- O anfitrião e as vagas sem app
-- ---------------------------------------------------------------------

-- Quem chega sem app depois da abertura entra no fim da fila.
create or replace function public.host_add_offline(p_court_id uuid, p_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session uuid;
begin
  v_session := public.require_host(p_court_id);

  perform 1 from public.courts c where c.id = p_court_id for update;
  perform public.advance_court(p_court_id);

  insert into public.queue_entries
    (court_id, created_by, is_offline, offline_kind, offline_label, host_session_id)
  values
    (p_court_id, auth.uid(), true, 'waiting', nullif(left(trim(coalesce(p_label, '')), 40), ''), v_session);

  perform public.call_next_team(p_court_id);

  return public.court_screen(p_court_id);
end;
$$;

-- arrived: entraram na quadra · gave_up: desistiram · finished: saíram
create or replace function public.host_mark_offline(p_entry_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
  v_match uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found or not v_entry.is_offline then
    raise exception 'Vaga sem app não encontrada' using errcode = 'NQ007';
  end if;

  perform public.require_host(v_entry.court_id);

  if p_action = 'arrived' then
    if v_entry.status not in ('waiting', 'ready') then
      raise exception 'Esta vaga não está mais na fila' using errcode = 'NQ009';
    end if;
    perform public.advance_court(v_entry.court_id);
    perform public.open_match(v_entry.id);

  elsif p_action = 'gave_up' then
    if v_entry.status not in ('waiting', 'ready') then
      raise exception 'Esta vaga não está mais na fila' using errcode = 'NQ009';
    end if;
    update public.queue_entries
       set status = 'cancelled', left_at = now(), cancel_reason = 'offline_gave_up'
     where id = v_entry.id;
    if v_entry.status = 'ready' then
      perform public.call_next_team(v_entry.court_id);
    end if;

  elsif p_action = 'finished' then
    select mt.id into v_match
    from public.matches mt
    where mt.ended_at is null and mt.side_a_entry_id = v_entry.id;
    if v_match is null then
      raise exception 'Este grupo não está em quadra' using errcode = 'NQ009';
    end if;
    perform public.close_match(v_match, null, 'finished_by_group', auth.uid());

  else
    raise exception 'Ação desconhecida: %', p_action using errcode = 'NQ032';
  end if;

  return public.court_screen(v_entry.court_id);
end;
$$;

-- O grupo devolve a quadra; num turno sem app, quem devolve é o anfitrião.
create or replace function public.finish_my_turn(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_match   public.matches%rowtype;
  v_offline boolean;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    raise exception 'Este turno já foi encerrado' using errcode = 'NQ009';
  end if;

  select e.is_offline into v_offline from public.queue_entries e where e.id = v_match.side_a_entry_id;

  if v_offline and not public.is_staff() then
    perform public.require_host(v_match.court_id);
  elsif not v_offline
        and not public.is_entry_member(v_match.side_a_entry_id, v_user)
        and not public.is_staff() then
    raise exception 'Só quem está no grupo encerra o turno' using errcode = 'NQ008';
  end if;

  return public.close_match(p_match_id, null, 'finished_by_group', v_user);
end;
$$;

-- ---------------------------------------------------------------------
-- O QR na tela
-- ---------------------------------------------------------------------
create or replace function public.issue_host_invite(p_court_id uuid, p_display_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_court   public.courts%rowtype;
  v_session uuid;
  v_code    text;
  v_invite  public.host_invites%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;
  if p_display_id is null then
    raise exception 'Exibição do QR sem identificador' using errcode = 'NQ032';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id;
  if not found or v_court.queue_mode <> 'host' then
    raise exception 'Esta quadra usa o QR Code da placa' using errcode = 'NQ030';
  end if;

  v_session := public.current_host_session(p_court_id);
  if v_session is null then
    raise exception 'A fila desta quadra não está aberta' using errcode = 'NQ034';
  end if;

  -- Quem mostra já provou presença ao entrar: qualquer pessoa da fila.
  if not exists (
    select 1
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    where m.user_id = v_user and m.is_active
      and e.court_id = p_court_id
      and e.status in ('waiting', 'ready', 'playing')
  ) then
    raise exception 'Só quem está na fila desta quadra mostra o QR' using errcode = 'NQ008';
  end if;

  -- 18 bytes viram 24 caracteres de base64url, sem preenchimento.
  v_code := translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_');

  insert into public.host_invites (session_id, court_id, issued_by, display_id, code_hash, expires_at)
  values (v_session, p_court_id, v_user, p_display_id, public.hash_scan_token(v_code),
          now() + interval '10 minutes')
  returning * into v_invite;

  return jsonb_build_object(
    'code',           v_code,
    'invite_id',      v_invite.id,
    'expires_at',     v_invite.expires_at,
    'rotate_seconds', 30,
    'valid_seconds',  600
  );
end;
$$;

-- Aberto antes do login: só conta, não dá acesso a nada.
create or replace function public.host_invite_opened(p_code text, p_visitor text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.host_invites%rowtype;
begin
  if p_visitor is null or char_length(p_visitor) > 64 then
    return;
  end if;

  select * into v_invite
  from public.host_invites i
  where i.code_hash = public.hash_scan_token(p_code);

  if not found then
    return;
  end if;

  insert into public.pilot_events (court_id, invite_id, user_id, visitor, event)
  values (v_invite.court_id, v_invite.id, auth.uid(), p_visitor, 'invite_opened')
  on conflict do nothing;
end;
$$;

-- ---------------------------------------------------------------------
-- Leituras
-- ---------------------------------------------------------------------
create or replace function public.match_state(p_match_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match   public.matches%rowtype;
  v_court   public.courts%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_players jsonb;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id;
  select * into v_entry from public.queue_entries e where e.id = v_match.side_a_entry_id;

  v_players := public.match_side_players(v_match.side_a_entry_id);

  return jsonb_build_object(
    'match_id',      v_match.id,
    'court_id',      v_match.court_id,
    'court_name',    public.court_label(v_court.court_number),
    'entry_id',      v_match.side_a_entry_id,
    'players',       v_players,
    'group_size',    jsonb_array_length(v_players),
    'group_label',   case when v_entry.is_offline then 'Sem app'
                          else public.group_label(jsonb_array_length(v_players)) end,
    'is_offline',    coalesce(v_entry.is_offline, false),
    'offline_label', v_entry.offline_label,
    'slot_minutes',  v_match.slot_minutes,
    'started_at',    v_match.started_at,
    'expires_at',    v_match.expires_at,
    'ended_at',      v_match.ended_at,
    'end_reason',    v_match.end_reason,
    'is_live',       v_match.ended_at is null,
    'elapsed_seconds',   greatest(0, floor(extract(epoch from (
                           coalesce(v_match.ended_at, now()) - v_match.started_at)))::integer),
    'remaining_seconds', case
                           when v_match.ended_at is not null then 0
                           else greatest(0, floor(extract(epoch from (
                             v_match.expires_at - now())))::integer)
                         end
  );
end;
$$;

create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  q as (
    select qp.entry_id, qp.position, qp.status, qp.joined_at,
           e.call_expires_at, e.is_offline, e.offline_label,
           -- A raquete do grupo é a de quem está à frente dele. A vaga
           -- sem app não tem raquete: entra uma cinza na pilha.
           coalesce(
             (select jsonb_build_object(
                       'frame', pr.racket_frame_color,
                       'grip',  pr.racket_grip_color)
                from public.queue_entry_members mm
                join public.profiles pr on pr.id = mm.user_id
               where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
               limit 1),
             case when e.is_offline
                  then jsonb_build_object('frame', '#9AA39C', 'grip', '#F1ECEF') end
           ) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'group_size',  jsonb_array_length(q.players),
        'group_label', case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        -- Mantido para o app anterior à Sprint 4.
        'mode_label',  case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'is_offline',  q.is_offline,
        'offline_label', q.offline_label,
        'racket',      q.racket,
        'players',     q.players,
        -- "Ana S. + Bruno L. + 3": o nome de todo mundo não cabe na linha.
        'team_label',  case
          when q.is_offline then coalesce(q.offline_label, 'Grupo sem app')
          else (
            select string_agg(pl ->> 'short_name', ' + ' order by ord)
                     || case when jsonb_array_length(q.players) > 2
                             then ' + ' || (jsonb_array_length(q.players) - 2)
                             else '' end
            from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
            where ord <= 2
          )
        end,
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position and q2.racket is not null
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', coalesce((select remaining from court), 0)
                       + (q.position - 1) * (select slot_minutes from court) * 60
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;

create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_park    public.parks%rowtype;
  v_match   uuid;
  v_items   jsonb;
  v_queue   integer;
  v_rem     integer := 0;
  v_mine    jsonb;
  v_state   jsonb;
  v_group   jsonb;
  v_req     jsonb;
  v_live    jsonb;
  v_session public.host_sessions%rowtype;
  v_host_id uuid;
  v_host    jsonb;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select mt.id,
         greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
  into v_match, v_rem
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  v_live  := case when v_match is null then null else public.match_state(v_match) end;
  v_items := public.court_queue_items(p_court_id);
  v_queue := jsonb_array_length(v_items);

  select i into v_mine
  from jsonb_array_elements(v_items) i
  where (i ->> 'is_mine')::boolean
  limit 1;

  v_state := public.player_state(auth.uid());

  if (v_state ->> 'court_id')::uuid = p_court_id then
    v_group := public.my_group((v_state ->> 'entry_id')::uuid);
  end if;

  v_req := public.my_join_request();
  if (v_req ->> 'court_id')::uuid is distinct from p_court_id then
    v_req := null;
  end if;

  -- A fila com anfitrião: quem organiza e o que quem olha pode fazer.
  if v_court.queue_mode = 'host' then
    select * into v_session
    from public.host_sessions s
    where s.id = public.current_host_session(p_court_id);

    if v_session.id is not null then
      v_host_id := public.effective_host(p_court_id);
      v_host := jsonb_build_object(
        'session_id', v_session.id,
        'opened_at',  v_session.opened_at,
        'host_name',  (select public.short_name_of(coalesce(pr.full_name, pr.username::text))
                         from public.profiles pr where pr.id = v_host_id),
        'is_me',      v_host_id is not null and v_host_id = auth.uid(),
        'can_show_invite', v_group is not null
      );
    end if;
  end if;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',            v_court.id,
      'name',          public.court_label(v_court.court_number),
      'number',        v_court.court_number,
      'surface',       v_court.surface,
      'surface_label', case v_court.surface
                         when 'clay'  then 'Saibro'
                         when 'hard'  then 'Rápida'
                         else 'Grama'
                       end,
      'status',        v_court.status,
      'is_active',     v_court.is_active,
      'slot_minutes',  v_court.slot_minutes,
      'call_window_seconds', v_court.call_window_seconds,
      'queue_mode',    v_court.queue_mode,
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code and v_court.queue_mode = 'fixed_qr'
          union all
          select 'nfc'::text where v_court.has_nfc_tag and v_court.queue_mode = 'fixed_qr'
          union all
          select 'gps'::text where v_court.queue_mode = 'host'
        ) s
      ),
      'latitude',      v_court.latitude,
      'longitude',     v_court.longitude,
      'rating_avg',    v_court.rating_avg,
      'rating_count',  v_court.rating_count,
      'cover_photo_path', v_court.cover_photo_path
    ),
    'park', jsonb_build_object(
      'id',       v_park.id,
      'name',     v_park.name,
      'district', v_park.district
    ),
    'match',        v_live,
    'is_live',      v_match is not null,
    'status_text',  case when v_match is not null then 'Em jogo' else 'Livre' end,
    'players_line', case
                      when v_match is null then 'Sem jogo agora — check-in libera a quadra'
                      when (v_live ->> 'is_offline')::boolean
                        then coalesce(v_live ->> 'offline_label', 'Grupo sem app')
                      else (
                        select coalesce(string_agg(pl ->> 'short_name', ' · ' order by ord), 'Grupo em quadra')
                        from jsonb_array_elements(v_live -> 'players') with ordinality as t(pl, ord)
                      )
                    end,
    'queue',        v_items,
    'queue_length', v_queue,
    'queue_text',   case
                      when v_queue = 0 then 'Fila vazia'
                      else v_queue || ' na espera'
                    end,
    'remaining_seconds', coalesce(v_rem, 0),
    'total_wait_seconds', coalesce(v_rem, 0) + v_queue * v_court.slot_minutes * 60,
    'next_position_label', (v_queue + 1) || 'º',
    'my_entry',     v_mine,
    'my_group',     v_group,
    'my_request',   v_req,
    'host',         v_host,
    'can_open_host', v_court.queue_mode = 'host'
                     and v_host is null
                     and v_court.is_active
                     and v_court.status <> 'unavailable'
                     and (v_state ->> 'state') = 'free',
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (v_state ->> 'state') = 'free'
                    and (v_court.queue_mode = 'fixed_qr' or v_host is not null),
    'my_state',     v_state,
    'generated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- A rotina de minuto em minuto também fecha a fila esquecida
-- ---------------------------------------------------------------------
create or replace function public.advance_expired_queues()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    record;
  v_result   jsonb;
  v_closed   integer := 0;
  v_expired  integer := 0;
  v_requests integer;
  v_sessions integer;
begin
  for v_court in
    select distinct court_id from (
      select court_id from public.matches
      where ended_at is null and expires_at <= now()
      union all
      select court_id from public.queue_entries
      where status = 'ready' and call_expires_at is not null and call_expires_at <= now()
    ) s
  loop
    v_result  := public.advance_court(v_court.court_id);
    v_closed  := v_closed + (v_result ->> 'matches_closed')::integer;
    v_expired := v_expired + (v_result ->> 'entries_expired')::integer;
  end loop;

  -- Pedido que ninguém respondeu, ou de um grupo que já saiu da fila.
  update public.queue_join_requests r
     set status = 'expired', decided_at = now()
   where r.status = 'pending'
     and (r.expires_at <= now()
          or not exists (select 1 from public.queue_entries e
                         where e.id = r.entry_id
                           and e.status in ('waiting', 'ready', 'playing')));
  get diagnostics v_requests = row_count;

  v_sessions := public.close_idle_host_sessions();

  return jsonb_build_object(
    'matches_closed',   v_closed,
    'entries_expired',  v_expired,
    'requests_expired', v_requests,
    'sessions_closed',  v_sessions,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.advance_expired_queues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Administração: o modo no formulário da quadra
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'address',   pk.address,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'address',       c.address,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'call_window_seconds', c.call_window_seconds,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
                'queue_mode',    c.queue_mode,
                'host_session_open', public.current_host_session(c.id) is not null,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_address      text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null,
  p_queue_mode           text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     public.courts;
  v_before  public.courts;
  v_park    public.parks;
  v_number  smallint;
  v_name    text;
  v_session uuid;
begin
  perform public.require_admin();

  if p_queue_mode is not null and p_queue_mode not in ('fixed_qr', 'host') then
    raise exception 'Modo de fila desconhecido: %', p_queue_mode using errcode = 'NQ032';
  end if;

  if p_id is not null then
    select * into v_before from public.courts where id = p_id;
  end if;

  -- O banco recusaria pela constraint; aqui a mensagem diz o porquê.
  if coalesce(p_queue_mode, v_before.queue_mode, 'fixed_qr') = 'host'
     and not coalesce(p_enforce_proximity, v_before.enforce_proximity, true) then
    raise exception 'No modo anfitrião, a conferência de distância não pode ser desligada: '
                    'sem ela, o print do QR funcionaria de casa.'
      using errcode = 'NQ035';
  end if;

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      address, latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds,
      queue_mode
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(nullif(trim(p_address), ''), v_park.address),
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120),
      coalesce(p_queue_mode, 'fixed_qr')
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      address      = coalesce(nullif(trim(p_address), ''), address),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds),
      queue_mode           = coalesce(p_queue_mode, queue_mode)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;

    -- Saiu do modo anfitrião (a placa chegou): a fila aberta fecha, e as
    -- vagas sem app que esperavam saem com ela — sem anfitrião, ninguém
    -- teria como andar com elas.
    if v_before.queue_mode = 'host' and v_row.queue_mode <> 'host' then
      for v_session in
        select s.id from public.host_sessions s where s.court_id = v_row.id and s.closed_at is null
      loop
        perform public.close_host_session(v_session, 'mode_changed');
      end loop;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer, text
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer, text
) to authenticated;

-- ---------------------------------------------------------------------
-- O painel do piloto
--
-- Contagens, não nomes: é o que vai na tela para a organização do
-- parque. Os dias são os de São Paulo.
-- ---------------------------------------------------------------------
create or replace function public.admin_pilot_stats(
  p_park_id uuid default null,
  p_from    date default null,
  p_to      date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz    constant text := 'America/Sao_Paulo';
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_from  date;
  v_to    date;
  v_start timestamptz;
  v_end   timestamptz;
begin
  perform public.require_admin();

  v_to    := coalesce(p_to, v_today);
  v_from  := coalesce(p_from, v_to - 29);
  if v_from > v_to then
    raise exception 'O período começa depois de terminar' using errcode = 'NQ032';
  end if;
  if v_to - v_from > 366 then
    raise exception 'O período vai até um ano' using errcode = 'NQ032';
  end if;

  v_start := v_from::timestamp at time zone v_tz;
  v_end   := (v_to + 1)::timestamp at time zone v_tz;

  return (
    with courts as (
      select c.id, c.court_number, c.park_id, pk.name as park_name
      from public.courts c
      join public.parks pk on pk.id = c.park_id
      where p_park_id is null or c.park_id = p_park_id
    ),
    entries as (
      select e.*
      from public.queue_entries e
      join courts c on c.id = e.court_id
      where e.joined_at >= v_start and e.joined_at < v_end
    ),
    members as (
      select m.*, e.joined_at as entry_joined_at
      from public.queue_entry_members m
      join entries e on e.id = m.entry_id
      where not e.is_offline
    ),
    invites as (
      select i.*
      from public.host_invites i
      join courts c on c.id = i.court_id
      where i.issued_at >= v_start and i.issued_at < v_end
    ),
    events as (
      select ev.*
      from public.pilot_events ev
      join courts c on c.id = ev.court_id
      where ev.created_at >= v_start and ev.created_at < v_end
    ),
    turns as (
      select mt.*, e.is_offline
      from public.matches mt
      join courts c on c.id = mt.court_id
      join public.queue_entries e on e.id = mt.side_a_entry_id
      where mt.started_at >= v_start and mt.started_at < v_end
    ),
    waits as (
      select extract(epoch from (e.started_at - e.joined_at)) / 60.0 as minutes
      from entries e
      where not e.is_offline and e.started_at is not null
    ),
    invite_joins as (
      select m.user_id, i.issued_by, i.issued_at
      from members m
      join public.host_invites i on i.id = m.invite_id
      where m.origin = 'host_invite'
    ),
    spreaders as (
      select issued_by, count(distinct user_id) as brought
      from invite_joins
      group by issued_by
    )
    select jsonb_build_object(
      'period', jsonb_build_object('from', v_from, 'to', v_to),
      'totals', jsonb_build_object(
        'people',          (select count(distinct user_id) from members),
        'app_entries',     (select count(*) from entries where not is_offline),
        'offline_entries', (select count(*) from entries where is_offline
                              and offline_kind = 'waiting'),
        'sessions',        (select count(*) from public.host_sessions s
                              join courts c on c.id = s.court_id
                             where s.opened_at >= v_start and s.opened_at < v_end),
        'turns',           (select count(*) from turns where not is_offline),
        'hours_played',    round(coalesce((
                             select sum(extract(epoch from (least(coalesce(ended_at, now()), expires_at) - started_at)))
                             from turns
                           ), 0)::numeric / 3600, 1)
      ),
      'daily', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'day',             d.day,
                 'people',          (select count(distinct m.user_id) from members m
                                      where (m.entry_joined_at at time zone v_tz)::date = d.day),
                 'app_entries',     (select count(*) from entries e
                                      where not e.is_offline and (e.joined_at at time zone v_tz)::date = d.day),
                 'offline_entries', (select count(*) from entries e
                                      where e.is_offline and e.offline_kind = 'waiting'
                                        and (e.joined_at at time zone v_tz)::date = d.day)
               ) order by d.day), '[]'::jsonb)
        from (select generate_series(v_from, v_to, interval '1 day')::date as day) d
      ),
      'origins', (
        select coalesce(jsonb_object_agg(origin, n), '{}'::jsonb)
        from (select coalesce(origin, 'unknown') as origin, count(*) as n from members group by 1) o
      ),
      'funnel', jsonb_build_object(
        'shown',        (select count(distinct display_id) from invites),
        'opened',       (select count(distinct visitor) from events where event = 'invite_opened'),
        'scanned',      (select count(distinct user_id) from events where event = 'invite_scanned'),
        'too_far',      (select count(*) from events where event = 'invite_too_far'),
        'new_accounts', (select count(distinct ev.user_id)
                           from events ev
                           join auth.users u on u.id = ev.user_id
                           join public.host_invites i on i.id = ev.invite_id
                          where ev.event = 'invite_scanned' and u.created_at >= i.issued_at),
        'joined',       (select count(distinct user_id) from invite_joins)
      ),
      'wait', jsonb_build_object(
        'samples',    (select count(*) from waits),
        'median_min', (select round(percentile_cont(0.5) within group (order by minutes)::numeric, 1) from waits),
        'p90_min',    (select round(percentile_cont(0.9) within group (order by minutes)::numeric, 1) from waits)
      ),
      'by_hour', (
        select coalesce(jsonb_agg(jsonb_build_object('hour', h.hour, 'turns', h.turns) order by h.hour), '[]'::jsonb)
        from (
          select g.hour,
                 (select count(*) from turns t
                   where extract(hour from (t.started_at at time zone v_tz)) = g.hour) as turns
          from generate_series(0, 23) as g(hour)
        ) h
      ),
      'calls', jsonb_build_object(
        'called', (select count(*) from entries where not is_offline and called_at is not null),
        'missed', (select count(*) from entries where not is_offline and cancel_reason = 'no_show')
      ),
      'offline_hold', jsonb_build_object(
        'samples', (select count(*) from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting'),
        'avg_min', (select round(avg(extract(epoch from (coalesce(started_at, left_at) - called_at)) / 60.0)::numeric, 1)
                      from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting'),
        'max_min', (select round(max(extract(epoch from (coalesce(started_at, left_at) - called_at)) / 60.0)::numeric, 1)
                      from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting')
      ),
      'spreaders', jsonb_build_object(
        'people', (select count(*) from spreaders),
        'top',    (select coalesce(jsonb_agg(s.brought order by s.brought desc), '[]'::jsonb)
                     from (select brought from spreaders order by brought desc limit 5) s)
      ),
      'courts', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'court_id',        c.id,
                 'label',           c.park_name || ' · ' || public.court_label(c.court_number),
                 'people',          (select count(distinct m.user_id) from members m where m.court_id = c.id),
                 'app_entries',     (select count(*) from entries e where e.court_id = c.id and not e.is_offline),
                 'offline_entries', (select count(*) from entries e where e.court_id = c.id and e.is_offline
                                       and e.offline_kind = 'waiting')
               ) order by c.park_name, c.court_number), '[]'::jsonb)
        from courts c
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
grant execute on function public.open_host_queue(text, integer, text[]) to authenticated;
grant execute on function public.host_add_offline(uuid, text)           to authenticated;
grant execute on function public.host_mark_offline(uuid, text)          to authenticated;
grant execute on function public.issue_host_invite(uuid, uuid)          to authenticated;
grant execute on function public.host_invite_opened(text, text)         to anon, authenticated;
grant execute on function public.check_in_and_start(text)               to authenticated;
grant execute on function public.finish_my_turn(uuid)                   to authenticated;
grant execute on function public.admin_pilot_stats(uuid, date, date)    to authenticated;
