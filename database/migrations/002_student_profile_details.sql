alter table public.profiles add column if not exists email text;
update public.profiles p set email=u.email from auth.users u where u.id=p.id and p.email is null;
alter table public.profiles alter column email set not null;
do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_email_key') then
  alter table public.profiles add constraint profiles_email_key unique(email);
 end if;
end; $$;
alter table public.profiles add column if not exists department text not null default 'Undeclared';
alter table public.profiles add column if not exists year integer not null default 1;
alter table public.profiles drop constraint if exists profiles_year_check;
alter table public.profiles add constraint profiles_year_check check(year between 1 and 6);
create or replace function public.create_profile_for_student()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,email,full_name,username,roll_number,department,year)
 values(new.id,new.email,new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'username',new.raw_user_meta_data->>'roll_number',coalesce(new.raw_user_meta_data->>'department','Undeclared'),coalesce((new.raw_user_meta_data->>'year')::integer,1));
 return new;
end; $$;
grant update(full_name,department,year) on public.profiles to authenticated;
revoke select on public.profiles from anon,authenticated;

-- Use the caller's JWT for game mutations so RLS and auth.uid() enforce ownership.
create or replace function public.create_game_session(p_game_name text,p_location text,p_starts_at timestamptz,p_max_players integer,p_notes text default '') returns uuid language plpgsql set search_path=public,pg_temp as $$
declare session_uuid uuid; game_uuid uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_starts_at<=now() then raise exception 'Session must be in the future'; end if;
 select id into game_uuid from public.games where name=p_game_name;
 if game_uuid is null then raise exception 'Unknown game'; end if;
 insert into public.game_sessions(host_id,game_id,location,starts_at,max_players,notes) values(auth.uid(),game_uuid,p_location,p_starts_at,p_max_players,coalesce(p_notes,'')) returning id into session_uuid;
 insert into public.session_participants(session_id,student_id) values(session_uuid,auth.uid()); return session_uuid;
end; $$;
create or replace function public.join_game_session(p_session_id uuid) returns uuid language plpgsql set search_path=public,pg_temp as $$
declare current_session public.game_sessions%rowtype; member_count integer;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into current_session from public.game_sessions where id=p_session_id for update;
 if not found or current_session.status<>'OPEN' then raise exception 'Session unavailable'; end if;
 if current_session.starts_at<=now() then raise exception 'Session is in the past'; end if;
 if exists(select 1 from public.session_participants where session_id=p_session_id and student_id=auth.uid()) then raise exception 'Student already joined'; end if;
 select count(*) into member_count from public.session_participants where session_id=p_session_id;
 if member_count>=current_session.max_players then raise exception 'Session is full'; end if;
 insert into public.session_participants(session_id,student_id) values(p_session_id,auth.uid()); return p_session_id;
end; $$;
revoke all on function public.create_game_session(uuid,text,text,timestamptz,integer,text) from public,anon,authenticated;
revoke all on function public.join_game_session(uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_game_session(text,text,timestamptz,integer,text) from public,anon;
revoke all on function public.join_game_session(uuid) from public,anon;
grant execute on function public.create_game_session(text,text,timestamptz,integer,text) to authenticated;
grant execute on function public.join_game_session(uuid) to authenticated;
grant insert on public.game_sessions,public.session_participants to authenticated;
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='game_sessions' and policyname='Students create own sessions') then
  create policy "Students create own sessions" on public.game_sessions for insert to authenticated with check(host_id=auth.uid());
 end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='session_participants' and policyname='Students join as themselves') then
  create policy "Students join as themselves" on public.session_participants for insert to authenticated with check(student_id=auth.uid());
 end if;
end $$;
