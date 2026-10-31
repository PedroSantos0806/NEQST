-- =====================================================================
-- Montar o grupo não é corrida contra a tolerância
--
-- Quem abre a fila de uma quadra no modo anfitrião recebia, no mesmo
-- instante, o prazo de check-in da quadra (padrão: 120 s). Só que a
-- pessoa que abriu a fila acabou de chegar e ainda vai fazer o que o
-- app pede que ela faça: cadastrar quem já estava jogando, cadastrar
-- quem já esperava sem app, passar o PIN para os amigos que vieram
-- junto e só então tocar em "Entrando na quadra".
--
-- Passados os 120 s, o cron expirava a vaga dela. O resultado, medido:
--
--     status da vaga de quem abriu: expired
--     check-in: RECUSADO -> "Você não está na fila desta quadra"
--     fila aberta nesta quadra: ainda aberta
--
-- Ou seja: expulsa da fila que ela mesma abriu, sem poder entrar e sem
-- poder reabrir, com a quadra travada até a sessão ser considerada
-- esquecida.
--
-- A correção parte do que a tolerância é para quê. Ela existe para
-- destravar a fila quando quem foi chamado não aparece. Se não há
-- ninguém atrás, não há fila travada — e não há por que haver relógio.
--
--   . primeiro grupo da fila, com a quadra livre e NINGUÉM atrás:
--     fica pronto para entrar, sem prazo. Monta o grupo com calma.
--   . no instante em que um segundo grupo entra, o prazo passa a
--     valer, contado dali. Quem está na frente tem a tolerância da
--     quadra para fazer o check-in, como sempre teve.
--
-- O tempo de jogo continua começando no check-in, não na abertura:
-- isso já era assim e os testes seguem provando.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Chamar o próximo — agora com o prazo condicionado a haver fila
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_next     public.queue_entries%rowtype;
  v_behind   boolean;
  v_deadline timestamptz;
  v_host     uuid;
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

  -- Tem alguém esperando atrás? É isso que faz o relógio existir.
  v_behind := exists (
    select 1 from public.queue_positions qp
    where qp.court_id = p_court_id and qp.entry_id <> v_next.id
  );

  v_deadline := case
                  -- Vaga sem app nunca teve prazo: quem marca é o anfitrião.
                  when v_next.is_offline then null
                  -- Sozinho na fila: monta o grupo sem relógio correndo.
                  when not v_behind     then null
                  else now() + make_interval(secs => v_court.call_window_seconds)
                end;

  if v_next.status = 'waiting' then
    update public.queue_entries
       set status          = 'ready',
           called_at       = coalesce(called_at, now()),
           call_expires_at = v_deadline
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

  elsif v_next.status = 'ready'
        and v_next.call_expires_at is null
        and v_deadline is not null then
    -- Estava montando o grupo sozinho e agora chegou gente atrás: o
    -- relógio começa AQUI, com a tolerância inteira.
    --
    -- Sem notificação nova aqui de propósito: a tela de quem está na
    -- frente já mostra a tolerância assim que ela passa a existir, e
    -- um tipo de aviso novo exigiria mexer no enum por um caso que a
    -- própria tela cobre.
    update public.queue_entries
       set call_expires_at = v_deadline
     where id = v_next.id and status = 'ready' and call_expires_at is null;
  end if;

  return v_next.id;
end;
$$;

revoke all on function public.call_next_team(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- A fila esquecida, agora que o primeiro grupo pode ficar sem prazo
--
-- Antes, qualquer grupo com app na fila impedia a sessão de ser
-- considerada esquecida — e tudo bem, porque um grupo parado acabava
-- expirando pelo prazo. Sem prazo, quem abre a fila e vai embora sem
-- fazer check-in seguraria a quadra para sempre.
--
-- Então a presença passa a ter validade: só conta quem se mexeu nos
-- últimos 30 minutos. É o mesmo relógio que a regra já usava para
-- decidir se a sessão foi abandonada, aplicado também a quem está nela.
-- ---------------------------------------------------------------------
create or replace function public.host_session_is_idle(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
           select 1
           from public.queue_entries e
           where e.court_id = s.court_id
             and not e.is_offline
             and e.status in ('waiting', 'ready', 'playing')
             and greatest(e.joined_at,
                          coalesce(e.called_at, e.joined_at),
                          coalesce(e.started_at, e.joined_at)) > now() - interval '30 minutes'
         )
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

-- `court_has_app_players` existia só para a regra acima, que agora
-- precisa da validade de 30 minutos embutida. Sem outro chamador, ela
-- sai de cena em vez de ficar como armadilha para quem vier depois.
drop function if exists public.court_has_app_players(uuid);
