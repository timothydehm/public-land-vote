-- =====================================================================
-- Land Bank Program Vote: the database
--
-- A companion to the Public Land Voting Tool, in the same Supabase
-- project (parcel-vote). One map: every lot in the city's land bank, and
-- three choices that match the city's programs (open space, yard
-- expansion, development). Voters vote with a passkey; an organizer
-- issues passkeys in labeled batches, each with its own votes per choice.
--
-- It reuses the Public Land Voting Tool's lot list (pv_parcels, synced
-- hourly from the city) and its helpers (pv_norm, pv_hash, pv_rand,
-- pv_words, pv_over, pv_note, pv_err), so run the main schema.sql first.
-- It changes nothing that belongs to the Public Land Voting Tool.
--
-- Run this whole file in the Supabase SQL editor. It's safe to run again.
-- The first run ends by showing the organizer key, once. Keep it.
--
-- Tables
--   lp_settings  the hash of the organizer key (the key itself is never stored)
--   lp_batches   a batch of passkeys: label, and votes per choice
--   lp_keys      passkeys. One per voter; readable only with the organizer key.
--   lp_votes     current votes: lot, voter number, choice, time. Public.
--   lp_history   every vote, change, and take-back, append-only. Public.
-- =====================================================================

do $$ begin
  if to_regclass('public.pv_parcels') is null or to_regprocedure('public.pv_words()') is null then
    raise exception 'Run the Public Land Voting Tool''s schema.sql first; this builds on its lot list and helpers.';
  end if;
end $$;


-- ------------------------------------------------------------------ tables

create table if not exists lp_settings (
  id         boolean primary key default true check (id),
  key_hash   text,                            -- sha-256 of the organizer key
  set_at     timestamptz
);
insert into lp_settings (id) values (true) on conflict (id) do nothing;

create table if not exists lp_batches (
  id          int generated always as identity primary key,
  label       text not null check (length(label) between 1 and 80),
  open_space      int not null check (open_space between 0 and 100),       -- votes per voter for each choice
  yard_expansion  int not null check (yard_expansion between 0 and 100),
  development     int not null check (development between 0 and 100),
  created_at  timestamptz not null default now(),
  check (open_space + yard_expansion + development > 0)
);

create sequence if not exists lp_voter_seq;

create table if not exists lp_keys (
  code       text primary key,                -- 8 characters, no dash
  batch_id   int not null references lp_batches(id) on delete cascade,
  voter      int not null unique default nextval('lp_voter_seq'),
  created_at timestamptz not null default now(),
  used_at    timestamptz                      -- first vote
);

create table if not exists lp_votes (
  parcel_id text not null references pv_parcels(id),
  voter     int not null references lp_keys(voter) on delete cascade,
  choice    text not null check (choice in ('open_space', 'yard_expansion', 'development')),
  at        timestamptz not null default now(),
  primary key (parcel_id, voter)
);
create index if not exists lp_votes_by_voter on lp_votes (voter, choice);

create table if not exists lp_history (
  id        bigint generated always as identity primary key,
  parcel_id text not null,
  voter     int not null,
  choice    text,
  action    text not null check (action in ('vote', 'change', 'take back')),
  at        timestamptz not null default now()
);
create index if not exists lp_history_by_time on lp_history (at);


-- ----------------------------------------------------------------- helpers

create or replace function lp_budget(b lp_batches, p_choice text) returns int
language sql immutable set search_path = public as $$
  select case p_choice when 'open_space' then b.open_space when 'yard_expansion' then b.yard_expansion
                       when 'development' then b.development end
$$;

create or replace function lp_budgets(b lp_batches) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('open_space', b.open_space, 'yard_expansion', b.yard_expansion, 'development', b.development)
$$;

create or replace function lp_issue_keys(p_batch int, p_n int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c text; out jsonb := '[]';
begin
  for i in 1..p_n loop
    loop c := pv_rand(8); exit when not exists (select 1 from lp_keys where code = c); end loop;
    insert into lp_keys (code, batch_id) values (c, p_batch);
    out := out || to_jsonb(c);
  end loop;
  return out;
end $$;

-- Makes a new organizer key and returns it. The old one stops working.
-- Run by hand in the SQL editor only: select lp_new_organizer_key();
create or replace function lp_new_organizer_key() returns text
language plpgsql security definer set search_path = public as $$
declare k text := pv_words();
begin
  update lp_settings set key_hash = pv_hash(pv_norm_key(k)), set_at = now();
  return k;
end $$;

create or replace function lp_org_ok(p_key text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if pv_over('lp-miss', 30, interval '10 minutes') then raise exception 'too_many_attempts'; end if;
  if exists (select 1 from lp_settings where key_hash is not null and key_hash = pv_hash(pv_norm_key(p_key))) then return true; end if;
  perform pv_note('lp-miss'); return false;
end $$;


-- ------------------------------------------------------------ public view

-- Turnout and totals, and the batches (labels, votes per choice, turnout). Never passkeys.
create or replace function lp_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'issued', (select count(*) from lp_keys),
    'used',   (select count(*) from lp_keys where used_at is not null),
    'votes',  (select count(*) from lp_votes),
    'lots',   (select count(distinct parcel_id) from lp_votes),
    'by', jsonb_build_object(
      'open_space',     (select count(*) from lp_votes where choice = 'open_space'),
      'yard_expansion', (select count(*) from lp_votes where choice = 'yard_expansion'),
      'development',    (select count(*) from lp_votes where choice = 'development')),
    'organizer', (select key_hash is not null from lp_settings),
    'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'label', b.label, 'budgets', lp_budgets(b), 'created_at', b.created_at,
                   'issued', (select count(*) from lp_keys k where k.batch_id = b.id),
                   'used',   (select count(*) from lp_keys k where k.batch_id = b.id and k.used_at is not null)) order by b.id)
                 from lp_batches b), '[]'))
$$;

create or replace function lp_tally() returns jsonb   -- [[parcel, open space, yard expansion, development], ...]
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(parcel_id, o, y, d)), '[]')
  from (select parcel_id,
               count(*) filter (where choice = 'open_space') o,
               count(*) filter (where choice = 'yard_expansion') y,
               count(*) filter (where choice = 'development') d
        from lp_votes group by parcel_id) t
$$;

create or replace function lp_record() returns jsonb   -- every current vote, for download
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('parcel', v.parcel_id, 'choice', v.choice, 'voter', v.voter,
           'batch', b.label, 'at', v.at) order by v.at), '[]')
  from lp_votes v join lp_keys k on k.voter = v.voter join lp_batches b on b.id = k.batch_id
$$;


-- ------------------------------------------------------------------ voting

create or replace function lp_join(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k lp_keys; b lp_batches;
begin
  if pv_over('lp-miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
  select * into k from lp_keys where code = pv_norm(p_code);
  if not found then perform pv_note('lp-miss'); return pv_err('key_not_found'); end if;
  select * into b from lp_batches where id = k.batch_id;
  return jsonb_build_object('voter', k.voter, 'batch', b.label, 'budgets', lp_budgets(b));
end $$;

create or replace function lp_vote(p_code text, p_parcel text, p_choice text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k lp_keys; b lp_batches; pid text := pv_norm(p_parcel); cur text; used int; lim int;
begin
  if p_choice is null or p_choice not in ('open_space', 'yard_expansion', 'development') then return pv_err('bad_choice'); end if;
  select * into k from lp_keys where code = pv_norm(p_code);
  if not found then
    if pv_over('lp-miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('lp-miss'); return pv_err('not_voter');
  end if;
  perform pg_advisory_xact_lock(hashtext('lp-voter:' || k.voter));
  if not exists (select 1 from pv_parcels where id = pid and status = 'public') then return pv_err('parcel_not_found'); end if;
  select choice into cur from lp_votes where parcel_id = pid and voter = k.voter;
  if cur = p_choice then return jsonb_build_object('ok', true); end if;
  select * into b from lp_batches where id = k.batch_id;
  lim := lp_budget(b, p_choice);
  select count(*) into used from lp_votes where voter = k.voter and choice = p_choice;
  if lim = 0 then return pv_err('choice_off'); end if;
  if used >= lim then return pv_err('budget_used'); end if;
  if cur is null then
    insert into lp_votes (parcel_id, voter, choice) values (pid, k.voter, p_choice);
    insert into lp_history (parcel_id, voter, choice, action) values (pid, k.voter, p_choice, 'vote');
  else
    update lp_votes set choice = p_choice, at = now() where parcel_id = pid and voter = k.voter;
    insert into lp_history (parcel_id, voter, choice, action) values (pid, k.voter, p_choice, 'change');
  end if;
  update lp_keys set used_at = coalesce(used_at, now()) where code = k.code;
  return jsonb_build_object('ok', true, 'left', lim - used - 1, 'was', cur);
end $$;

create or replace function lp_unvote(p_code text, p_parcel text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k lp_keys; pid text := pv_norm(p_parcel); cur text;
begin
  select * into k from lp_keys where code = pv_norm(p_code);
  if not found then
    if pv_over('lp-miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('lp-miss'); return pv_err('not_voter');
  end if;
  perform pg_advisory_xact_lock(hashtext('lp-voter:' || k.voter));
  delete from lp_votes where parcel_id = pid and voter = k.voter returning choice into cur;
  if found then insert into lp_history (parcel_id, voter, choice, action) values (pid, k.voter, cur, 'take back'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function lp_mine(p_code text) returns jsonb   -- [[parcel, choice], ...] for this passkey
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(v.parcel_id, v.choice)), '[]')
  from lp_keys k join lp_votes v on v.voter = k.voter
  where k.code = pv_norm(p_code)
$$;


-- --------------------------------------------------------------- organizer

-- Every batch with its passkeys and their first use.
create or replace function lp_org_batches(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not lp_org_ok(p_key) then return pv_err('bad_key'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'label', b.label, 'budgets', lp_budgets(b), 'created_at', b.created_at,
            'keys', coalesce((select jsonb_agg(jsonb_build_object('code', k.code, 'voter', k.voter, 'used_at', k.used_at) order by k.voter)
                              from lp_keys k where k.batch_id = b.id), '[]')) order by b.id desc)
          from lp_batches b), '[]');
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

create or replace function lp_new_batch(p_key text, p_label text, p_n int, p_open int, p_yard int, p_dev int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l text := trim(coalesce(p_label, '')); bid int;
begin
  if l = '' or length(l) > 80 then return pv_err('bad_label'); end if;
  if p_n is null or p_n < 1 or p_n > 1000 then return pv_err('bad_count'); end if;
  if coalesce(p_open, -1) not between 0 and 100 or coalesce(p_yard, -1) not between 0 and 100 or coalesce(p_dev, -1) not between 0 and 100
     or p_open + p_yard + p_dev = 0 then return pv_err('bad_budget'); end if;
  if not lp_org_ok(p_key) then return pv_err('bad_key'); end if;
  insert into lp_batches (label, open_space, yard_expansion, development) values (l, p_open, p_yard, p_dev) returning id into bid;
  return jsonb_build_object('batch', bid, 'keys', lp_issue_keys(bid, p_n));
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

create or replace function lp_add_keys(p_key text, p_batch int, p_n int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_n is null or p_n < 1 or p_n > 1000 then return pv_err('bad_count'); end if;
  if not lp_org_ok(p_key) then return pv_err('bad_key'); end if;
  if not exists (select 1 from lp_batches where id = p_batch) then return pv_err('batch_not_found'); end if;
  return lp_issue_keys(p_batch, p_n);
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

create or replace function lp_org_check(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if lp_org_ok(p_key) then return jsonb_build_object('ok', true); end if;
  return pv_err('bad_key');
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;


-- ------------------------------------------------------------------ access

alter table lp_settings enable row level security;
alter table lp_batches  enable row level security;
alter table lp_keys     enable row level security;
alter table lp_votes    enable row level security;
alter table lp_history  enable row level security;

-- Votes and their history are open to everyone. Batches are read through lp_info; passkeys and the key hash are private.
do $$
declare t text;
begin
  foreach t in array array['lp_votes', 'lp_history'] loop
    execute format('drop policy if exists "Anyone can read" on %I', t);
    execute format('create policy "Anyone can read" on %I for select using (true)', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to anon, authenticated', t);
  end loop;
end $$;
revoke all on lp_settings, lp_batches, lp_keys from anon, authenticated;
revoke all on sequence lp_voter_seq from anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'lp\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function lp_info()                                     to anon, authenticated;
grant execute on function lp_tally()                                    to anon, authenticated;
grant execute on function lp_record()                                   to anon, authenticated;
grant execute on function lp_join(text)                                 to anon, authenticated;
grant execute on function lp_vote(text, text, text)                     to anon, authenticated;
grant execute on function lp_unvote(text, text)                         to anon, authenticated;
grant execute on function lp_mine(text)                                 to anon, authenticated;
grant execute on function lp_org_check(text)                            to anon, authenticated;
grant execute on function lp_org_batches(text)                          to anon, authenticated;
grant execute on function lp_new_batch(text, text, int, int, int, int)  to anon, authenticated;
grant execute on function lp_add_keys(text, int, int)                   to anon, authenticated;
-- lp_new_organizer_key() stays private: only the SQL editor can make a key.


-- -------------------------------------------- the organizer key, first run only
-- Shows the key once. Running the file again won't replace it; to replace a lost key,
-- run:  select lp_new_organizer_key();   (the old key stops working)
select case when (select key_hash from lp_settings) is null
            then 'Organizer key (keep it; it is shown only this once): ' || lp_new_organizer_key()
            else 'The organizer key is already set. To replace it, run: select lp_new_organizer_key();'
       end as organizer_key;
