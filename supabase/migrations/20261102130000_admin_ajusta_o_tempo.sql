-- =====================================================================
-- O admin ajusta o tempo do turno em andamento
--
-- O relógio da quadra é o do banco, e ele começa quando o turno começa.
-- Na quadra real isso sai errado de vez em quando: o grupo entrou cinco
-- minutos antes de alguém marcar, a troca demorou mais que o minuto, o
-- anfitrião marcou "entraram" com o grupo ainda juntando as raquetes.
-- Quando isso acontece, hoje não há nada a fazer: ou se espera um turno
-- errado até o fim, ou se devolve a quadra e a fila anda cedo.
--
-- Então o administrador passa a poder dizer quanto falta. É uma
-- correção de relógio, não um favor: fica registrado quem mexeu, quando
-- e quanto, e a tela de todo mundo mostra que o tempo foi ajustado.
--
-- Zerar o tempo encerra o turno na hora — a quadra entra na troca de 1
-- minuto e o próximo começa sozinho, como em qualquer fim de turno
-- (docs/sprint6.md).
-- =====================================================================

alter table public.matches
  add column if not exists time_adjusted_at      timestamptz,
  add column if not exists time_adjusted_by      uuid references auth.users (id) on delete set null,
  add column if not exists time_adjusted_seconds integer not null default 0;

comment on column public.matches.time_adjusted_at is
  'Último ajuste de relógio feito pelo administrador neste turno.';
comment on column public.matches.time_adjusted_seconds is
  'Soma dos ajustes, em segundos. Positivo = o turno ganhou tempo.';

-- ---------------------------------------------------------------------
-- Quanto falta, dito pelo administrador
--
-- O contrato é "faltam N minutos", e não "+5" nem "-5": assim duas
-- pessoas mexendo ao mesmo tempo não somam ajustes sem perceber, e
-- repetir a chamada não muda nada. Os botões de +5 e -5 do app mandam o
-- total já calculado.
-- ---------------------------------------------------------------------
create or replace function public.admin_set_match_time(
  p_match_id          uuid,
  p_remaining_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_new   timestamptz;
  v_delta integer;
begin
  perform public.require_admin();

  if p_remaining_minutes is null
     or p_remaining_minutes < 0
     or p_remaining_minutes > 240 then
    raise exception 'O tempo restante vai de 0 a 240 minutos' using errcode = 'NQ036';
  end if;

  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    raise exception 'Este turno já foi encerrado' using errcode = 'NQ009';
  end if;

  -- Zero significa "acabou agora". Um segundo para trás, para o
  -- advance_court logo abaixo ver o turno como vencido — now() é o
  -- mesmo instante dentro da transação, e `expires_at <= now()` com os
  -- dois exatamente iguais depende de arredondamento.
  v_new := case
             when p_remaining_minutes = 0 then now() - interval '1 second'
             else now() + make_interval(mins => p_remaining_minutes)
           end;

  v_delta := round(extract(epoch from (v_new - v_match.expires_at)))::integer;

  update public.matches
     set expires_at            = v_new,
         time_adjusted_at      = now(),
         time_adjusted_by      = auth.uid(),
         time_adjusted_seconds = time_adjusted_seconds + v_delta
   where id = p_match_id;

  if p_remaining_minutes = 0 then
    perform public.advance_court(v_match.court_id);
  end if;

  return public.court_screen(v_match.court_id);
end;
$$;

revoke all on function public.admin_set_match_time(uuid, integer) from public, anon, authenticated;
grant execute on function public.admin_set_match_time(uuid, integer) to authenticated;

comment on function public.admin_set_match_time(uuid, integer) is
  'Administrador corrige quanto falta no turno em andamento. 0 encerra agora. '
  'Registra quem ajustou, quando e quanto.';

-- ---------------------------------------------------------------------
-- O ajuste aparece para todo mundo
--
-- Um relógio que pula sem explicação é pior que um relógio errado: quem
-- está em quadra acha que o app quebrou. A tela mostra que o tempo foi
-- ajustado pela organização.
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
    'time_adjusted_at',      v_match.time_adjusted_at,
    'time_adjusted_seconds', v_match.time_adjusted_seconds,
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

grant execute on function public.match_state(uuid) to anon, authenticated;
