-- RACKBET database setup for Supabase.
-- Run the whole file once in Supabase > SQL Editor.
-- Virtual points only. No deposits, cash value, transfers or withdrawals.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (char_length(username) between 3 and 20),
  points integer not null default 1000 check (points >= 0),
  wins integer not null default 0,
  losses integer not null default 0,
  is_admin boolean not null default false,
  last_daily_claim date,
  created_at timestamptz not null default now()
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  player1_id uuid not null references public.profiles(id),
  player2_id uuid not null references public.profiles(id),
  game_type text not null default '8-ball',
  scheduled_at timestamptz,
  odds1 numeric(5,2) not null default 1.90 check (odds1 between 1.01 and 20),
  odds2 numeric(5,2) not null default 1.90 check (odds2 between 1.01 and 20),
  status text not null default 'open' check (status in ('open','live','settled','cancelled')),
  winner_id uuid references public.profiles(id),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  constraint different_players check (player1_id <> player2_id),
  constraint winner_is_player check (winner_id is null or winner_id in (player1_id, player2_id))
);

create table if not exists public.bets (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id),
  user_id uuid not null references public.profiles(id),
  selection uuid not null references public.profiles(id),
  stake integer not null check (stake >= 10 and stake <= 5000),
  odds numeric(5,2) not null,
  potential_payout integer not null,
  status text not null default 'pending' check (status in ('pending','won','lost','refunded')),
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  constraint one_bet_per_user_per_match unique (match_id, user_id)
);

create index if not exists matches_status_created_idx on public.matches(status, created_at desc);
create index if not exists bets_user_created_idx on public.bets(user_id, created_at desc);
create index if not exists bets_match_idx on public.bets(match_id);

-- Create a profile automatically. Username is taken from signup metadata.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare chosen_username text;
begin
  chosen_username := coalesce(nullif(trim(new.raw_user_meta_data->>'username'), ''), 'player_' || substr(new.id::text, 1, 8));
  insert into public.profiles(id, username, points)
  values(new.id, chosen_username, 1000);
  return new;
exception when unique_violation then
  raise exception 'Käyttäjänimi on jo käytössä. Valitse toinen käyttäjänimi.';
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.matches enable row level security;
alter table public.bets enable row level security;

-- Profiles are public for the open league leaderboard and match display.
drop policy if exists "Profiles readable by everyone" on public.profiles;
create policy "Profiles readable by everyone" on public.profiles for select using (true);
drop policy if exists "Matches readable by everyone" on public.matches;
create policy "Matches readable by everyone" on public.matches for select using (true);
drop policy if exists "Authenticated users create matches" on public.matches;
create policy "Authenticated users create matches" on public.matches for insert to authenticated
with check (auth.uid() = created_by);
drop policy if exists "Users read own bets" on public.bets;
create policy "Users read own bets" on public.bets for select to authenticated using (auth.uid() = user_id);
-- No direct client insert/update/delete policies on bets. All money-like point changes
-- happen atomically in the security-definer RPCs below.

create or replace function public.claim_daily_points()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Kirjaudu sisään.'; end if;
  update public.profiles
    set points = points + 100, last_daily_claim = current_date
    where id = uid and (last_daily_claim is null or last_daily_claim < current_date);
  if not found then raise exception 'Päiväpisteet on jo kerätty tänään.'; end if;
  return jsonb_build_object('message', '100 päiväpistettä lisätty!');
end;
$$;

create or replace function public.place_bet(p_match_id uuid, p_selection uuid, p_stake integer)
returns uuid language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid(); m public.matches%rowtype; chosen_odds numeric(5,2); new_id uuid;
begin
  if uid is null then raise exception 'Kirjaudu sisään.'; end if;
  if p_stake < 10 or p_stake > 5000 then raise exception 'Panos pitää olla 10–5 000 pistettä.'; end if;
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Ottelua ei löydy.'; end if;
  if m.status <> 'open' then raise exception 'Vetoaika on päättynyt.'; end if;
  if uid in (m.player1_id, m.player2_id) then raise exception 'Ottelun pelaajat eivät voi lyödä vetoa omaan otteluunsa.'; end if;
  if p_selection = m.player1_id then chosen_odds := m.odds1;
  elsif p_selection = m.player2_id then chosen_odds := m.odds2;
  else raise exception 'Virheellinen voittajavalinta.'; end if;
  update public.profiles set points = points - p_stake where id = uid and points >= p_stake;
  if not found then raise exception 'Pisteet eivät riitä.'; end if;
  insert into public.bets(match_id, user_id, selection, stake, odds, potential_payout)
  values(p_match_id, uid, p_selection, p_stake, chosen_odds, floor(p_stake * chosen_odds)::integer)
  returning id into new_id;
  return new_id;
exception when unique_violation then
  raise exception 'Olet jo asettanut vedon tähän otteluun.';
end;
$$;

create or replace function public.start_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare m public.matches%rowtype; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Kirjaudu sisään.'; end if;
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Ottelua ei löydy.'; end if;
  if not (uid = m.created_by or exists(select 1 from public.profiles p where p.id = uid and p.is_admin)) then
    raise exception 'Vain ottelun luoja tai ylläpitäjä voi aloittaa ottelun.';
  end if;
  if m.status <> 'open' then raise exception 'Ottelu ei ole enää avoin.'; end if;
  update public.matches set status = 'live' where id = p_match_id;
end;
$$;

create or replace function public.settle_match(p_match_id uuid, p_winner_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare m public.matches%rowtype; uid uuid := auth.uid(); b record;
begin
  if uid is null then raise exception 'Kirjaudu sisään.'; end if;
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Ottelua ei löydy.'; end if;
  if not (uid = m.created_by or exists(select 1 from public.profiles p where p.id = uid and p.is_admin)) then
    raise exception 'Vain ottelun luoja tai ylläpitäjä voi vahvistaa tuloksen.';
  end if;
  if m.status not in ('open','live') then raise exception 'Ottelua ei voi enää ratkaista.'; end if;
  if p_winner_id not in (m.player1_id, m.player2_id) then raise exception 'Voittajan täytyy olla ottelun pelaaja.'; end if;
  update public.matches set status = 'settled', winner_id = p_winner_id, settled_at = now() where id = p_match_id;
  update public.profiles set wins = wins + 1 where id = p_winner_id;
  update public.profiles set losses = losses + 1 where id = case when p_winner_id = m.player1_id then m.player2_id else m.player1_id end;
  for b in select * from public.bets where match_id = p_match_id and status = 'pending' for update loop
    if b.selection = p_winner_id then
      update public.profiles set points = points + b.potential_payout where id = b.user_id;
      update public.bets set status = 'won', settled_at = now() where id = b.id;
    else
      update public.bets set status = 'lost', settled_at = now() where id = b.id;
    end if;
  end loop;
end;
$$;

create or replace function public.cancel_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare m public.matches%rowtype; uid uuid := auth.uid(); b record;
begin
  if uid is null then raise exception 'Kirjaudu sisään.'; end if;
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Ottelua ei löydy.'; end if;
  if not (uid = m.created_by or exists(select 1 from public.profiles p where p.id = uid and p.is_admin)) then
    raise exception 'Vain ottelun luoja tai ylläpitäjä voi perua ottelun.';
  end if;
  if m.status not in ('open','live') then raise exception 'Ottelua ei voi enää perua.'; end if;
  update public.matches set status = 'cancelled' where id = p_match_id;
  for b in select * from public.bets where match_id = p_match_id and status = 'pending' for update loop
    update public.profiles set points = points + b.stake where id = b.user_id;
    update public.bets set status = 'refunded', settled_at = now() where id = b.id;
  end loop;
end;
$$;

-- A creator can move their own match from open to live; no other direct updates
-- are exposed in the UI. Result settlement/cancellation must use the RPCs above.
revoke all on function public.claim_daily_points() from public;
revoke all on function public.place_bet(uuid, uuid, integer) from public;
revoke all on function public.start_match(uuid) from public;
revoke all on function public.settle_match(uuid, uuid) from public;
revoke all on function public.cancel_match(uuid) from public;
grant execute on function public.claim_daily_points() to authenticated;
grant execute on function public.place_bet(uuid, uuid, integer) to authenticated;
grant execute on function public.start_match(uuid) to authenticated;
grant execute on function public.settle_match(uuid, uuid) to authenticated;
grant execute on function public.cancel_match(uuid) to authenticated;
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.matches to anon, authenticated;
grant select on public.bets to authenticated;
grant insert on public.matches to authenticated;

-- Realtime: enable from Supabase Dashboard if not already enabled for these tables.
