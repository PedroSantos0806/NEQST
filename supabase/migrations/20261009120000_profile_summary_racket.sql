-- =====================================================================
-- A tela de perfil precisa das cores da raquete e do tom do avatar.
--
-- my_profile_summary() nasceu na Sprint 2, antes de a Sprint 3 criar as
-- colunas. Sem elas na resposta, a tela abria sempre com a raquete
-- padrão e descartava, na primeira edição, o que o jogador já tinha
-- escolhido. Aqui ela passa a devolver o que o app precisa para
-- desenhar o jogador do jeito que ele se configurou.
-- =====================================================================

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
        'user_id',            p.id,
        'username',           p.username,
        'full_name',          p.full_name,
        'email',              p.email,
        'avatar_url',         p.avatar_url,
        'role',               p.role,
        'created_at',         p.created_at,
        'avatar_tone',        p.avatar_tone,
        'racket_frame_color', p.racket_frame_color,
        'racket_grip_color',  p.racket_grip_color
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
  'Uma chamada para a tela de perfil: dados, raquete, estatísticas e filas ativas.';

revoke all on function public.my_profile_summary() from public;
grant execute on function public.my_profile_summary() to authenticated;
