-- Connect Hub: authenticated email/password access without a service-role key.
-- This is a forward-only migration. It keeps existing rows and game records.

-- Students can read their own private profile and update only the editable fields.
drop policy if exists "Profiles visible to signed-in students" on public.profiles;
drop policy if exists "Students read own profile" on public.profiles;
create policy "Students read own profile" on public.profiles
  for select to authenticated using (auth.uid() = id);

revoke all on public.profiles from anon;
revoke select, insert, update, delete on public.profiles from authenticated;
revoke update (full_name, department, year) on public.profiles from authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, department, year) on public.profiles to authenticated;

-- Keep the session summary view read-only and limited to public session details.
-- The view owner reads the underlying tables; the WHERE clause limits which
-- rows the view can reveal to guests and signed-in students.
create or replace view public.session_details with (security_invoker = false) as
select s.id, s.host_id, p.full_name as host_name, g.name as game_name,
       g.category, s.location, s.starts_at, s.max_players, s.notes,
       s.status, s.created_at, count(sp.student_id)::integer as participant_count
from public.game_sessions s
join public.profiles p on p.id = s.host_id
join public.games g on g.id = s.game_id
left join public.session_participants sp on sp.session_id = s.id
where s.status = 'OPEN' or s.host_id = auth.uid()
group by s.id, p.full_name, g.name, g.category;

revoke all on public.session_details from public;
grant select on public.session_details to anon, authenticated;
grant select on public.games to anon, authenticated;

-- Host ownership is enforced by RLS for any direct update/delete request.
drop policy if exists "Hosts update own sessions" on public.game_sessions;
drop policy if exists "Hosts delete own sessions" on public.game_sessions;
create policy "Hosts update own sessions" on public.game_sessions
  for update to authenticated using (host_id = auth.uid())
  with check (host_id = auth.uid());
create policy "Hosts delete own sessions" on public.game_sessions
  for delete to authenticated using (host_id = auth.uid());

revoke insert, update, delete on public.game_sessions from anon, authenticated;
grant select on public.game_sessions to authenticated;
grant update (location, starts_at, max_players, notes, status) on public.game_sessions to authenticated;
grant delete on public.game_sessions to authenticated;

-- Participation rows are private to each student. A controlled function handles
-- joins so clients cannot bypass duplicate or capacity checks with direct INSERT.
drop policy if exists "Participants readable by signed-in students" on public.session_participants;
drop policy if exists "Students read own participation" on public.session_participants;
create policy "Students read own participation" on public.session_participants
  for select to authenticated using (student_id = auth.uid());

revoke insert, update, delete on public.session_participants from anon, authenticated;
grant select on public.session_participants to authenticated;

-- Both functions derive the student ID from the verified Supabase access token.
-- They take no student ID argument and are executable only by authenticated users.
create or replace function public.create_game_session(
  p_game_name text, p_location text, p_starts_at timestamptz,
  p_max_players integer, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  session_uuid uuid;
  game_uuid uuid;
  student_uuid uuid := auth.uid();
begin
  if student_uuid is null then raise exception 'Authentication required'; end if;
  if p_starts_at <= now() then raise exception 'Session must be in the future'; end if;
  select id into game_uuid from public.games where name = p_game_name;
  if game_uuid is null then raise exception 'Unknown game'; end if;
  insert into public.game_sessions(host_id, game_id, location, starts_at, max_players, notes)
    values (student_uuid, game_uuid, p_location, p_starts_at, p_max_players, coalesce(p_notes, ''))
    returning id into session_uuid;
  insert into public.session_participants(session_id, student_id)
    values (session_uuid, student_uuid);
  return session_uuid;
end;
$$;

create or replace function public.join_game_session(p_session_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  current_session public.game_sessions%rowtype;
  member_count integer;
  student_uuid uuid := auth.uid();
begin
  if student_uuid is null then raise exception 'Authentication required'; end if;
  select * into current_session from public.game_sessions
    where id = p_session_id for update;
  if not found or current_session.status <> 'OPEN' then raise exception 'Session unavailable'; end if;
  if current_session.starts_at <= now() then raise exception 'Session is in the past'; end if;
  if exists (select 1 from public.session_participants
      where session_id = p_session_id and student_id = student_uuid) then
    raise exception 'Student already joined';
  end if;
  select count(*) into member_count from public.session_participants
    where session_id = p_session_id;
  if member_count >= current_session.max_players then raise exception 'Session is full'; end if;
  insert into public.session_participants(session_id, student_id)
    values (p_session_id, student_uuid);
  return p_session_id;
end;
$$;

revoke all on function public.create_game_session(text, text, timestamptz, integer, text) from public, anon, authenticated;
revoke all on function public.join_game_session(uuid) from public, anon, authenticated;
grant execute on function public.create_game_session(text, text, timestamptz, integer, text) to authenticated;
grant execute on function public.join_game_session(uuid) to authenticated;
