-- =====================================================================
-- Auditoria de segurança: fechando o que estava aberto no banco
--
-- Uma auditoria estática do repositório apontou três furos exploráveis
-- de autorização e um bug funcional que trava quadra. Os quatro foram
-- reproduzidos num Postgres descartável antes desta migration existir,
-- e é isso que cada bloco aqui fecha.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. profiles: o cliente escrevia a linha inteira, inclusive o e-mail
--
-- O grant era `select, update on public.profiles` — tabela inteira, sem
-- lista de colunas — e a policy do dono só protegia o papel:
--
--     with check (id = auth.uid() and role = public.current_app_role())
--
-- Reproduzido: qualquer conta logada gravava
-- `email = 'admin@neqst.com'` no PRÓPRIO perfil. A sincronia com
-- auth.users é de mão única, então nada corrigia depois — e isso é
-- metade da escalação do item 2.
--
-- Agora o grant é por coluna. `email`, `username`, `role` e `id` saem da
-- escrita do cliente; `email` e `role` saem também da LEITURA, porque
-- `select email, full_name, role from profiles` entregava a base inteira
-- com um "qual conta é admin" de brinde.
--
-- O app não perde nada: ele nunca leu profiles direto, sempre por RPC
-- (`my_profile_summary`, `admin_users`), e essas são SECURITY DEFINER.
-- ---------------------------------------------------------------------
revoke select, update on public.profiles from authenticated;

grant select (id, username, full_name, avatar_url, created_at,
              avatar_tone, racket_frame_color, racket_grip_color)
  on public.profiles to authenticated;

-- O que a pessoa muda no próprio perfil. username fica de fora de
-- propósito: quem valida o formato e a unicidade é `update_my_profile`.
grant update (full_name, avatar_url, avatar_tone,
              racket_frame_color, racket_grip_color)
  on public.profiles to authenticated;

comment on column public.profiles.email is
  'Espelho de auth.users.email, mantido pelo gatilho. Fora do alcance do '
  'cliente: nem leitura nem escrita. Quem decide quem é quem é auth.users.';

-- ---------------------------------------------------------------------
-- 2. promote_to_admin resolvia o alvo por um e-mail forjável
--
-- A busca era em `public.profiles`, coluna com índice NÃO único, com
-- `select ... into` — que com duas linhas não levanta erro: pega uma e
-- segue. Somado ao item 1, o ataque era: gravo o e-mail do admin no meu
-- perfil, e o operador que roda `promote_to_admin('admin@…')` no SQL
-- Editor promove, na melhor das hipóteses, uma linha ao acaso.
--
-- Medido: na reprodução o Postgres escolheu o admin de verdade, não o
-- atacante — a ordem das linhas decide. Ou seja, não é um exploit
-- determinístico; é um sorteio. Um sorteio para dar admin a um
-- desconhecido é tão inaceitável quanto a certeza.
--
-- Duas correções, e a primeira já basta sozinha:
--
--   . o alvo passa a ser resolvido em `auth.users`, que o cliente não
--     escreve e onde o e-mail é único de verdade;
--   . mais de uma linha agora é erro, nunca uma escolha silenciosa.
--
-- E quem quiser certeza absoluta usa `promote_to_admin_by_id(uuid)`,
-- com o id copiado de Authentication > Users. Nome diferente de
-- propósito: duas funções `promote_to_admin` com um argumento cada
-- deixariam a chamada ambígua ("is not unique"), que foi exatamente o
-- erro que travou o deploy no PR #14.
-- ---------------------------------------------------------------------
create or replace function public.promote_to_admin_by_id(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current uuid;
begin
  if p_user_id is null then
    raise exception 'Informe o id do usuário (Authentication > Users).'
      using errcode = 'NQ021';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'Nenhum usuário com o id %.', p_user_id using errcode = 'NQ021';
  end if;

  -- Um admin por vez, e a troca continua sendo um ato deliberado: a
  -- função recusa em vez de rebaixar o admin atual sozinha. Um erro de
  -- digitação aqui transferiria a administração em silêncio.
  select p.id into v_current
  from public.profiles p where p.role = 'admin'::public.app_role;

  if v_current is not null and v_current <> p_user_id then
    raise exception 'Já existe um admin. Rebaixe-o antes: update public.profiles set role = ''player'' where id = ''%'';', v_current
      using errcode = 'NQ022';
  end if;

  update public.profiles set role = 'admin'::public.app_role where id = p_user_id;

  if not found then
    raise exception 'Nenhum perfil para o id %. O gatilho de criação de perfil pode não ter rodado.', p_user_id
      using errcode = 'NQ021';
  end if;

  return jsonb_build_object('user_id', p_user_id, 'role', 'admin');
end;
$$;

revoke all on function public.promote_to_admin_by_id(uuid) from public, anon, authenticated;

comment on function public.promote_to_admin_by_id(uuid) is
  'Promove a admin pelo id do usuário. É a forma sem ambiguidade: copie o id '
  'em Authentication > Users. Só pelo SQL Editor.';

create or replace function public.promote_to_admin(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_count integer;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if v_email = '' then
    raise exception 'Informe o e-mail da conta.' using errcode = 'NQ021';
  end if;

  -- auth.users, não profiles: aquele e-mail o cliente não escreve.
  select count(*)::integer into v_count
  from auth.users u where lower(u.email) = v_email;

  if v_count = 0 then
    raise exception 'Nenhuma conta com o e-mail %. Crie o usuário em Authentication > Users primeiro.', p_email
      using errcode = 'NQ021';
  end if;

  if v_count > 1 then
    raise exception 'Há % contas com o e-mail %. Use promote_to_admin_by_id(<uuid>) com o id de Authentication > Users.',
      v_count, p_email
      using errcode = 'NQ021';
  end if;

  select u.id into v_id from auth.users u where lower(u.email) = v_email;

  return public.promote_to_admin_by_id(v_id) || jsonb_build_object('email', p_email);
end;
$$;

revoke all on function public.promote_to_admin(text) from public, anon, authenticated;

comment on function public.promote_to_admin(text) is
  'Promove a admin pelo e-mail da CONTA (auth.users), não pelo e-mail do perfil. '
  'Mais de uma conta com o mesmo e-mail é erro, nunca uma escolha ao acaso.';

-- ---------------------------------------------------------------------
-- 3. expire_stale_queue_entries expulsava quem só esperou — e travava
--    a quadra
--
-- Era isto:
--
--     where status in ('waiting','ready') and joined_at < now() - '3 hours'
--
-- Dois defeitos, ambos reproduzidos:
--
--   . esperar 3 horas numa fila movimentada é o comportamento NORMAL de
--     uma fila movimentada — é o cenário que o app existe para
--     gerenciar. E desde a rotação automática `joined_at` renasce a cada
--     turno (é por isso que `first_joined_at` existe), então a função
--     ficou medindo a coisa errada de duas formas ao mesmo tempo.
--
--   . era a ÚNICA função que mudava status de fila sem chamar
--     `call_next_team`. Expirar um grupo em `ready` deixava a quadra
--     `available` com gente em `waiting` e zero partidas: ninguém
--     destravava, porque `nudge_court` só age sobre o que já venceu, e
--     nada estava vencido. A quadra ficava inutilizável.
--
-- Agora a regra é ausência de SINAL, não tempo de espera: só sai quem
-- nunca foi chamado e não se mexeu desde que chegou. Quem está na fila
-- esperando a vez chegar tem sinal — o grupo da frente jogando é sinal.
-- ---------------------------------------------------------------------
create or replace function public.expire_stale_queue_entries(p_max_wait interval default '3 hours')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count  integer := 0;
  v_courts uuid[];
  v_court  uuid;
begin
  -- Sai quem nunca foi chamado, não se mexeu desde que chegou, e está
  -- numa quadra PARADA. Alguém jogando é sinal de fila viva: ali quem
  -- espera está esperando certo, não abandonado.
  with expirados as (
    update public.queue_entries e
       set status = 'expired', cancel_reason = 'expired_by_system', left_at = now()
     where e.status in ('waiting', 'ready')
       and e.first_joined_at < now() - p_max_wait
       and e.called_at is null
       and not exists (
         select 1 from public.matches mt
         where mt.court_id = e.court_id and mt.ended_at is null
       )
    returning e.court_id
  )
  select coalesce(array_agg(distinct court_id), '{}'::uuid[]), count(*)::integer
  into v_courts, v_count
  from expirados;

  -- E a fila anda. Sem isto a quadra ficava `available` com gente em
  -- `waiting` e ninguém para destravar: era a única função que mexia em
  -- status de fila sem chamar o próximo.
  foreach v_court in array v_courts loop
    perform public.call_next_team(v_court);
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_stale_queue_entries(interval) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Nome completo e presença em tempo real sem login (LGPD)
--
-- `court_queue` roda sem JWT e `court_queue_items`, `court_screen`,
-- `queue_entry_players` e `match_side_players` têm grant para anon. Com
-- o slug da quadra — que é previsível — qualquer pessoa, sem conta,
-- lia nome completo, posição na fila e horário de todo mundo que está
-- numa quadra pública. Nome completo mais local mais horário é rotina
-- de pessoa identificada.
--
-- O que o anônimo passa a receber é o que a placa da quadra mostraria
-- de qualquer forma: primeiro nome e inicial ("Ana S."), que é o que a
-- fila precisa para você se reconhecer nela — e é o que o tablet fala
-- em voz alta. `full_name`, `username` e `user_id` ficam só para quem
-- está logado.
-- ---------------------------------------------------------------------
create or replace function public.match_side_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      -- `role` e `checked_in` ficam nos dois casos: o placar precisa
      -- deles para desenhar igual, e não dizem quem a pessoa é.
      case
        when auth.uid() is null then
          jsonb_build_object(
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text)),
            'role',       m.role,
            'checked_in', m.checked_in_at is not null
          )
        else
          jsonb_build_object(
            'user_id',    m.user_id,
            'username',   p.username,
            'full_name',  p.full_name,
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text)),
            'role',       m.role,
            'checked_in', m.checked_in_at is not null
          )
      end
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

grant execute on function public.match_side_players(uuid) to anon, authenticated;

create or replace function public.queue_entry_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      case
        when auth.uid() is null then
          jsonb_build_object(
            'role',       m.role,
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text))
          )
        else
          jsonb_build_object(
            'user_id',    m.user_id,
            'role',       m.role,
            'username',   p.username,
            'full_name',  p.full_name,
            'avatar_url', p.avatar_url,
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text))
          )
      end
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

grant execute on function public.queue_entry_players(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. 61 funções nasceram executáveis por PUBLIC
--
-- Em Postgres, função nova é executável por PUBLIC. O padrão correto do
-- repositório é `revoke all ... from public` antes do grant, e ele é
-- seguido na maior parte do código — mas numa leva de RPCs o revoke não
-- foi escrito, e ali o grant é decorativo.
--
-- Não havia exploit anônimo: as RPCs sensíveis recusam por dentro
-- (`auth.uid() is null` → NQ001, ou checagem de papel). O risco era
-- arquitetural: a defesa inteira repousava numa checagem manual dentro
-- de cada função, e a próxima que esquecesse já nascia aberta.
--
-- Conferido antes de revogar: nenhuma das 61 depende SÓ do PUBLIC —
-- todas têm grant explícito para authenticated. Então revogar não
-- quebra nada, e o teste de privilégios (tests/local/90) passa a impedir
-- a regressão.
--
-- O laço abaixo é SQL dinâmico, o único do repositório, e é aqui de
-- propósito: ele roda uma vez, numa migration, sobre identificadores
-- vindos do catálogo (`oid::regprocedure`, já citados pelo Postgres).
-- Listar 61 assinaturas à mão envelheceria errado na primeira função
-- nova.
-- ---------------------------------------------------------------------
do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as assinatura
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('public', p.oid, 'EXECUTE')
  loop
    execute format('revoke execute on function %s from public', v_fn.assinatura);
  end loop;
end $$;

-- E as próximas nascem fechadas, em vez de depender de alguém lembrar.
alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------------
-- 6. O worker de push reenviava o mesmo aviso
--
-- O `select ... where status = 'pending'` não tinha claim nem lease, e o
-- worker é chamado de 10 em 10 segundos enquanto um lote de 200 leva
-- mais que isso: duas execuções sobrepostas mandavam o mesmo push duas
-- vezes. "É a sua vez!" duplicado na quadra é ruído; e se a escrita de
-- `status = 'sent'` falhar, a linha fica `pending` para sempre e o
-- reenvio não tem fim.
--
-- claimed_at em vez de um valor novo no enum: valor novo de enum não
-- pode ser usado na mesma transação que o criou, o que custaria duas
-- migrations por uma coluna que resolve igual.
-- ---------------------------------------------------------------------
alter table public.notification_outbox
  add column if not exists claimed_at timestamptz;

comment on column public.notification_outbox.claimed_at is
  'Quando um worker pegou esta linha. Outro worker só pega de novo depois de '
  '2 minutos — o bastante para o primeiro ter morrido no meio.';

create index if not exists notification_outbox_claim_idx
  on public.notification_outbox (claimed_at)
  where status = 'pending';

create or replace function public.claim_notifications(
  p_limit        integer default 200,
  p_max_attempts integer default 5
)
returns setof public.notification_outbox
language sql
volatile
security definer
set search_path = ''
as $$
  update public.notification_outbox o
     set claimed_at = now()
   where o.id in (
     select c.id
     from public.notification_outbox c
     where c.status = 'pending'
       -- Os mesmos filtros que o worker fazia na mão, agora de um lado
       -- só: aviso agendado para o futuro não sai antes da hora, e o
       -- que já falhou cinco vezes para de ser tentado.
       and c.scheduled_for <= now()
       and c.attempts < coalesce(p_max_attempts, 5)
       and (c.claimed_at is null or c.claimed_at < now() - interval '2 minutes')
     order by c.scheduled_for
     -- É isto que faz dois workers sobrepostos pegarem lotes
     -- diferentes em vez do mesmo.
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 200), 500))
   )
  returning o.*;
$$;

revoke all on function public.claim_notifications(integer, integer) from public, anon, authenticated;

comment on function public.claim_notifications(integer, integer) is
  'Pega um lote de notificações pendentes para um worker, marcando o claim. '
  'Dois workers ao mesmo tempo levam lotes diferentes (for update skip locked).';

-- ---------------------------------------------------------------------
-- 7. Rotação do segredo do QR com lost update
--
-- A Edge Function fazia read-modify-write: lia `qr_secret_version`,
-- somava 1 e gravava. Dois POSTs concorrentes liam v1 e gravavam v2 — e
-- o segundo administrador achava que havia invalidado o QR impresso do
-- primeiro sem ter invalidado nada.
--
-- Invalidar papel já colado na quadra é irreversível: tem de ser
-- atômico. Aqui o incremento é feito pelo banco e devolve a versão que
-- de fato vale.
-- ---------------------------------------------------------------------
create or replace function public.rotate_court_qr_secret(p_court_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version integer;
begin
  perform public.require_admin();

  update public.courts
     set qr_secret_version = qr_secret_version + 1,
         qr_rotated_at     = now()
   where id = p_court_id
  returning qr_secret_version into v_version;

  if v_version is null then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  return v_version;
end;
$$;

revoke all on function public.rotate_court_qr_secret(uuid) from public, anon, authenticated;
grant execute on function public.rotate_court_qr_secret(uuid) to authenticated;

comment on function public.rotate_court_qr_secret(uuid) is
  'Incrementa a versão do segredo do QR da quadra de forma atômica e devolve a '
  'versão nova. Invalidar QR impresso é irreversível: não pode ter lost update.';
