-- =====================================================================
-- NEQST — Sprint 4
-- 26. A vaga na fila é de um grupo, e cada um prova que está lá
--
-- O modelo da Sprint 3 era "lado A × lado B, quem ganha fica": cada
-- inscrição era um time de 1 ou 2 e o adversário vinha da fila. Nos
-- parques não é assim. Quem entra na quadra é um grupo de conhecidos
-- que joga entre si — dois no simples, quatro nas duplas, às vezes
-- cinco revezando — e cada vaga da fila vale um turno fixo de quadra.
--
--   1. Uma pessoa abre a vaga sozinha e guarda o lugar.
--   2. Os amigos entram nessa mesma vaga escaneando o QR da quadra:
--      pedindo para entrar (o dono aprova) ou digitando o PIN do grupo.
--      Vale até o fim do turno — quem chega atrasado entra com o jogo
--      rolando, e o relógio não para.
--   3. Uma pessoa, uma vaga. Quem já está em outra fila precisa sair
--      dela para entrar no grupo do amigo.
--   4. Chamado o grupo, a tolerância para o check-in é curta (2 min,
--      ajustável pelo admin). Basta um check-in para o turno começar.
--   5. Não há vencedor nem adversário: o turno acaba no fim do slot, ou
--      antes, se o grupo devolver a quadra.
--   6. A vaga não se perde enquanto houver alguém nela. Saiu o dono,
--      outro membro herda; saíram todos, a vez passa.
--
-- O furo que o pedido de entrada fecha: sem aprovação, qualquer pessoa
-- que escaneasse o QR escolheria o grupo do 1º da fila e passaria na
-- frente de todo mundo.
--
-- Códigos novos:
--   NQ027 pedido de entrada não encontrado ou não está mais pendente
--   NQ028 muitas tentativas de PIN
--   NQ029 parceiro não é mais adicionado pelo @ — ele escaneia a quadra
--
-- A tabela matches continua: uma linha agora é o turno de um grupo
-- (side_a_entry_id). O lado B, o vencedor e o mandante deixam de ser
-- usados, mas as colunas ficam para o histórico já gravado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sem limite de pessoas por vaga
-- ---------------------------------------------------------------------
drop trigger if exists queue_entry_members_team_size on public.queue_entry_members;
drop function if exists public.enforce_queue_team_size();

comment on table public.queue_entry_members is
  'Pessoas de um grupo na fila. Sem limite de tamanho: o turno é fixo, quantos forem.';
comment on column public.queue_entries.mode is
  'Legado (Sprint 1-3). A vaga é de um grupo de qualquer tamanho; o campo não decide nada.';

alter table public.queue_entry_members
  add column if not exists joined_via    text,
  add column if not exists checked_in_at timestamptz,
  add column if not exists left_at       timestamptz;

do $$ begin
  alter table public.queue_entry_members
    add constraint queue_entry_members_joined_via_check
    check (joined_via is null or joined_via in ('owner', 'approval', 'pin', 'partner'));
exception when duplicate_object then null; end $$;

comment on column public.queue_entry_members.joined_via is
  'Como entrou: abriu a vaga (owner), foi aprovado (approval) ou usou o PIN (pin). '
  '"partner" é o parceiro adicionado pelo @ antes da Sprint 4.';
comment on column public.queue_entry_members.checked_in_at is
  'Quando escaneou a quadra para jogar. Quem entra com o turno rolando já chega com check-in.';
comment on column public.queue_entry_members.left_at is
  'Saiu do grupo com o turno em andamento. Quem sai antes do turno é removido do grupo.';

update public.queue_entry_members
   set joined_via = case when role = 'owner' then 'owner' else 'partner' end
 where joined_via is null;

-- ---------------------------------------------------------------------
-- 2. PIN do grupo
--
-- Mostrado só para quem está no grupo; quem tem o PIN e escaneia a
-- quadra entra sem esperar aprovação. É o que resolve o amigo que chega
-- com o jogo rolando: o dono está em quadra e não vai olhar o celular.
--
-- Fica numa tabela à parte porque queue_entries é legível por qualquer
-- pessoa logada (e passa pelo Realtime). Cada vaga tem o seu — um PIN
-- que vazou num grupo de WhatsApp na semana passada não serve hoje.
-- ---------------------------------------------------------------------
create table if not exists public.queue_entry_pins (
  entry_id   uuid primary key references public.queue_entries (id) on delete cascade,
  pin        text not null check (pin ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);

comment on table public.queue_entry_pins is
  'PIN de 4 dígitos de cada vaga. Sem acesso direto do cliente: só sai pelas RPCs, para os membros.';

alter table public.queue_entry_pins enable row level security;
revoke all on public.queue_entry_pins from anon, authenticated;

create or replace function public.new_group_pin(p_court_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pin text;
begin
  -- Único entre as vagas ativas da quadra: o PIN é procurado por quadra.
  for i in 1..50 loop
    v_pin := lpad((floor(random() * 10000))::integer::text, 4, '0');
    exit when not exists (
      select 1
      from public.queue_entry_pins p
      join public.queue_entries e on e.id = p.entry_id
      where e.court_id = p_court_id
        and e.status in ('waiting', 'ready', 'playing')
        and p.pin = v_pin
    );
  end loop;
  return v_pin;
end;
$$;

revoke all on function public.new_group_pin(uuid) from public, anon, authenticated;

-- Tentativas de PIN: cada uma exige um scan novo na quadra, e um erro
-- a mais que o limite trava por 15 minutos.
create table if not exists public.queue_pin_attempts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  court_id   uuid not null references public.courts (id) on delete cascade,
  entry_id   uuid references public.queue_entries (id) on delete set null,
  success    boolean not null,
  created_at timestamptz not null default now()
);

create index if not exists queue_pin_attempts_user_idx
  on public.queue_pin_attempts (user_id, created_at desc);

alter table public.queue_pin_attempts enable row level security;
revoke all on public.queue_pin_attempts from anon, authenticated;

-- Vagas que já estavam na fila ganham o seu.
insert into public.queue_entry_pins (entry_id, pin)
select e.id, public.new_group_pin(e.court_id)
from public.queue_entries e
where e.status in ('waiting', 'ready', 'playing')
on conflict (entry_id) do nothing;

-- ---------------------------------------------------------------------
-- 3. Pedido para entrar num grupo
-- ---------------------------------------------------------------------
create table if not exists public.queue_join_requests (
  id            uuid primary key default gen_random_uuid(),
  entry_id      uuid not null references public.queue_entries (id) on delete cascade,
  court_id      uuid not null references public.courts (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  scan_token_id uuid references public.scan_tokens (id) on delete set null,
  status        public.join_request_status not null default 'pending',
  leave_current boolean not null default false,
  expires_at    timestamptz not null,
  decided_at    timestamptz,
  decided_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default clock_timestamp()
);

comment on table public.queue_join_requests is
  'Quem escaneou a quadra e pediu para entrar no grupo de alguém. O dono do grupo aprova.';
comment on column public.queue_join_requests.leave_current is
  'Quem pediu estava em outra fila e confirmou que sai dela. Sai só quando for aceito.';

-- Um pedido pendente por pessoa: pedir outro cancela o anterior.
create unique index if not exists queue_join_requests_one_pending_per_user
  on public.queue_join_requests (user_id)
  where status = 'pending';

create index if not exists queue_join_requests_entry_idx
  on public.queue_join_requests (entry_id)
  where status = 'pending';

create index if not exists queue_join_requests_expiry_idx
  on public.queue_join_requests (expires_at)
  where status = 'pending';

alter table public.queue_join_requests enable row level security;

-- Quem pediu e quem está no grupo enxergam o pedido. É o que deixa o
-- Realtime avisar o dono na hora.
create or replace function public.is_entry_member(p_entry_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = p_entry_id and m.user_id = p_user_id and m.is_active
  );
$$;

grant execute on function public.is_entry_member(uuid, uuid) to authenticated;

drop policy if exists "pedidos: quem pediu e o grupo leem" on public.queue_join_requests;
create policy "pedidos: quem pediu e o grupo leem"
  on public.queue_join_requests for select
  to authenticated
  using (user_id = auth.uid() or public.is_entry_member(entry_id, auth.uid()));

revoke all on public.queue_join_requests from anon, authenticated;
grant select on public.queue_join_requests to authenticated;

alter table public.queue_join_requests replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_join_requests'
  ) then
    alter publication supabase_realtime add table public.queue_join_requests;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Tolerância do check-in: 2 minutos, ajustável por quadra
-- ---------------------------------------------------------------------
alter table public.courts alter column call_window_seconds set default 120;

-- Só muda quem ainda estava no padrão antigo: um valor que o admin
-- escolheu continua valendo.
update public.courts set call_window_seconds = 120 where call_window_seconds = 300;

comment on column public.courts.call_window_seconds is
  'Tolerância para o check-in depois de chamado. Padrão 120s; o admin ajusta por quadra.';

-- ---------------------------------------------------------------------
-- Notificações
-- ---------------------------------------------------------------------

-- Só para quem continua no grupo.
create or replace function public.enqueue_team_notification(
  p_entry_id uuid,
  p_type     public.notification_type,
  p_title    text,
  p_body     text,
  p_data     jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted integer;
begin
  insert into public.notification_outbox (user_id, entry_id, court_id, type, title, body, data)
  select m.user_id, m.entry_id, m.court_id, p_type, p_title, p_body, p_data
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.is_active
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

-- Para uma pessoa só. Sem entry_id de propósito: a deduplicação por
-- (entry_id, user_id, type) engoliria o segundo pedido para o mesmo
-- dono.
create or replace function public.enqueue_user_notification(
  p_user_id  uuid,
  p_court_id uuid,
  p_type     public.notification_type,
  p_title    text,
  p_body     text,
  p_data     jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notification_outbox (user_id, court_id, type, title, body, data)
  values (p_user_id, p_court_id, p_type, p_title, p_body, p_data);
$$;

revoke all on function public.enqueue_user_notification(uuid, uuid, public.notification_type, text, text, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Rótulo do grupo
-- ---------------------------------------------------------------------
create or replace function public.group_label(p_size integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_size, 0) <= 1 then 'Solo'
    when p_size = 2 then 'Dupla'
    else p_size || ' jogadores'
  end;
$$;

grant execute on function public.group_label(integer) to anon, authenticated;

-- Quem está no grupo. Numa vaga ativa, só quem continua nela; num turno
-- encerrado, todo mundo que jogou.
create or replace function public.match_side_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',    m.user_id,
        'username',   p.username,
        'full_name',  p.full_name,
        'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
        'short_name', public.short_name_of(coalesce(p.full_name, p.username::text)),
        'role',       m.role,
        'checked_in', m.checked_in_at is not null
      )
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id
    and (m.is_active or e.status not in ('waiting', 'ready', 'playing'));
$$;

create or replace function public.queue_entry_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',    m.user_id,
        'role',       m.role,
        'username',   p.username,
        'full_name',  p.full_name,
        'avatar_url', p.avatar_url
      )
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id
    and (m.is_active or e.status not in ('waiting', 'ready', 'playing'));
$$;

-- ---------------------------------------------------------------------
-- Encerrar o turno (uso interno)
--
-- Sem vencedor: o grupo sai e o próximo da fila é chamado. p_winner
-- fica na assinatura só para não quebrar quem já chama a função.
-- ---------------------------------------------------------------------
create or replace function public.close_match(
  p_match_id uuid,
  p_winner   public.match_side,
  p_reason   public.match_end_reason,
  p_reporter uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    return public.match_state(p_match_id);
  end if;

  update public.matches
     set ended_at    = now(),
         winner_side = null,
         end_reason  = p_reason,
         reported_by = p_reporter
   where id = p_match_id;

  -- O lado B só existe em turnos gravados antes da Sprint 4.
  update public.queue_entries
     set status = 'done', ended_at = now()
   where id in (v_match.side_a_entry_id, v_match.side_b_entry_id)
     and status = 'playing';

  update public.courts
     set holder_entry_id = null,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = v_match.court_id;

  update public.queue_join_requests
     set status = 'expired', decided_at = now()
   where status = 'pending'
     and entry_id in (v_match.side_a_entry_id, v_match.side_b_entry_id);

  -- Com a quadra livre, o próximo grupo é chamado na hora.
  perform public.call_next_team(v_match.court_id);

  return public.match_state(p_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Abrir o turno: o grupo da vez, sem adversário
-- ---------------------------------------------------------------------
create or replace function public.open_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry    public.queue_entries%rowtype;
  v_court    public.courts%rowtype;
  v_first    uuid;
  v_live     public.matches%rowtype;
  v_match_id uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não pode iniciar o turno agora' using errcode = 'NQ009';
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id for update;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  select qp.entry_id into v_first
  from public.queue_positions qp
  where qp.court_id = v_court.id
  order by qp.position
  limit 1;

  if v_first is distinct from v_entry.id then
    raise exception 'Ainda não é a vez do seu grupo' using errcode = 'NQ015';
  end if;

  select * into v_live
  from public.matches mt
  where mt.court_id = v_court.id and mt.ended_at is null
  for update;

  if found then
    if v_live.expires_at > now() then
      raise exception 'A quadra está ocupada por mais % minuto(s)',
        greatest(1, ceil(extract(epoch from (v_live.expires_at - now())) / 60)::integer)
        using errcode = 'NQ017';
    end if;
    perform public.close_match(v_live.id, null, 'slot_expired');
  end if;

  insert into public.matches
    (court_id, side_a_entry_id, side_b_entry_id, mode, slot_minutes, expires_at)
  values
    (v_court.id, v_entry.id, null, v_entry.mode, v_court.slot_minutes,
     now() + make_interval(mins => v_court.slot_minutes))
  returning id into v_match_id;

  update public.queue_entries
     set status = 'playing', called_at = coalesce(called_at, now()), started_at = now()
   where id = v_entry.id;

  update public.courts set status = 'in_game', holder_entry_id = null where id = v_court.id;

  return public.match_state(v_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Andar a fila de uma quadra: turno vencido sai, chamada não atendida
-- perde a vez. Roda antes do check-in e da entrada na fila — com uma
-- tolerância de 2 minutos, esperar o cron de 15 em 15 deixaria a quadra
-- parada. advance_expired_queues() deve ser agendada a cada minuto
-- (docs/deploy.md), para o "É a sua vez!" do próximo sair sozinho.
-- ---------------------------------------------------------------------
create or replace function public.advance_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match   record;
  v_entry   record;
  v_closed  integer := 0;
  v_expired integer := 0;
begin
  for v_match in
    select id from public.matches
    where court_id = p_court_id and ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  for v_entry in
    select e.id
    from public.queue_entries e
    where e.court_id = p_court_id
      and e.status = 'ready'
      and e.call_expires_at is not null
      and e.call_expires_at <= now()
    order by e.queue_number
  loop
    update public.queue_entries
       set status = 'expired', cancel_reason = 'no_show', left_at = now()
     where id = v_entry.id and status = 'ready';

    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = v_entry.id;

    perform public.call_next_team(p_court_id);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('matches_closed', v_closed, 'entries_expired', v_expired);
end;
$$;

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

  return jsonb_build_object(
    'matches_closed',   v_closed,
    'entries_expired',  v_expired,
    'requests_expired', v_requests,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.advance_court(uuid)      from public, anon, authenticated;
revoke all on function public.advance_expired_queues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Sair do grupo (uso interno)
--
-- Antes do turno, quem sai deixa de fazer parte do grupo. Com o turno
-- rolando, fica registrado que jogou. A vaga só some quando sai o
-- último; saindo o dono, o membro mais antigo herda.
-- ---------------------------------------------------------------------
create or replace function public.leave_entry(
  p_entry_id uuid,
  p_user_id  uuid,
  p_reason   text default 'left_by_user'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry     public.queue_entries%rowtype;
  v_member    public.queue_entry_members%rowtype;
  v_remaining integer;
  v_heir      uuid;
  v_match     uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready', 'playing') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  select * into v_member
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.user_id = p_user_id and m.is_active
  for update;

  if not found then
    raise exception 'Você não faz parte deste grupo' using errcode = 'NQ008';
  end if;

  if v_entry.status = 'playing' then
    update public.queue_entry_members
       set is_active = false, left_at = now()
     where id = v_member.id;
  else
    delete from public.queue_entry_members where id = v_member.id;
  end if;

  select count(*)::integer into v_remaining
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.is_active;

  if v_remaining = 0 then
    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = p_entry_id;

    if v_entry.status = 'playing' then
      select mt.id into v_match
      from public.matches mt
      where mt.ended_at is null
        and p_entry_id in (mt.side_a_entry_id, mt.side_b_entry_id);

      if v_match is not null then
        perform public.close_match(v_match, null, 'abandoned', p_user_id);
      else
        update public.queue_entries set status = 'done', ended_at = now() where id = p_entry_id;
      end if;
    else
      update public.queue_entries
         set status = 'cancelled', left_at = now(), cancel_reason = coalesce(p_reason, 'left_by_user')
       where id = p_entry_id;

      -- Era a vez deste grupo: a vez passa agora, sem esperar o prazo.
      if v_entry.status = 'ready' then
        perform public.call_next_team(v_entry.court_id);
      end if;
    end if;
  elsif v_member.role = 'owner' then
    select m.id into v_heir
    from public.queue_entry_members m
    where m.entry_id = p_entry_id and m.is_active
    order by m.created_at
    limit 1;

    update public.queue_entry_members set role = 'owner' where id = v_heir;
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id;

  return jsonb_build_object(
    'entry_id',          p_entry_id,
    'status',            v_entry.status,
    'left_at',           now(),
    'remaining_members', v_remaining
  );
end;
$$;

revoke all on function public.leave_entry(uuid, uuid, text) from public, anon, authenticated;

-- Sair da fila: agora sai quem pediu, não o grupo inteiro.
create or replace function public.leave_queue(
  p_entry_id uuid,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_entry public.queue_entries%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if public.is_entry_member(p_entry_id, v_user) then
    return public.leave_entry(p_entry_id, v_user, coalesce(p_reason, 'left_by_user'));
  end if;

  -- A operação do parque ainda pode tirar um grupo inteiro da fila.
  if not public.is_staff() then
    raise exception 'Você não faz parte deste grupo' using errcode = 'NQ008';
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  update public.queue_entries
     set status = 'cancelled', left_at = now(), cancel_reason = coalesce(p_reason, 'removed_by_staff')
   where id = p_entry_id;

  if v_entry.status = 'ready' then
    perform public.call_next_team(v_entry.court_id);
  end if;

  return jsonb_build_object('entry_id', p_entry_id, 'status', 'cancelled', 'left_at', now(),
                            'remaining_members', 0);
end;
$$;

-- ---------------------------------------------------------------------
-- Prova de presença: o scan token, igual para todas as entradas
-- ---------------------------------------------------------------------
create or replace function public.take_scan_token(p_scan_token text, p_message text)
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
     or v_token.expires_at <= now() then
    raise exception '%', p_message using errcode = 'NQ002';
  end if;

  return v_token;
end;
$$;

revoke all on function public.take_scan_token(text, text) from public, anon, authenticated;

-- Quem já está em outra fila precisa sair dela para entrar no grupo. Sem
-- p_leave_current, a chamada é recusada com o aviso (NQ014); o app
-- pergunta e repete com a confirmação. Com p_leave_now = false só
-- confere — é o pedido de entrada, que sai da fila antiga apenas quando
-- for aceito.
create or replace function public.free_player_for(
  p_user_id       uuid,
  p_target_entry  uuid,
  p_leave_current boolean,
  p_leave_now     boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
begin
  v_state := public.player_state(p_user_id);

  if v_state ->> 'state' = 'free' then
    return;
  end if;

  if (v_state ->> 'entry_id')::uuid = p_target_entry then
    raise exception 'Você já está neste grupo' using errcode = 'NQ004';
  end if;

  if not coalesce(p_leave_current, false) then
    raise exception 'Para entrar neste grupo, saia da sua fila atual (%).',
      lower(coalesce(v_state ->> 'where', 'outra quadra'))
      using errcode = 'NQ014';
  end if;

  if coalesce(p_leave_now, true) then
    perform public.leave_entry((v_state ->> 'entry_id')::uuid, p_user_id, 'switched_group');
  end if;
end;
$$;

revoke all on function public.free_player_for(uuid, uuid, boolean, boolean) from public, anon, authenticated;

-- Coloca a pessoa no grupo (aprovada ou pelo PIN).
create or replace function public.add_group_member(
  p_entry_id uuid,
  p_user_id  uuid,
  p_via      text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id;

  -- Quem entra com o turno rolando está na quadra: o scan que fez para
  -- entrar já é o check-in.
  insert into public.queue_entry_members
    (entry_id, court_id, user_id, role, joined_via, checked_in_at)
  values
    (p_entry_id, v_entry.court_id, p_user_id, 'partner', p_via,
     case when v_entry.status = 'playing' then now() end)
  on conflict (entry_id, user_id) do update
    set is_active     = true,
        left_at       = null,
        role          = 'partner',
        joined_via    = excluded.joined_via,
        checked_in_at = coalesce(public.queue_entry_members.checked_in_at, excluded.checked_in_at);

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = p_user_id and entry_id <> p_entry_id;
end;
$$;

revoke all on function public.add_group_member(uuid, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Abrir uma vaga na fila
--
-- A assinatura antiga continua aceita (o app em produção ainda manda
-- p_mode), mas o parceiro pelo @ acabou: ele não provava que a pessoa
-- estava na quadra.
-- ---------------------------------------------------------------------
create or replace function public.join_queue(
  p_scan_token text,
  p_mode       public.queue_mode default 'single',
  p_partner    text default null
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
  v_entry_id uuid;
  v_state    jsonb;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if nullif(trim(coalesce(p_partner, '')), '') is not null then
    raise exception 'O parceiro entra escaneando a quadra e pedindo para entrar no seu grupo'
      using errcode = 'NQ029';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra novamente para entrar na fila');

  select * into v_court from public.courts c where c.id = v_token.court_id for update;

  if not found or not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  v_state := public.player_state(v_user);

  if v_state ->> 'state' <> 'free' then
    if (v_state ->> 'court_id')::uuid = v_court.id then
      raise exception 'Você já está nesta fila' using errcode = 'NQ004';
    end if;
    raise exception 'Você já está na fila da %', v_state ->> 'court_name'
      using errcode = 'NQ014';
  end if;

  -- Antes de calcular a vez: uma chamada vencida nesta quadra não pode
  -- segurar a fila.
  perform public.advance_court(v_court.id);

  insert into public.queue_entries (court_id, mode, created_by, scan_token_id)
  values (v_court.id, coalesce(p_mode, 'single'), v_user, v_token.id)
  returning id into v_entry_id;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role, joined_via)
  values (v_entry_id, v_court.id, v_user, 'owner', 'owner');

  insert into public.queue_entry_pins (entry_id, pin)
  values (v_entry_id, public.new_group_pin(v_court.id));

  -- Abriu a própria vaga: um pedido para entrar em outro grupo perde o sentido.
  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry_id
   where id = v_token.id;

  perform public.call_next_team(v_court.id);

  return public.queue_entry_state(v_entry_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Pedir para entrar no grupo de alguém
-- ---------------------------------------------------------------------
create or replace function public.request_join(
  p_scan_token    text,
  p_entry_id      uuid,
  p_leave_current boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_token   public.scan_tokens%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_court   public.courts%rowtype;
  v_owner   uuid;
  v_name    text;
  v_request public.queue_join_requests%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra novamente para pedir para entrar');

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.court_id <> v_token.court_id then
    raise exception 'Escaneie o QR Code da quadra deste grupo' using errcode = 'NQ002';
  end if;
  if v_entry.status not in ('waiting', 'ready', 'playing') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  -- Quem está em outra fila continua nela enquanto espera: só sai quando
  -- for aceito. Aqui só se confere que confirmou o aviso.
  perform public.free_player_for(v_user, p_entry_id, p_leave_current, false);

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  insert into public.queue_join_requests
    (entry_id, court_id, user_id, scan_token_id, expires_at, leave_current)
  values
    (p_entry_id, v_entry.court_id, v_user, v_token.id, now() + interval '10 minutes',
     public.player_state(v_user) ->> 'state' <> 'free')
  returning * into v_request;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = p_entry_id
   where id = v_token.id;

  select m.user_id into v_owner
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.is_active and m.role = 'owner'
  limit 1;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  select public.short_name_of(coalesce(p.full_name, p.username::text)) into v_name
  from public.profiles p where p.id = v_user;

  if v_owner is not null then
    perform public.enqueue_user_notification(
      v_owner, v_entry.court_id, 'group_join_request',
      'Pedido para entrar no seu grupo',
      format('%s quer entrar no seu grupo na %s.', coalesce(v_name, 'Alguém'),
             public.court_label(v_court.court_number)),
      jsonb_build_object('request_id', v_request.id, 'entry_id', p_entry_id,
                         'court_id', v_entry.court_id)
    );
  end if;

  return jsonb_build_object(
    'request_id', v_request.id,
    'status',     v_request.status,
    'entry_id',   p_entry_id,
    'court_id',   v_entry.court_id,
    'expires_at', v_request.expires_at
  );
end;
$$;

-- ---------------------------------------------------------------------
-- O dono aceita ou recusa
-- ---------------------------------------------------------------------
create or replace function public.decide_join_request(
  p_request_id uuid,
  p_approve    boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_request public.queue_join_requests%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_court   public.courts%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_request from public.queue_join_requests r where r.id = p_request_id for update;
  if not found or v_request.status <> 'pending' or v_request.expires_at <= now() then
    raise exception 'Este pedido não está mais pendente' using errcode = 'NQ027';
  end if;

  select * into v_entry from public.queue_entries e where e.id = v_request.entry_id for update;

  if not exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = v_entry.id and m.user_id = v_user and m.is_active and m.role = 'owner'
  ) then
    raise exception 'Só quem abriu o grupo aceita pedidos' using errcode = 'NQ008';
  end if;

  if not coalesce(p_approve, false) then
    update public.queue_join_requests
       set status = 'rejected', decided_at = now(), decided_by = v_user
     where id = p_request_id;
    return jsonb_build_object('request_id', p_request_id, 'status', 'rejected');
  end if;

  if v_entry.status not in ('waiting', 'ready', 'playing') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  -- Quem pediu estando em outra fila e confirmou o aviso sai dela agora,
  -- na mesma transação em que entra no grupo.
  if public.player_state(v_request.user_id) ->> 'state' <> 'free' and v_request.leave_current then
    perform public.free_player_for(v_request.user_id, v_entry.id, true);
  end if;

  -- Estava livre ao pedir e entrou em outra fila enquanto esperava.
  if public.player_state(v_request.user_id) ->> 'state' <> 'free' then
    update public.queue_join_requests
       set status = 'cancelled', decided_at = now(), decided_by = v_user
     where id = p_request_id;
    return jsonb_build_object('request_id', p_request_id, 'status', 'cancelled',
                              'reason', 'requester_in_another_queue');
  end if;

  perform public.add_group_member(v_entry.id, v_request.user_id, 'approval');

  update public.queue_join_requests
     set status = 'approved', decided_at = now(), decided_by = v_user
   where id = p_request_id;

  select * into v_court from public.courts c where c.id = v_entry.court_id;

  perform public.enqueue_user_notification(
    v_request.user_id, v_entry.court_id, 'group_join_approved',
    'Você entrou no grupo',
    format('Seu pedido foi aceito. Você está no grupo da %s.',
           public.court_label(v_court.court_number)),
    jsonb_build_object('entry_id', v_entry.id, 'court_id', v_entry.court_id)
  );

  return jsonb_build_object('request_id', p_request_id, 'status', 'approved',
                            'entry_id', v_entry.id);
end;
$$;

create or replace function public.cancel_join_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where id = p_request_id and user_id = auth.uid() and status = 'pending';

  if not found then
    raise exception 'Este pedido não está mais pendente' using errcode = 'NQ027';
  end if;

  return jsonb_build_object('request_id', p_request_id, 'status', 'cancelled');
end;
$$;

-- ---------------------------------------------------------------------
-- Entrar com o PIN do grupo
--
-- PIN errado não é exceção: a tentativa precisa ficar gravada (e o scan
-- gasto) para o limite funcionar, e uma exceção desfaria as duas coisas.
-- ---------------------------------------------------------------------
create or replace function public.join_with_pin(
  p_scan_token    text,
  p_pin           text,
  p_leave_current boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_token   public.scan_tokens%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_failed  integer;
  v_limit   constant integer := 5;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra novamente para entrar com o PIN');

  select count(*)::integer into v_failed
  from public.queue_pin_attempts a
  where a.user_id = v_user and not a.success and a.created_at > now() - interval '15 minutes';

  if v_failed >= v_limit then
    raise exception 'Muitas tentativas de PIN. Tente de novo em alguns minutos ou peça para entrar.'
      using errcode = 'NQ028';
  end if;

  select e.* into v_entry
  from public.queue_entry_pins p
  join public.queue_entries e on e.id = p.entry_id
  where e.court_id = v_token.court_id
    and e.status in ('waiting', 'ready', 'playing')
    and p.pin = trim(coalesce(p_pin, ''))
  for update of e;

  if not found then
    insert into public.queue_pin_attempts (user_id, court_id, success)
    values (v_user, v_token.court_id, false);

    update public.scan_tokens set consumed_at = now() where id = v_token.id;

    return jsonb_build_object(
      'joined',        false,
      'code',          'PIN_INVALID',
      'message',       'PIN incorreto. Confira com quem está no grupo e escaneie de novo.',
      'attempts_left', greatest(v_limit - v_failed - 1, 0)
    );
  end if;

  perform public.free_player_for(v_user, v_entry.id, p_leave_current);
  perform public.add_group_member(v_entry.id, v_user, 'pin');

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  insert into public.queue_pin_attempts (user_id, court_id, entry_id, success)
  values (v_user, v_token.court_id, v_entry.id, true);

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  return jsonb_build_object(
    'joined',   true,
    'entry_id', v_entry.id,
    'court_id', v_entry.court_id,
    'status',   (select e.status from public.queue_entries e where e.id = v_entry.id)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Check-in na quadra
--
-- Um check-in basta para o turno começar. Quem é do grupo e chega
-- depois escaneia também: fica registrado que está em quadra.
-- ---------------------------------------------------------------------
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
    'Escaneie o QR Code da quadra para confirmar que você chegou');

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
-- O grupo devolve a quadra antes do fim do turno
-- ---------------------------------------------------------------------
create or replace function public.finish_my_turn(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_match public.matches%rowtype;
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

  if not public.is_entry_member(v_match.side_a_entry_id, v_user) and not public.is_staff() then
    raise exception 'Só quem está no grupo encerra o turno' using errcode = 'NQ008';
  end if;

  return public.close_match(p_match_id, null, 'finished_by_group', v_user);
end;
$$;

-- Fim do "quem ganha fica".
drop function if exists public.report_match_result(uuid, public.match_side);
drop function if exists public.join_open_side(text);
drop function if exists public.finish_match(uuid, public.match_side);

create or replace function public.finish_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_match public.matches%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode encerrar turnos' using errcode = 'NQ008';
  end if;

  select * into v_match
  from public.matches mt
  where mt.ended_at is null
    and p_entry_id in (mt.side_a_entry_id, mt.side_b_entry_id);

  if not found then
    raise exception 'Este grupo não está em quadra' using errcode = 'NQ009';
  end if;

  return public.close_match(v_match.id, null, 'cancelled', auth.uid());
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
  v_players jsonb;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id;

  v_players := public.match_side_players(v_match.side_a_entry_id);

  return jsonb_build_object(
    'match_id',     v_match.id,
    'court_id',     v_match.court_id,
    'court_name',   public.court_label(v_court.court_number),
    'entry_id',     v_match.side_a_entry_id,
    'players',      v_players,
    'group_size',   jsonb_array_length(v_players),
    'group_label',  public.group_label(jsonb_array_length(v_players)),
    'slot_minutes', v_match.slot_minutes,
    'started_at',   v_match.started_at,
    'expires_at',   v_match.expires_at,
    'ended_at',     v_match.ended_at,
    'end_reason',   v_match.end_reason,
    'is_live',      v_match.ended_at is null,
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
           e.call_expires_at,
           -- A raquete do grupo é a de quem está à frente dele.
           (select jsonb_build_object(
                     'frame', pr.racket_frame_color,
                     'grip',  pr.racket_grip_color)
              from public.queue_entry_members mm
              join public.profiles pr on pr.id = mm.user_id
             where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
             limit 1) as racket,
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
        'group_label', public.group_label(jsonb_array_length(q.players)),
        -- Mantido para o app anterior à Sprint 4.
        'mode_label',  public.group_label(jsonb_array_length(q.players)),
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'racket',      q.racket,
        'players',     q.players,
        -- "Ana S. + Bruno L. + 3": o nome de todo mundo não cabe na linha.
        'team_label',  (
          select string_agg(pl ->> 'short_name', ' + ' order by ord)
                   || case when jsonb_array_length(q.players) > 2
                           then ' + ' || (jsonb_array_length(q.players) - 2)
                           else '' end
          from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
          where ord <= 2
        ),
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position
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

-- O grupo de quem está olhando: PIN, membros e pedidos pendentes. Só
-- sai para quem está no grupo.
create or replace function public.my_group(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not public.is_entry_member(p_entry_id, auth.uid()) then null
    else jsonb_build_object(
      'entry_id', p_entry_id,
      'status',   (select e.status from public.queue_entries e where e.id = p_entry_id),
      'pin',      (select p.pin from public.queue_entry_pins p where p.entry_id = p_entry_id),
      'is_owner', exists (
                    select 1 from public.queue_entry_members m
                    where m.entry_id = p_entry_id and m.user_id = auth.uid()
                      and m.is_active and m.role = 'owner'),
      'checked_in', exists (
                    select 1 from public.queue_entry_members m
                    where m.entry_id = p_entry_id and m.user_id = auth.uid()
                      and m.is_active and m.checked_in_at is not null),
      'players',  public.match_side_players(p_entry_id),
      'group_size', jsonb_array_length(public.match_side_players(p_entry_id)),
      'pending_requests', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'request_id', r.id,
                 'user_id',    r.user_id,
                 'full_name',  pr.full_name,
                 'short_name', public.short_name_of(coalesce(pr.full_name, pr.username::text)),
                 'initials',   public.initials_of(coalesce(pr.full_name, pr.username::text)),
                 'created_at', r.created_at,
                 'expires_at', r.expires_at
               ) order by r.created_at), '[]'::jsonb)
        from public.queue_join_requests r
        left join public.profiles pr on pr.id = r.user_id
        where r.entry_id = p_entry_id and r.status = 'pending' and r.expires_at > now()
      )
    )
  end;
$$;

-- O pedido que eu fiz e ainda espera resposta.
create or replace function public.my_join_request()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select (
    select jsonb_build_object(
      'request_id', r.id,
      'entry_id',   r.entry_id,
      'court_id',   r.court_id,
      'court_name', public.court_label(c.court_number),
      'expires_at', r.expires_at,
      'owner_name', (
        select public.short_name_of(coalesce(pr.full_name, pr.username::text))
        from public.queue_entry_members m
        join public.profiles pr on pr.id = m.user_id
        where m.entry_id = r.entry_id and m.is_active and m.role = 'owner'
        limit 1)
    )
    from public.queue_join_requests r
    join public.courts c on c.id = r.court_id
    where r.user_id = auth.uid() and r.status = 'pending' and r.expires_at > now()
    limit 1
  );
$$;

grant execute on function public.my_group(uuid)    to authenticated;
grant execute on function public.my_join_request() to authenticated;

create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court  public.courts%rowtype;
  v_park   public.parks%rowtype;
  v_match  uuid;
  v_items  jsonb;
  v_queue  integer;
  v_rem    integer := 0;
  v_mine   jsonb;
  v_state  jsonb;
  v_group  jsonb;
  v_req    jsonb;
  v_live   jsonb;
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
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code
          union all
          select 'nfc'::text where v_court.has_nfc_tag
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
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (v_state ->> 'state') = 'free',
    'my_state',     v_state,
    'generated_at', now()
  );
end;
$$;

create or replace function public.my_queue_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_entry  public.queue_entries%rowtype;
  v_court  public.courts%rowtype;
  v_park   public.parks%rowtype;
  v_item   jsonb;
  v_match  uuid;
begin
  if v_user is null then
    return jsonb_build_object('state', 'free');
  end if;

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active
  limit 1;

  if not found then
    return jsonb_build_object('state', 'free', 'pending_request', public.my_join_request());
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  select * into v_park  from public.parks pk where pk.id = v_court.park_id;

  select i into v_item
  from jsonb_array_elements(public.court_queue_items(v_entry.court_id)) i
  where (i ->> 'entry_id')::uuid = v_entry.id;

  select mt.id into v_match
  from public.matches mt
  where mt.court_id = v_entry.court_id
    and mt.ended_at is null
    and mt.side_a_entry_id = v_entry.id;

  return jsonb_build_object(
    'state',      case
                    when v_entry.status = 'playing' then 'playing'
                    when v_entry.status = 'ready'   then 'called'
                    else 'queued'
                  end,
    'entry_id',   v_entry.id,
    'court_id',   v_court.id,
    'court_name', public.court_label(v_court.court_number),
    'park_id',    v_park.id,
    'park_name',  v_park.name,
    'position',        (v_item ->> 'position')::integer,
    'position_label',  v_item ->> 'position_label',
    'teams_ahead',     (v_item ->> 'teams_ahead')::integer,
    'eta_seconds',     (v_item ->> 'eta_seconds')::integer,
    'stack',           v_item -> 'stack',
    'stack_more',      (v_item ->> 'stack_more')::integer,
    'players',         public.match_side_players(v_entry.id),
    'group',           public.my_group(v_entry.id),
    'call_expires_at',      v_entry.call_expires_at,
    'call_remaining_seconds', case
                                when v_entry.status <> 'ready' or v_entry.call_expires_at is null then null
                                else greatest(0, floor(extract(epoch from
                                       (v_entry.call_expires_at - now())))::integer)
                              end,
    'match',      case when v_match is null then null else public.match_state(v_match) end,
    'generated_at', now()
  );
end;
$$;

-- Compatível com a Sprint 1 (Edge Function queue-status).
create or replace function public.court_queue(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_screen jsonb;
begin
  v_screen := public.court_screen(p_court_id);

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',                    v_screen -> 'court' -> 'id',
      'slug',                  (select c.slug from public.courts c where c.id = p_court_id),
      'name',                  v_screen -> 'court' -> 'name',
      'address',               (select c.address from public.courts c where c.id = p_court_id),
      'status',                v_screen -> 'court' -> 'status',
      'is_active',             v_screen -> 'court' -> 'is_active',
      'latitude',              v_screen -> 'court' -> 'latitude',
      'longitude',             v_screen -> 'court' -> 'longitude',
      'average_match_minutes', v_screen -> 'court' -> 'slot_minutes',
      'photo_url',             (select c.photo_url from public.courts c where c.id = p_court_id)
    ),
    'can_join',      v_screen -> 'court_accepting',
    'teams_waiting', v_screen -> 'queue_length',
    'current_match', case
                       when (v_screen ->> 'is_live')::boolean then jsonb_build_object(
                         'entry_id',   v_screen -> 'match' -> 'entry_id',
                         'started_at', v_screen -> 'match' -> 'started_at',
                         'players',    v_screen -> 'match' -> 'players'
                       )
                       else null
                     end,
    'current_match_remaining_minutes', case
                                         when (v_screen ->> 'is_live')::boolean
                                           then ceil((v_screen ->> 'remaining_seconds')::numeric / 60)::integer
                                         else null
                                       end,
    'queue', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'entry_id',               i -> 'entry_id',
               'group_size',             i -> 'group_size',
               'status',                 i -> 'status',
               'joined_at',              i -> 'joined_at',
               'position',               i -> 'position',
               'teams_ahead',            i -> 'teams_ahead',
               'estimated_wait_minutes', ceil((i ->> 'eta_seconds')::numeric / 60)::integer,
               'players',                i -> 'players'
             ) order by (i ->> 'position')::integer), '[]'::jsonb)
      from jsonb_array_elements(v_screen -> 'queue') i
    ),
    'generated_at', v_screen -> 'generated_at'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Administração: a tolerância do check-in no formulário da quadra
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
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

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
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) to authenticated;

-- ---------------------------------------------------------------------
-- Dados que já existiam
-- ---------------------------------------------------------------------

-- Um mandante do "quem ganha fica" está 'playing' sem turno aberto. No
-- modelo novo isso não existe: o turno dele acabou.
update public.queue_entries e
   set status = 'done', ended_at = coalesce(e.ended_at, now())
 where e.status = 'playing'
   and not exists (
     select 1 from public.matches mt
     where mt.ended_at is null and mt.side_a_entry_id = e.id
   );

-- Um turno aberto com lado B (gravado antes desta migration) segue até
-- o fim do slot; close_match encerra os dois lados.
update public.courts set holder_entry_id = null where holder_entry_id is not null;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
grant execute on function public.request_join(text, uuid, boolean)       to authenticated;
grant execute on function public.decide_join_request(uuid, boolean)      to authenticated;
grant execute on function public.cancel_join_request(uuid)               to authenticated;
grant execute on function public.join_with_pin(text, text, boolean)      to authenticated;
grant execute on function public.finish_my_turn(uuid)                    to authenticated;
grant execute on function public.finish_match(uuid)                      to authenticated;
grant execute on function public.check_in_and_start(text)                to authenticated;
grant execute on function public.leave_queue(uuid, text)                 to authenticated;
grant execute on function public.join_queue(text, public.queue_mode, text) to authenticated;
