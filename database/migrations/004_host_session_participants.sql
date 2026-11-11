-- Give a session host a safe, minimal view of its participant roster.
-- Existing tables, rows, and RLS policies remain unchanged.
create or replace function public.get_host_session_participants(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  session_capacity integer;
  roster jsonb;
  player_total integer;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select s.max_players into session_capacity
  from public.game_sessions s
  where s.id = p_session_id and s.host_id = current_user_id;

  if not found then
    raise exception 'Only the session host can view its participants' using errcode = '42501';
  end if;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'full_name', p.full_name,
          'username', p.username,
          'is_host', sp.student_id = current_user_id
        ) order by (sp.student_id = current_user_id) desc, p.username
      ),
      '[]'::jsonb
    ),
    count(*)::integer
  into roster, player_total
  from public.session_participants sp
  join public.profiles p on p.id = sp.student_id
  where sp.session_id = p_session_id;

  return jsonb_build_object(
    'participants', roster,
    'total_players', player_total,
    'max_players', session_capacity,
    'remaining_slots', greatest(session_capacity - player_total, 0)
  );
end;
$$;

revoke all on function public.get_host_session_participants(uuid) from public, anon, authenticated;
grant execute on function public.get_host_session_participants(uuid) to authenticated;
