-- =====================================================================
-- Public Land Voting Tool: the database
--
-- The record that everything else serves: every map a coalition makes,
-- its invite codes, and every vote, keyed by the city's parcel number.
-- The page talks to it only through the pv_* functions below; nobody
-- writes to the tables directly.
--
-- Run this whole file in the Supabase SQL editor. It's safe to run again.
-- The first time, it also moves over the lot list and city sync from the
-- earlier Cleveland Land Ballot build and removes that build's tables.
--
-- Tables
--   pv_parcels   the city's land bank inventory, synced hourly. Lots the
--                city stops publishing are archived, never deleted, so
--                their votes stay in the record.
--   pv_maps      a coalition's map: its kind, question, steward, votes per
--                member, on-site rule, and the hash of the steward key.
--                Two kinds: a question map (a vote means "yes" to the
--                coalition's question) and a land bank map (three fixed
--                answers matching the city's land bank programs: open
--                space, development, yard expansion, each with its own
--                number of votes per member).
--                A map can have a leader: one member whose votes are shown
--                as the map's recommendation, under the leader's name. They
--                count like anyone else's.
--   pv_codes     invite codes. One per member, in labeled groups; readable
--                only through the steward key. Group labels are public.
--                The leader's code is one of them (pv_maps.leader_member).
--   pv_votes     current votes: map, parcel, member number, answer (land
--                bank maps), time, and the on-site yes/no on on-site maps.
--                One vote per lot per member. Public. The leader's votes can
--                carry a one-line note (why).
--   pv_history   every vote, change, and take-back, append-only. Public.
--   pv_share_log each time a map's leader sent the map to decision-makers
--                (council, CDC, planner, land bank): when, which offices
--                (public officials' office and name only, never an email),
--                and the turnout and top lots at that moment. Append-only
--                and public. A map with entries can't be deleted, only
--                closed to voting (pv_maps.closed_at).
--   pv_sync      where the lots come from and how the last sync went.
--   pv_attempts  rate limiting by network address.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
do $$ begin
  create extension if not exists http with schema extensions;
exception when others then raise notice 'http extension not available here; the city sync will not run: %', sqlerrm; end $$;
do $$ begin
  create extension if not exists pg_cron;
exception when others then raise notice 'pg_cron not available here; the city sync will not be scheduled: %', sqlerrm; end $$;


-- -------------------------------------- moving over from the Land Ballot build
-- Keep the lot list and sync settings; remove the green/grey voting tables.
do $$
declare f regprocedure;
begin
  if to_regclass('public.lb_parcels') is not null and to_regclass('public.pv_parcels') is null then
    alter table lb_parcels rename to pv_parcels;
  end if;
  if to_regclass('public.lb_sync') is not null and to_regclass('public.pv_sync') is null then
    alter table lb_sync rename to pv_sync;
  end if;
  drop view if exists lb_green_grey, lb_tally_by_parcel;
  drop table if exists lb_votes, lb_history, lb_totals, lb_submissions, lb_map_parcels, lb_maps, lb_voters, lb_attempts cascade;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'lb\_%' loop
    execute format('drop function %s', f);
  end loop;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'lb-city-sync';
  end if;
end $$;


-- ------------------------------------------------------------------ tables

create table if not exists pv_parcels (
  id          text primary key,              -- letters and digits of the parcel number, uppercase: 10131002
  pin         text not null,                 -- as the city publishes it
  address     text,
  category    text,
  status      text not null default 'public' check (status in ('public', 'archived')),
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  archived_at timestamptz
);

create table if not exists pv_sync (
  id             boolean primary key default true check (id),
  layer_url      text not null,
  id_field       text not null,
  address_field  text,
  category_field text,
  last_edit      bigint,
  last_run       timestamptz,
  last_ok        timestamptz,
  last_result    jsonb
);
insert into pv_sync (layer_url, id_field, address_field, category_field) values (
  'https://services3.arcgis.com/dty2kHktVXHrqO8i/arcgis/rest/services/City_Landbank/FeatureServer/0',
  'parcelpin', 'par_addr_all', 'cityLandBankType')
on conflict (id) do nothing;

create table if not exists pv_maps (
  id         text primary key check (id ~ '^[a-z0-9]{4,12}$'),
  question   text not null check (length(question) between 1 and 200),
  steward    text check (length(steward) <= 80),
  kind       text not null default 'question' check (kind in ('question', 'land_bank')),
  budget     int check (budget between 1 and 100),          -- question maps: votes per member
  budgets    jsonb,                          -- land bank maps: {"open_space": n, "development": n, "yard_expansion": n}
  onsite     boolean not null default false,
  key_hash   text not null,                  -- sha-256 of the steward key; the key itself is never stored
  members    int not null default 0,         -- member numbers handed out so far
  created_at timestamptz not null default now()
);

create table if not exists pv_codes (
  code       text primary key,               -- 8 characters, no dash
  map_id     text not null references pv_maps(id) on delete cascade,
  member     int not null,
  created_at timestamptz not null default now(),
  used_at    timestamptz,                    -- first vote
  label      text check (length(label) <= 80),   -- the code's group ("Hough training, Oct 12"). Public.
  unique (map_id, member)
);

create table if not exists pv_votes (
  map_id    text not null,
  parcel_id text not null references pv_parcels(id),
  member    int not null,
  choice    text,                            -- land bank maps: open_space, development or yard_expansion. Null on question maps.
  onsite    boolean,                         -- on-site maps only: was the vote cast at the lot. Never a location.
  at        timestamptz not null default now(),
  primary key (map_id, parcel_id, member),
  foreign key (map_id, member) references pv_codes(map_id, member) on delete cascade
);
create index if not exists pv_votes_by_parcel on pv_votes (parcel_id);

create table if not exists pv_history (
  id        bigint generated always as identity primary key,
  map_id    text not null,
  parcel_id text not null,
  member    int not null,
  action    text not null check (action in ('vote', 'change', 'take back')),
  choice    text,
  onsite    boolean,
  at        timestamptz not null default now()
);
create index if not exists pv_history_by_map on pv_history (map_id, at);

-- Land bank maps (Oct 2026). Brings a database made before them up to date; existing maps become question maps.
alter table pv_maps    add column if not exists kind text not null default 'question' check (kind in ('question', 'land_bank'));
alter table pv_maps    add column if not exists budgets jsonb;
alter table pv_maps    alter column budget drop not null;
alter table pv_maps    drop constraint if exists pv_maps_terms;
alter table pv_maps    add constraint pv_maps_terms check ((kind = 'question' and budget is not null) or (kind = 'land_bank' and budgets is not null));
alter table pv_codes   add column if not exists label text check (length(label) <= 80);
alter table pv_votes   add column if not exists choice text;
alter table pv_votes   drop constraint if exists pv_votes_choice;
alter table pv_votes   add constraint pv_votes_choice check (choice is null or choice in ('open_space', 'development', 'yard_expansion'));
alter table pv_history add column if not exists choice text;
alter table pv_history drop constraint if exists pv_history_action_check;
alter table pv_history add constraint pv_history_action_check check (action in ('vote', 'change', 'take back'));
create index if not exists pv_votes_by_member on pv_votes (map_id, member, choice);
-- Leaders (Oct 15, 2026): a map's leader is one member, shown by name; their votes can carry a note.
alter table pv_maps    add column if not exists leader text check (length(leader) <= 60);
alter table pv_maps    add column if not exists leader_member int;
alter table pv_votes   add column if not exists note text check (length(note) <= 80);
-- Sharing, closing, deleting (Oct 16, 2026). A closed map takes no more votes; everything on it stays public.
alter table pv_maps    add column if not exists closed_at timestamptz;

-- Each time a leader sent the map to decision-makers. Written only by pv_share (leader code), never changed or removed.
-- recipients: [{"office": "Ward 7", "name": "Austin N. Davis"}, {"office": "Cleveland Land Bank"}, ...]
-- top_parcels_at_send: [{"parcel": "10131002", "choice": "open_space" or null, "votes": 6, "total": 7}, ...]
-- The foreign key has no cascade, so a map with entries can't be deleted.
create table if not exists pv_share_log (
  id                  bigint generated always as identity primary key,
  map_id              text not null references pv_maps(id),
  sent_at             timestamptz not null default now(),
  recipients          jsonb not null check (jsonb_typeof(recipients) = 'array'),
  voters_at_send      int not null,
  members_at_send     int not null,
  top_parcels_at_send jsonb not null default '[]'
);
create index if not exists pv_share_log_by_map on pv_share_log (map_id, sent_at);
create or replace function pv_share_log_frozen() returns trigger
language plpgsql set search_path = public as $$
begin raise exception 'pv_share_log is append-only'; end $$;
drop trigger if exists pv_share_log_frozen on pv_share_log;
create trigger pv_share_log_frozen before update or delete on pv_share_log for each row execute function pv_share_log_frozen();
drop trigger if exists pv_share_log_frozen_t on pv_share_log;
create trigger pv_share_log_frozen_t before truncate on pv_share_log for each statement execute function pv_share_log_frozen();

create table if not exists pv_attempts (
  ip   text not null,
  kind text not null,
  at   timestamptz not null default now()
);
create index if not exists pv_attempts_by_ip on pv_attempts (ip, kind, at);


-- ----------------------------------------------------------------- helpers

create or replace function pv_norm(p text) returns text
language sql immutable set search_path = public as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

create or replace function pv_norm_key(p text) returns text   -- "Coral-Rain  Jay." -> "coral rain jay"
language sql immutable set search_path = public as $$
  select trim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g'))
$$;

create or replace function pv_hash(p text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(coalesce(p, ''), 'sha256'), 'hex')
$$;

create or replace function pv_rand(n int) returns text   -- unambiguous letters and digits
language plpgsql volatile set search_path = public, extensions as $$
declare a text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; b bytea := extensions.gen_random_bytes(n); r text := '';
begin
  for i in 0..n - 1 loop r := r || substr(a, 1 + get_byte(b, i) % 31, 1); end loop;
  return r;
end $$;

create or replace function pv_words() returns text   -- a three-word steward key
language plpgsql volatile set search_path = public, extensions as $$
declare
  w text[] := string_to_array('acorn alder amber anchor apple arbor ash aspen aster autumn badger barley basil bay beach beacon bear beaver beech bell bench berry birch bison bloom bluff boat bramble branch breeze brick bridge brook bud burrow cabin canal canopy cardinal cedar chalk cherry chestnut chimney cider clay cloud clover coast cobalt comet copper coral corn cove coyote crane creek cricket crow cypress daisy dawn deer delta dew dove dune dusk eagle earth elm ember falcon fennel fern field finch fir firefly flint fog forest fox frog frost garden gate ginger glade glen goose granite grape grass grove gull harbor hare harvest hawk hazel heath hedge heron hickory hill hollow honey ibis iris ivy jade jay juniper kale kestrel lake lamp lane lantern larch lark laurel leaf lemon lilac lily lime linden lynx maple marsh meadow melon mill mink mint mist moon moss moth nest newt nutmeg oak oat ocean olive orchard oriole osprey otter owl pansy park path peach pear pebble pepper pier pine plaza plum pond poplar poppy porch prairie quail quarry rabbit rain raven reed ridge river robin rock rose rowan rye sage salt sand sapling sedge seed shore sky slate snow sorrel sparrow spring spruce square squirrel stone stork storm stream summer sun swallow swan sycamore teal tern thistle thyme tide timber toad tower trail trout tulip turtle valley violet walnut warbler wave whale wheat willow wind winter wolf wren yarrow', ' ');
  out text[] := '{}'; pick text; b bytea;
begin
  while coalesce(array_length(out, 1), 0) < 3 loop
    b := extensions.gen_random_bytes(2);
    pick := w[1 + (get_byte(b, 0) * 256 + get_byte(b, 1)) % array_length(w, 1)];
    if not pick = any(out) then out := out || pick; end if;
  end loop;
  return array_to_string(out, ' ');
end $$;

create or replace function pv_client_ip() returns text
language sql stable set search_path = public as $$
  select coalesce(nullif(trim(split_part(coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1)), ''), 'unknown')
$$;

create or replace function pv_over(p_kind text, p_max int, p_window interval) returns boolean
language sql stable set search_path = public as $$
  select count(*) >= p_max from pv_attempts where ip = pv_client_ip() and kind = p_kind and at > now() - p_window
$$;

create or replace function pv_note(p_kind text) returns void
language plpgsql set search_path = public as $$
begin
  insert into pv_attempts (ip, kind) values (pv_client_ip(), p_kind);
  if random() < 0.01 then delete from pv_attempts where at < now() - interval '1 day'; end if;
end $$;

create or replace function pv_err(p_code text) returns jsonb
language sql immutable set search_path = public as $$ select jsonb_build_object('error', p_code) $$;

-- The land bank's programs: the fixed answers on a land bank map, in the order the page shows them.
create or replace function pv_answers() returns text[]
language sql immutable set search_path = public as $$ select array['open_space', 'development', 'yard_expansion'] $$;

-- Votes per answer, as {"open_space": n, "development": n, "yard_expansion": n}.
create or replace function pv_by(o bigint, d bigint, y bigint) returns jsonb
language sql immutable set search_path = public as $$ select jsonb_build_object('open_space', o, 'development', d, 'yard_expansion', y) $$;

-- A map's public face: its terms and turnout (by code group too). Never the steward key or the codes.
create or replace function pv_map_info(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', m.id, 'kind', m.kind, 'question', m.question, 'steward', m.steward, 'budget', m.budget, 'budgets', m.budgets,
           'onsite', m.onsite, 'created_at', m.created_at, 'leader', m.leader, 'leader_member', m.leader_member,
           'closed_at', m.closed_at,
           'shared', (select count(*) from pv_share_log s where s.map_id = m.id),
           'last_shared', (select max(s.sent_at) from pv_share_log s where s.map_id = m.id),
           'issued', (select count(*) from pv_codes c where c.map_id = m.id),
           'used',   (select count(*) from pv_codes c where c.map_id = m.id and c.used_at is not null),
           'votes',  v.n, 'lots', v.lots,
           'by',     case when m.kind = 'land_bank' then pv_by(v.o, v.d, v.y) end,
           'groups', (select coalesce(jsonb_agg(jsonb_build_object('label', g.label, 'issued', g.issued, 'used', g.used) order by g.first_member), '[]')
                      from (select c.label, count(*) issued, count(c.used_at) used, min(c.member) as first_member from pv_codes c where c.map_id = m.id group by c.label) g))
  from pv_maps m,
       lateral (select count(*) n, count(distinct parcel_id) lots, count(*) filter (where choice = 'open_space') o,
                       count(*) filter (where choice = 'development') d, count(*) filter (where choice = 'yard_expansion') y
                from pv_votes x where x.map_id = m.id) v
  where m.id = p_id
$$;

drop function if exists pv_issue_codes(text, int);
create or replace function pv_issue_codes(p_map text, p_n int, p_label text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare first int; c text; out jsonb := '[]';
begin
  update pv_maps set members = members + p_n where id = p_map returning members - p_n into first;
  for i in 1..p_n loop
    loop c := pv_rand(8); exit when not exists (select 1 from pv_codes where code = c); end loop;
    insert into pv_codes (code, map_id, member, label) values (c, p_map, first + i, p_label);
    out := out || to_jsonb(c);
  end loop;
  return out;
end $$;

-- A code group's label: trimmed, blank means none. Null back if it's too long.
create or replace function pv_label(p text, out ok boolean, out label text)
language sql immutable set search_path = public as $$
  select length(trim(coalesce(p, ''))) <= 80, nullif(trim(coalesce(p, '')), '')
$$;


-- ------------------------------------------------------------------- maps

create or replace function pv_list_maps() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(pv_map_info(id) order by created_at desc), '[]') from pv_maps
$$;

create or replace function pv_get_map(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(pv_map_info(p_id), pv_err('map_not_found'))
$$;

-- Anyone can start a map. Returns the map, its steward key (shown once), and the invite codes.
-- Question map: p_budget votes per member. Land bank map: p_budgets, votes per member for each answer
-- (0 leaves that answer off the map). p_label names the first group of codes.
-- Postgres can't change a function's arguments in place, so the older versions are dropped first.
-- Every new map gets a leader code (member 1) as well: the leader votes with it like anyone else, and those votes
-- are shown as the map's recommendation under p_leader (the steward's name if blank).
drop function if exists pv_create_map(text, text, int, int, boolean);
drop function if exists pv_create_map(text, text, text, int, jsonb, int, boolean, text);
create or replace function pv_create_map(p_question text, p_steward text, p_kind text default 'question', p_budget int default null,
  p_budgets jsonb default null, p_members int default null, p_onsite boolean default false, p_label text default null, p_leader text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text; k text := pv_words(); codes jsonb; kind text := coalesce(nullif(p_kind, ''), 'question');
  q text := trim(coalesce(p_question, '')); s text := nullif(trim(coalesce(p_steward, '')), ''); lab record;
  b jsonb := '{}'; a text; n numeric; total int := 0; ld text := nullif(trim(coalesce(p_leader, '')), ''); lc jsonb;
begin
  if kind not in ('question', 'land_bank') then return pv_err('bad_kind'); end if;
  if kind = 'land_bank' and q = '' then q := 'What should each lot become?'; end if;
  if q = '' or length(q) > 200 then return pv_err('bad_question'); end if;
  if length(s) > 80 then return pv_err('bad_steward'); end if;
  if length(ld) > 60 then return pv_err('bad_leader'); end if;
  if kind = 'question' then
    if p_budget is null or p_budget < 1 or p_budget > 100 then return pv_err('bad_budget'); end if;
  else
    foreach a in array pv_answers() loop
      if jsonb_typeof(p_budgets -> a) is distinct from 'number' then return pv_err('bad_budget'); end if;
      n := (p_budgets ->> a)::numeric;
      if n <> trunc(n) or n < 0 or n > 100 then return pv_err('bad_budget'); end if;
      b := b || jsonb_build_object(a, n::int); total := total + n::int;
    end loop;
    if total = 0 then return pv_err('bad_budget'); end if;
  end if;
  if p_members is null or p_members < 1 or p_members > 2000 then return pv_err('bad_members'); end if;
  select * into lab from pv_label(p_label); if not lab.ok then return pv_err('bad_label'); end if;
  if pv_over('create', 20, interval '1 hour') then return pv_err('too_many_attempts'); end if;
  perform pv_note('create');
  loop v_id := lower(pv_rand(6)); exit when not exists (select 1 from pv_maps m where m.id = v_id); end loop;
  insert into pv_maps (id, kind, question, steward, budget, budgets, onsite, key_hash, leader)
    values (v_id, kind, q, s, case when kind = 'question' then p_budget end, case when kind = 'land_bank' then b end,
            coalesce(p_onsite, false), pv_hash(pv_norm_key(k)), coalesce(ld, left(s, 60)));
  lc := pv_issue_codes(v_id, 1, 'Leader');
  update pv_maps set leader_member = 1 where id = v_id;
  codes := pv_issue_codes(v_id, p_members, lab.label);
  return jsonb_build_object('map', pv_map_info(v_id), 'key', k, 'codes', codes, 'leader_code', lc -> 0);
end $$;

create or replace function pv_steward_ok(p_map text, p_key text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if pv_over('miss', 30, interval '10 minutes') then raise exception 'too_many_attempts'; end if;
  if exists (select 1 from pv_maps where id = p_map and key_hash = pv_hash(pv_norm_key(p_key))) then return true; end if;
  perform pv_note('miss'); return false;
end $$;

-- The steward's view: every code with its member number and first use.
create or replace function pv_codes(p_map text, p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from pv_maps where id = p_map) then return pv_err('map_not_found'); end if;
  if not pv_steward_ok(p_map, p_key) then return pv_err('bad_key'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'member', c.member, 'label', c.label, 'used_at', c.used_at,
                                     'leader', c.member is not distinct from m.leader_member) order by c.member)
                   from pv_codes c join pv_maps m on m.id = c.map_id where c.map_id = p_map), '[]');
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

drop function if exists pv_add_codes(text, text, int);
create or replace function pv_add_codes(p_map text, p_key text, p_n int, p_label text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lab record;
begin
  select * into lab from pv_label(p_label);
  if p_n is null or p_n < 1 or p_n > 1000 then return pv_err('bad_members'); end if;
  if not lab.ok then return pv_err('bad_label'); end if;
  if not pv_steward_ok(p_map, p_key) then return pv_err('bad_key'); end if;
  if (select members from pv_maps where id = p_map) + p_n > 5000 then return pv_err('bad_members'); end if;
  return pv_issue_codes(p_map, p_n, lab.label);
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

-- The steward names the leader, and makes the leader code if the map doesn't have one (maps made before Oct 15).
-- Returns {"leader": name, "code": the leader code}.
create or replace function pv_set_leader(p_map text, p_key text, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare nm text := nullif(trim(coalesce(p_name, '')), ''); m pv_maps; lc text;
begin
  if not exists (select 1 from pv_maps where id = p_map) then return pv_err('map_not_found'); end if;
  if nm is null or length(nm) > 60 then return pv_err('bad_leader'); end if;
  if not pv_steward_ok(p_map, p_key) then return pv_err('bad_key'); end if;
  perform pg_advisory_xact_lock(hashtext('pv-leader:' || p_map));
  select * into m from pv_maps where id = p_map;
  if m.leader_member is null then
    lc := pv_issue_codes(p_map, 1, 'Leader') ->> 0;
    update pv_maps set leader = nm, leader_member = (select member from pv_codes where code = lc) where id = p_map;
  else
    update pv_maps set leader = nm where id = p_map;
    select code into lc from pv_codes where map_id = p_map and member = m.leader_member;
  end if;
  return jsonb_build_object('leader', nm, 'code', lc);
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

-- A steward key typed on the home page: which maps it opens.
create or replace function pv_find_by_key(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ids jsonb;
begin
  if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
  select coalesce(jsonb_agg(id), '[]') into ids from pv_maps where key_hash = pv_hash(pv_norm_key(p_key));
  if ids = '[]' then perform pv_note('miss'); end if;
  return ids;
end $$;


-- ------------------------------------------------------------------ voting

create or replace function pv_join(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c pv_codes;
begin
  if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
  select * into c from pv_codes where code = pv_norm(p_code);
  if not found then perform pv_note('miss'); return pv_err('code_not_found'); end if;
  return jsonb_build_object('map', c.map_id, 'member', c.member, 'label', c.label);
end $$;

-- Cast or change this member's vote on a lot. Question maps: p_choice is ignored and a vote means yes.
-- Land bank maps: p_choice is one of pv_answers(); a different answer changes the vote, the same one changes
-- nothing. Each answer has its own number of votes per member (budget_used), and 0 leaves it off (choice_off).
drop function if exists pv_vote(text, text, boolean);
create or replace function pv_vote(p_code text, p_parcel text, p_choice text default null, p_onsite boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c pv_codes; m pv_maps; cur pv_votes; had boolean; pid text := pv_norm(p_parcel); ch text := nullif(trim(coalesce(p_choice, '')), ''); lim int; used int;
begin
  select * into c from pv_codes where code = pv_norm(p_code);
  if not found then
    if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('miss'); return pv_err('not_member');
  end if;
  perform pg_advisory_xact_lock(hashtext('pv-member:' || c.map_id || ':' || c.member));
  select * into m from pv_maps where id = c.map_id;
  if not exists (select 1 from pv_parcels where id = pid and status = 'public') then return pv_err('parcel_not_found'); end if;
  if m.kind = 'land_bank' then
    if ch is null or not ch = any(pv_answers()) then return pv_err('bad_choice'); end if;
  else ch := null; end if;
  select * into cur from pv_votes where map_id = m.id and parcel_id = pid and member = c.member;
  had := found;
  if m.closed_at is not null then return pv_err('closed'); end if;
  if had and (m.kind = 'question' or cur.choice = ch) then return jsonb_build_object('ok', true); end if;
  if m.kind = 'land_bank' then
    lim := coalesce((m.budgets ->> ch)::int, 0);
    if lim <= 0 then return pv_err('choice_off'); end if;
    select count(*) into used from pv_votes where map_id = m.id and member = c.member and choice = ch;
  else
    lim := m.budget;
    select count(*) into used from pv_votes where map_id = m.id and member = c.member;
  end if;
  if used >= lim then return pv_err('budget_used'); end if;
  if m.onsite and not coalesce(p_onsite, false) then return pv_err('off_site'); end if;
  if had then
    update pv_votes set choice = ch, at = now(), onsite = case when m.onsite then true end
      where map_id = m.id and parcel_id = pid and member = c.member;
  else
    insert into pv_votes (map_id, parcel_id, member, choice, onsite) values (m.id, pid, c.member, ch, case when m.onsite then true end);
  end if;
  insert into pv_history (map_id, parcel_id, member, action, choice, onsite)
    values (m.id, pid, c.member, case when had then 'change' else 'vote' end, ch, case when m.onsite then true end);
  update pv_codes set used_at = coalesce(used_at, now()) where code = c.code;
  return jsonb_build_object('ok', true, 'left', lim - used - 1);
end $$;

-- The leader's one-line note on a lot they've voted on (blank clears it). Only the leader's code can write one.
create or replace function pv_set_note(p_code text, p_parcel text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c pv_codes; nt text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into c from pv_codes where code = pv_norm(p_code);
  if not found then
    if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('miss'); return pv_err('not_member');
  end if;
  if not exists (select 1 from pv_maps where id = c.map_id and leader_member = c.member) then return pv_err('not_leader'); end if;
  if exists (select 1 from pv_maps where id = c.map_id and closed_at is not null) then return pv_err('closed'); end if;
  if length(nt) > 80 then return pv_err('bad_note'); end if;
  update pv_votes set note = nt where map_id = c.map_id and parcel_id = pv_norm(p_parcel) and member = c.member;
  if not found then return pv_err('no_vote'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function pv_unvote(p_code text, p_parcel text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c pv_codes; pid text := pv_norm(p_parcel); ch text;
begin
  select * into c from pv_codes where code = pv_norm(p_code);
  if not found then
    if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('miss'); return pv_err('not_member');
  end if;
  perform pg_advisory_xact_lock(hashtext('pv-member:' || c.map_id || ':' || c.member));
  if exists (select 1 from pv_maps where id = c.map_id and closed_at is not null) then return pv_err('closed'); end if;
  delete from pv_votes where map_id = c.map_id and parcel_id = pid and member = c.member returning choice into ch;
  if found then insert into pv_history (map_id, parcel_id, member, action, choice) values (c.map_id, pid, c.member, 'take back', ch); end if;
  return jsonb_build_object('ok', true);
end $$;


-- ------------------------------------------------------------- reading

-- Question maps: [[parcel, votes], ...]. Land bank maps: [[parcel, open space, development, yard expansion], ...].
create or replace function pv_tally(p_map text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(case when m.kind = 'land_bank' then jsonb_build_array(t.parcel_id, t.o, t.d, t.y) else jsonb_build_array(t.parcel_id, t.n) end), '[]')
  from pv_maps m,
       lateral (select parcel_id, count(*) n, count(*) filter (where choice = 'open_space') o, count(*) filter (where choice = 'development') d,
                       count(*) filter (where choice = 'yard_expansion') y
                from pv_votes where map_id = m.id group by parcel_id) t
  where m.id = p_map
$$;

create or replace function pv_mine(p_code text) returns jsonb   -- this code's votes: [[parcel, answer or null], ...]
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(v.parcel_id, v.choice)), '[]')
  from pv_codes c join pv_votes v on v.map_id = c.map_id and v.member = c.member
  where c.code = pv_norm(p_code)
$$;

create or replace function pv_lot_maps(p_parcel text) returns jsonb   -- every map with votes on this lot, with votes per answer on land bank maps
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'question', m.question, 'steward', m.steward, 'votes', t.n,
           'by', case when m.kind = 'land_bank' then pv_by(t.o, t.d, t.y) end, 'leader', m.leader, 'closed_at', m.closed_at,
           'shared', exists (select 1 from pv_share_log s where s.map_id = m.id)) order by t.n desc, m.created_at), '[]')
  from (select map_id, count(*) n, count(*) filter (where choice = 'open_space') o, count(*) filter (where choice = 'development') d,
               count(*) filter (where choice = 'yard_expansion') y
        from pv_votes where parcel_id = pv_norm(p_parcel) group by map_id) t join pv_maps m on m.id = t.map_id
$$;

-- The leader's votes on a map: [[parcel, answer or null, note], ...].
create or replace function pv_leader(p_map text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(v.parcel_id, v.choice, v.note)), '[]')
  from pv_maps m join pv_votes v on v.map_id = m.id and v.member = m.leader_member
  where m.id = p_map
$$;

create or replace function pv_record(p_map text default null) returns jsonb   -- every current vote, for download
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('map', v.map_id, 'kind', m.kind, 'question', m.question, 'parcel', v.parcel_id, 'member', v.member,
           'choice', v.choice, 'label', c.label, 'at', v.at, 'onsite', v.onsite,
           'leader', v.member is not distinct from m.leader_member, 'note', v.note) order by v.map_id, v.at), '[]')
  from pv_votes v join pv_maps m on m.id = v.map_id left join pv_codes c on c.map_id = v.map_id and c.member = v.member
  where p_map is null or v.map_id = p_map
$$;

-- Every lot with a vote on any map: [[parcel, maps with votes on it, open space, development, yard expansion], ...].
-- The three answers are summed over land bank maps only (their answers are fixed, so they add up); question maps
-- count toward the number of maps but not toward the answers. The home page's map of the whole record.
create or replace function pv_all_lots() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(t.parcel_id, t.maps, t.o, t.d, t.y)), '[]')
  from (select v.parcel_id, count(distinct v.map_id) maps,
               count(*) filter (where m.kind = 'land_bank' and v.choice = 'open_space') o,
               count(*) filter (where m.kind = 'land_bank' and v.choice = 'development') d,
               count(*) filter (where m.kind = 'land_bank' and v.choice = 'yard_expansion') y
        from pv_votes v join pv_maps m on m.id = v.map_id group by v.parcel_id) t
$$;

-- How many maps sent to decision-makers include this lot: it was among the top lots when one was sent, or it has
-- votes on a map that has been sent.
create or replace function pv_lot_shared(p_parcel text) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct s.map_id)::int from pv_share_log s
  where s.top_parcels_at_send @> jsonb_build_array(jsonb_build_object('parcel', pv_norm(p_parcel)))
     or exists (select 1 from pv_votes v where v.map_id = s.map_id and v.parcel_id = pv_norm(p_parcel))
$$;

-- The lots where a map's members agree most, best first: [{"parcel", "choice", "votes", "total"}, ...].
-- Agreement is the leading answer's votes (question maps: the votes); more votes in all breaks a tie, then the
-- parcel number. Lots where two answers tie for the lead are left out: they have no one answer to report.
create or replace function pv_top_lots(p_map text, p_n int default 3) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('parcel', x.parcel_id, 'choice', x.choice, 'votes', x.lead, 'total', x.n)
                            order by x.lead desc, x.n desc, x.parcel_id), '[]')
  from (select * from (
          select t.parcel_id, t.n,
                 case when m.kind = 'land_bank' then greatest(t.o, t.d, t.y) else t.n end lead,
                 case when m.kind = 'land_bank' then
                   case greatest(t.o, t.d, t.y) when t.o then 'open_space' when t.d then 'development' else 'yard_expansion' end end choice,
                 m.kind = 'land_bank' and ((t.o = greatest(t.o, t.d, t.y))::int + (t.d = greatest(t.o, t.d, t.y))::int + (t.y = greatest(t.o, t.d, t.y))::int) > 1 tie
          from pv_maps m,
               lateral (select parcel_id, count(*) n, count(*) filter (where choice = 'open_space') o,
                               count(*) filter (where choice = 'development') d, count(*) filter (where choice = 'yard_expansion') y
                        from pv_votes where map_id = m.id group by parcel_id) t
          where m.id = p_map) z
        where not z.tie
        order by z.lead desc, z.n desc, z.parcel_id
        limit greatest(0, least(coalesce(p_n, 3), 20))) x
$$;


-- ------------------------------------------- sharing, closing, deleting
-- All three take the map's leader code, checked here, never only in the page.

-- The record of a map being sent to decision-makers, newest first.
create or replace function pv_shares(p_map text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sent_at', s.sent_at, 'recipients', s.recipients, 'voters', s.voters_at_send,
           'members', s.members_at_send, 'top', s.top_parcels_at_send) order by s.sent_at desc, s.id desc), '[]')
  from pv_share_log s where s.map_id = p_map
$$;

-- A leader code's map, or null (wrong codes count toward the rate limit).
create or replace function pv_leader_map(p_code text) returns pv_maps
language plpgsql security definer set search_path = public as $$
declare c pv_codes; m pv_maps;
begin
  if pv_over('miss', 30, interval '10 minutes') then raise exception 'too_many_attempts'; end if;
  select * into c from pv_codes where code = pv_norm(p_code);
  if found then select * into m from pv_maps where id = c.map_id and leader_member = c.member; end if;
  if m.id is null then perform pv_note('miss'); end if;
  return m;
end $$;

-- The leader confirms they sent the map. p_recipients: [{"office": "...", "name": "..."}], public officials only.
-- Only the office and name are kept (anything else, an email included, is dropped). Turnout and the top lots are
-- read here, at the moment of the entry, not taken from the page.
create or replace function pv_share(p_code text, p_recipients jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m pv_maps; r jsonb; rs jsonb := '[]'; o text; nm text; e pv_share_log;
begin
  m := pv_leader_map(p_code);
  if m.id is null then return pv_err('not_leader'); end if;
  if jsonb_typeof(p_recipients) is distinct from 'array' or jsonb_array_length(p_recipients) not between 1 and 20 then return pv_err('bad_recipients'); end if;
  for r in select * from jsonb_array_elements(p_recipients) loop
    if jsonb_typeof(r) <> 'object' then return pv_err('bad_recipients'); end if;
    o := nullif(trim(coalesce(r ->> 'office', '')), ''); nm := nullif(trim(coalesce(r ->> 'name', '')), '');
    if o is null or length(o) > 120 or length(nm) > 100 or o ~ '@' or nm ~ '@' then return pv_err('bad_recipients'); end if;
    rs := rs || jsonb_build_array(case when nm is null then jsonb_build_object('office', o) else jsonb_build_object('office', o, 'name', nm) end);
  end loop;
  perform pg_advisory_xact_lock(hashtext('pv-share:' || m.id));
  if (select count(*) from pv_share_log where map_id = m.id and sent_at > now() - interval '1 day') >= 10 then return pv_err('too_many_shares'); end if;
  insert into pv_share_log (map_id, recipients, voters_at_send, members_at_send, top_parcels_at_send)
    values (m.id, rs, (select count(*) from pv_codes where map_id = m.id and used_at is not null),
            (select count(*) from pv_codes where map_id = m.id), pv_top_lots(m.id, 3))
    returning * into e;
  return jsonb_build_object('id', e.id, 'sent_at', e.sent_at, 'recipients', e.recipients, 'voters', e.voters_at_send,
                            'members', e.members_at_send, 'top', e.top_parcels_at_send);
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

-- The leader closes voting for good. Votes, the map, and its share log stay public.
create or replace function pv_close_map(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m pv_maps; t timestamptz;
begin
  m := pv_leader_map(p_code);
  if m.id is null then return pv_err('not_leader'); end if;
  update pv_maps set closed_at = coalesce(closed_at, now()) where id = m.id returning closed_at into t;
  return jsonb_build_object('ok', true, 'closed_at', t);
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

-- The leader deletes a map that was never sent to decision-makers (tests, demos): the map, its codes, its votes,
-- and their history. p_confirm must be the map's question, as a check that it's the right map.
create or replace function pv_delete_map(p_code text, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m pv_maps;
begin
  m := pv_leader_map(p_code);
  if m.id is null then return pv_err('not_leader'); end if;
  perform pg_advisory_xact_lock(hashtext('pv-share:' || m.id));
  if exists (select 1 from pv_share_log where map_id = m.id) then return pv_err('shared'); end if;
  if pv_norm_key(p_confirm) is distinct from pv_norm_key(m.question) then return pv_err('bad_confirm'); end if;
  delete from pv_history where map_id = m.id;
  delete from pv_maps where id = m.id;   -- codes go with it, and votes with the codes
  return jsonb_build_object('ok', true);
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;


-- ------------------------------------------------------ syncing with the city

create or replace function pv_city_get(p_url text) returns jsonb
language plpgsql set search_path = public, extensions as $$
declare st int; body text; j jsonb;
begin
  -- The http extension gives up connecting after 1 second by default; the city's service can take longer.
  begin
    execute $q$select extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '20')$q$;
    execute $q$select extensions.http_set_curlopt('CURLOPT_TIMEOUT', '60')$q$;
  exception when others then null; end;
  execute 'select status, content from extensions.http_get($1)' into st, body using p_url;
  if st is distinct from 200 then raise exception 'The city service answered % for %', st, p_url; end if;
  j := body::jsonb;
  if j ? 'error' then raise exception 'The city service returned an error: %', j -> 'error'; end if;
  return j;
end $$;

-- Brings pv_parcels in line with the city's published inventory. Checks the layer's last-edit date first
-- and stops there if nothing changed. Lots the city no longer publishes are archived with their votes.
-- Refuses (and changes nothing) if the city returns far fewer lots than expected; pv_sync_city(true) overrides.
create or replace function pv_sync_city(p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s pv_sync; meta jsonb; edit bigint; cnt int; size int; off int := 0; q text;
  got int; cur int; added int; relisted int; archived int; res jsonb;
begin
  select * into s from pv_sync;
  update pv_sync set last_run = now();
  begin
    meta := pv_city_get(s.layer_url || '?f=json');
    edit := coalesce(meta #>> '{editingInfo,dataLastEditDate}', meta #>> '{editingInfo,lastEditDate}')::bigint;
    if not p_force and edit is not null and edit = s.last_edit and s.last_ok is not null then
      res := jsonb_build_object('status', 'unchanged', 'edited', edit);
      update pv_sync set last_result = res;
      return res;
    end if;

    cnt  := (pv_city_get(s.layer_url || '/query?where=1%3D1&returnCountOnly=true&f=json') ->> 'count')::int;
    size := least(coalesce((meta ->> 'maxRecordCount')::int, 1000), 2000);
    q    := s.layer_url || '/query?where=1%3D1&returnGeometry=false&f=json'
         || '&outFields=' || concat_ws(',', s.id_field, s.address_field, s.category_field)
         || '&orderByFields=' || coalesce(meta ->> 'objectIdField', 'OBJECTID')
         || '&resultRecordCount=' || size || '&resultOffset=';

    drop table if exists _pv_seen;
    create temp table _pv_seen (id text primary key, pin text, address text, category text) on commit drop;
    while off < cnt loop
      insert into _pv_seen (id, pin, address, category)
        select pv_norm(a ->> s.id_field), trim(a ->> s.id_field),
               nullif(trim(a ->> s.address_field), ''), nullif(trim(a ->> s.category_field), '')
        from jsonb_array_elements(pv_city_get(q || off) -> 'features') f, lateral (select f -> 'attributes' as a) x
        where pv_norm(a ->> s.id_field) <> ''
        on conflict (id) do nothing;
      off := off + size;
    end loop;

    select count(*) into got from _pv_seen;
    select count(*) into cur from pv_parcels where status = 'public';
    if got = 0 or (not p_force and (got < cnt * 0.98 or got < cur / 2)) then
      res := jsonb_build_object('status', 'refused', 'edited', edit, 'reason',
        format('The city returned %s lots of %s expected, with %s on the list now. Nothing changed. Run pv_sync_city(true) to accept it anyway.', got, cnt, cur));
      update pv_sync set last_result = res;
      return res;
    end if;

    select count(*) filter (where p.id is null), count(*) filter (where p.status = 'archived')
      into added, relisted
      from _pv_seen x left join pv_parcels p on p.id = x.id;
    insert into pv_parcels (id, pin, address, category, status, last_seen, archived_at)
      select id, pin, address, category, 'public', now(), null from _pv_seen
    on conflict (id) do update
      set pin = excluded.pin, address = excluded.address, category = excluded.category,
          status = 'public', last_seen = now(), archived_at = null;
    update pv_parcels p set status = 'archived', archived_at = now()
      where p.status = 'public' and not exists (select 1 from _pv_seen x where x.id = p.id);
    get diagnostics archived = row_count;

    res := jsonb_build_object('status', 'synced', 'edited', edit, 'public', got, 'added', added,
                              'relisted', relisted, 'archived', archived);
    update pv_sync set last_edit = edit, last_ok = now(), last_result = res;
    return res;
  exception when others then
    res := jsonb_build_object('status', 'failed', 'error', sqlerrm);
    update pv_sync set last_result = res;
    return res;
  end;
end $$;


-- ------------------------------------------------------------------ access

alter table pv_parcels  enable row level security;
alter table pv_sync     enable row level security;
alter table pv_maps     enable row level security;
alter table pv_codes    enable row level security;
alter table pv_votes    enable row level security;
alter table pv_history  enable row level security;
alter table pv_attempts enable row level security;
alter table pv_share_log enable row level security;

-- The lots, the votes, their history, the share log, and the sync status are open to everyone. Maps are read through
-- pv_list_maps / pv_get_map (so the steward key's hash never leaves). Codes and attempts are private.
do $$
declare t text;
begin
  foreach t in array array['pv_parcels', 'pv_sync', 'pv_votes', 'pv_history', 'pv_share_log'] loop
    execute format('drop policy if exists "Anyone can read" on %I', t);
    execute format('create policy "Anyone can read" on %I for select using (true)', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to anon, authenticated', t);
  end loop;
end $$;
revoke all on pv_maps, pv_codes, pv_attempts from anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pv\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function pv_list_maps()                                  to anon, authenticated;
grant execute on function pv_get_map(text)                                to anon, authenticated;
grant execute on function pv_create_map(text, text, text, int, jsonb, int, boolean, text, text) to anon, authenticated;
grant execute on function pv_set_leader(text, text, text)                 to anon, authenticated;
grant execute on function pv_set_note(text, text, text)                   to anon, authenticated;
grant execute on function pv_leader(text)                                 to anon, authenticated;
grant execute on function pv_codes(text, text)                            to anon, authenticated;
grant execute on function pv_add_codes(text, text, int, text)             to anon, authenticated;
grant execute on function pv_find_by_key(text)                            to anon, authenticated;
grant execute on function pv_join(text)                                   to anon, authenticated;
grant execute on function pv_vote(text, text, text, boolean)              to anon, authenticated;
grant execute on function pv_unvote(text, text)                           to anon, authenticated;
grant execute on function pv_tally(text)                                  to anon, authenticated;
grant execute on function pv_mine(text)                                   to anon, authenticated;
grant execute on function pv_lot_maps(text)                               to anon, authenticated;
grant execute on function pv_record(text)                                 to anon, authenticated;
grant execute on function pv_all_lots()                                   to anon, authenticated;
grant execute on function pv_lot_shared(text)                             to anon, authenticated;
grant execute on function pv_top_lots(text, int)                          to anon, authenticated;
grant execute on function pv_shares(text)                                 to anon, authenticated;
grant execute on function pv_share(text, jsonb)                           to anon, authenticated;
grant execute on function pv_close_map(text)                              to anon, authenticated;
grant execute on function pv_delete_map(text, text)                       to anon, authenticated;


-- ------------------------------------- retiring the Land Bank Program Vote
-- Its single map is now a land bank map in this tool. Its lp_* tables and functions (programs/schema.sql)
-- are removed if they hold no votes. If they do, nothing is touched: download them first
-- (select lp_record();), then run   drop table lp_votes, lp_history, lp_keys, lp_batches, lp_settings cascade;
do $$
declare f regprocedure; n bigint := 0;
begin
  if to_regclass('public.lp_votes') is not null then execute 'select count(*) from lp_votes' into n; end if;
  if n > 0 then
    raise notice 'Left the Land Bank Program Vote tables in place: lp_votes has % votes. Export them, then drop them by hand.', n;
    return;
  end if;
  drop table if exists lp_votes, lp_history, lp_keys, lp_batches, lp_settings cascade;
  drop sequence if exists lp_voter_seq;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'lp\_%' loop
    execute format('drop function %s', f);
  end loop;
end $$;


-- ----------------------------------------- schedule the sync, run it once

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('pv-city-sync', '17 * * * *', 'select public.pv_sync_city()');
  end if;
end $$;

do $$
declare r jsonb;
begin
  if exists (select 1 from pg_extension where extname = 'http') then
    r := pv_sync_city();
    raise notice 'City sync: %', r;
  end if;
end $$;

-- How the last sync went:  select last_run, last_result from pv_sync;
-- Every map, with turnout:  select pv_list_maps();
