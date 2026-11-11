create extension if not exists pgcrypto;
create type public.game_category as enum ('INDOOR','OUTDOOR');
create type public.session_status as enum ('OPEN','CANCELLED','COMPLETED');
create table public.profiles(id uuid primary key references auth.users(id) on delete cascade,email text not null unique,full_name text not null check(char_length(full_name) between 2 and 80),username text not null unique check(username~'^[A-Za-z0-9_]{3,24}$'),roll_number text not null unique check(char_length(roll_number) between 2 and 32),department text not null default 'Undeclared',year integer not null default 1 check(year between 1 and 6),created_at timestamptz not null default now());
create table public.games(id uuid primary key default gen_random_uuid(),name text not null unique,category public.game_category not null,description text not null,created_at timestamptz not null default now());
create table public.game_sessions(id uuid primary key default gen_random_uuid(),host_id uuid not null references public.profiles(id) on delete cascade,game_id uuid not null references public.games(id) on delete restrict,location text not null check(char_length(location) between 2 and 100),starts_at timestamptz not null,max_players integer not null check(max_players between 2 and 30),notes text not null default '' check(char_length(notes)<=240),status public.session_status not null default 'OPEN',created_at timestamptz not null default now());
create table public.session_participants(session_id uuid not null references public.game_sessions(id) on delete cascade,student_id uuid not null references public.profiles(id) on delete cascade,joined_at timestamptz not null default now(),primary key(session_id,student_id));
create index game_sessions_starts_at_open_idx on public.game_sessions(starts_at) where status='OPEN';
create index game_sessions_game_idx on public.game_sessions(game_id,starts_at);
create index session_participants_student_idx on public.session_participants(student_id);
create view public.session_details with(security_invoker=true) as select s.id,s.host_id,p.full_name as host_name,g.name as game_name,g.category,s.location,s.starts_at,s.max_players,s.notes,s.status,s.created_at,count(sp.student_id)::integer as participant_count from public.game_sessions s join public.profiles p on p.id=s.host_id join public.games g on g.id=s.game_id left join public.session_participants sp on sp.session_id=s.id group by s.id,p.full_name,g.name,g.category;
create or replace function public.create_profile_for_student() returns trigger language plpgsql security definer set search_path=public as $$
 begin insert into public.profiles(id,email,full_name,username,roll_number,department,year) values(new.id,new.email,new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'username',new.raw_user_meta_data->>'roll_number',coalesce(new.raw_user_meta_data->>'department','Undeclared'),coalesce((new.raw_user_meta_data->>'year')::integer,1)); return new; end; $$;
create trigger on_auth_student_created after insert on auth.users for each row execute procedure public.create_profile_for_student();
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
insert into public.games(name,category,description) values
('Chess','INDOOR','Quiet strategy, sharp minds. Find your next worthy opponent.'),('Carrom','INDOOR','A little flick, a little finesse. The board is waiting.'),('Table Tennis','INDOOR','Fast rallies and friendly rivalry, right around the corner.'),('Cricket','OUTDOOR','One more over? Find a side and make it happen.'),('Football','OUTDOOR','Pick-up game, big energy. Your team is one tap away.'),('Badminton','OUTDOOR','Trade clears and smashes with players on campus.'),('Volleyball','OUTDOOR','Build a team, get a rally going, play together.'),('Basketball','OUTDOOR','Shoot hoops with people who are always up for one.') on conflict(name) do nothing;
alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.game_sessions enable row level security;
alter table public.session_participants enable row level security;
create policy "Profiles visible to signed-in students" on public.profiles for select to authenticated using(true);
create policy "Students update own profile" on public.profiles for update to authenticated using(auth.uid()=id) with check(auth.uid()=id);
create policy "Games readable by everyone" on public.games for select using(true);
create policy "Open sessions readable" on public.game_sessions for select using(status='OPEN' or host_id=auth.uid());
create policy "Students create own sessions" on public.game_sessions for insert to authenticated with check(host_id=auth.uid());
create policy "Participants readable by signed-in students" on public.session_participants for select to authenticated using(true);
create policy "Students join as themselves" on public.session_participants for insert to authenticated with check(student_id=auth.uid());
grant select on public.session_details to anon,authenticated;
grant select on public.games to anon,authenticated;
grant update(full_name,department,year) on public.profiles to authenticated;
revoke select on public.profiles from anon,authenticated;
grant select on public.game_sessions,public.session_participants to authenticated;
grant insert on public.game_sessions,public.session_participants to authenticated;
revoke all on function public.create_game_session(text,text,timestamptz,integer,text) from public,anon;
revoke all on function public.join_game_session(uuid) from public,anon;
grant execute on function public.create_game_session(text,text,timestamptz,integer,text) to authenticated;
grant execute on function public.join_game_session(uuid) to authenticated;
