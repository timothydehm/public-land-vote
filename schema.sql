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
--   pv_maps      a coalition's map: question, steward, votes per member,
--                on-site rule, and the hash of the steward key.
--   pv_codes     invite codes. One per member; readable only through the
--                steward key.
--   pv_votes     current votes: map, parcel, member number, time, and the
--                on-site yes/no on on-site maps. Public.
--   pv_history   every vote and take-back, append-only. Public.
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
  budget     int not null check (budget between 1 and 100),
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
  unique (map_id, member)
);

create table if not exists pv_votes (
  map_id    text not null,
  parcel_id text not null references pv_parcels(id),
  member    int not null,
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
  action    text not null check (action in ('vote', 'take back')),
  onsite    boolean,
  at        timestamptz not null default now()
);
create index if not exists pv_history_by_map on pv_history (map_id, at);

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

-- A map's public face: its terms and turnout. Never the steward key or the codes.
create or replace function pv_map_info(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', m.id, 'question', m.question, 'steward', m.steward, 'budget', m.budget, 'onsite', m.onsite,
           'created_at', m.created_at,
           'issued', (select count(*) from pv_codes c where c.map_id = m.id),
           'used',   (select count(*) from pv_codes c where c.map_id = m.id and c.used_at is not null),
           'votes',  (select count(*) from pv_votes v where v.map_id = m.id),
           'lots',   (select count(distinct v.parcel_id) from pv_votes v where v.map_id = m.id))
  from pv_maps m where m.id = p_id
$$;

create or replace function pv_issue_codes(p_map text, p_n int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare first int; c text; out jsonb := '[]';
begin
  update pv_maps set members = members + p_n where id = p_map returning members - p_n into first;
  for i in 1..p_n loop
    loop c := pv_rand(8); exit when not exists (select 1 from pv_codes where code = c); end loop;
    insert into pv_codes (code, map_id, member) values (c, p_map, first + i);
    out := out || to_jsonb(c);
  end loop;
  return out;
end $$;


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
create or replace function pv_create_map(p_question text, p_steward text, p_budget int, p_members int, p_onsite boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id text; k text := pv_words(); codes jsonb; q text := trim(coalesce(p_question, '')); s text := nullif(trim(coalesce(p_steward, '')), '');
begin
  if q = '' or length(q) > 200 then return pv_err('bad_question'); end if;
  if length(s) > 80 then return pv_err('bad_steward'); end if;
  if p_budget is null or p_budget < 1 or p_budget > 100 then return pv_err('bad_budget'); end if;
  if p_members is null or p_members < 1 or p_members > 2000 then return pv_err('bad_members'); end if;
  if pv_over('create', 20, interval '1 hour') then return pv_err('too_many_attempts'); end if;
  perform pv_note('create');
  loop v_id := lower(pv_rand(6)); exit when not exists (select 1 from pv_maps m where m.id = v_id); end loop;
  insert into pv_maps (id, question, steward, budget, onsite, key_hash) values (v_id, q, s, p_budget, coalesce(p_onsite, false), pv_hash(pv_norm_key(k)));
  codes := pv_issue_codes(v_id, p_members);
  return jsonb_build_object('map', pv_map_info(v_id), 'key', k, 'codes', codes);
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
  return coalesce((select jsonb_agg(jsonb_build_object('code', code, 'member', member, 'used_at', used_at) order by member)
                   from pv_codes where map_id = p_map), '[]');
exception when others then if sqlerrm = 'too_many_attempts' then return pv_err('too_many_attempts'); end if; raise;
end $$;

create or replace function pv_add_codes(p_map text, p_key text, p_n int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_n is null or p_n < 1 or p_n > 1000 then return pv_err('bad_members'); end if;
  if not pv_steward_ok(p_map, p_key) then return pv_err('bad_key'); end if;
  if (select members from pv_maps where id = p_map) + p_n > 5000 then return pv_err('bad_members'); end if;
  return pv_issue_codes(p_map, p_n);
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
  return jsonb_build_object('map', c.map_id, 'member', c.member);
end $$;

create or replace function pv_vote(p_code text, p_parcel text, p_onsite boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c pv_codes; m pv_maps; pid text := pv_norm(p_parcel); used int;
begin
  select * into c from pv_codes where code = pv_norm(p_code);
  if not found then
    if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('miss'); return pv_err('not_member');
  end if;
  perform pg_advisory_xact_lock(hashtext('pv-member:' || c.map_id || ':' || c.member));
  select * into m from pv_maps where id = c.map_id;
  if not exists (select 1 from pv_parcels where id = pid and status = 'public') then return pv_err('parcel_not_found'); end if;
  if exists (select 1 from pv_votes where map_id = m.id and parcel_id = pid and member = c.member) then
    return jsonb_build_object('ok', true);
  end if;
  select count(*) into used from pv_votes where map_id = m.id and member = c.member;
  if used >= m.budget then return pv_err('budget_used'); end if;
  if m.onsite and not coalesce(p_onsite, false) then return pv_err('off_site'); end if;
  insert into pv_votes (map_id, parcel_id, member, onsite) values (m.id, pid, c.member, case when m.onsite then true end);
  insert into pv_history (map_id, parcel_id, member, action, onsite) values (m.id, pid, c.member, 'vote', case when m.onsite then true end);
  update pv_codes set used_at = coalesce(used_at, now()) where code = c.code;
  return jsonb_build_object('ok', true, 'left', m.budget - used - 1);
end $$;

create or replace function pv_unvote(p_code text, p_parcel text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c pv_codes; pid text := pv_norm(p_parcel);
begin
  select * into c from pv_codes where code = pv_norm(p_code);
  if not found then
    if pv_over('miss', 30, interval '10 minutes') then return pv_err('too_many_attempts'); end if;
    perform pv_note('miss'); return pv_err('not_member');
  end if;
  perform pg_advisory_xact_lock(hashtext('pv-member:' || c.map_id || ':' || c.member));
  delete from pv_votes where map_id = c.map_id and parcel_id = pid and member = c.member;
  if found then insert into pv_history (map_id, parcel_id, member, action) values (c.map_id, pid, c.member, 'take back'); end if;
  return jsonb_build_object('ok', true);
end $$;


-- ------------------------------------------------------------- reading

create or replace function pv_tally(p_map text) returns jsonb   -- [[parcel, votes], ...]
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(parcel_id, n)), '[]')
  from (select parcel_id, count(*) n from pv_votes where map_id = p_map group by parcel_id) t
$$;

create or replace function pv_mine(p_code text) returns jsonb   -- the lots this code has voted for
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(v.parcel_id), '[]')
  from pv_codes c join pv_votes v on v.map_id = c.map_id and v.member = c.member
  where c.code = pv_norm(p_code)
$$;

create or replace function pv_lot_maps(p_parcel text) returns jsonb   -- every map with votes on this lot
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'question', m.question, 'steward', m.steward, 'votes', t.n) order by t.n desc), '[]')
  from (select map_id, count(*) n from pv_votes where parcel_id = pv_norm(p_parcel) group by map_id) t join pv_maps m on m.id = t.map_id
$$;

create or replace function pv_record(p_map text default null) returns jsonb   -- every current vote, for download
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('map', v.map_id, 'question', m.question, 'parcel', v.parcel_id, 'member', v.member,
           'at', v.at, 'onsite', v.onsite) order by v.map_id, v.at), '[]')
  from pv_votes v join pv_maps m on m.id = v.map_id
  where p_map is null or v.map_id = p_map
$$;


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

-- The lots, the votes, their history, and the sync status are open to everyone. Maps are read through
-- pv_list_maps / pv_get_map (so the steward key's hash never leaves). Codes and attempts are private.
do $$
declare t text;
begin
  foreach t in array array['pv_parcels', 'pv_sync', 'pv_votes', 'pv_history'] loop
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
grant execute on function pv_create_map(text, text, int, int, boolean)    to anon, authenticated;
grant execute on function pv_codes(text, text)                            to anon, authenticated;
grant execute on function pv_add_codes(text, text, int)                   to anon, authenticated;
grant execute on function pv_find_by_key(text)                            to anon, authenticated;
grant execute on function pv_join(text)                                   to anon, authenticated;
grant execute on function pv_vote(text, text, boolean)                    to anon, authenticated;
grant execute on function pv_unvote(text, text)                           to anon, authenticated;
grant execute on function pv_tally(text)                                  to anon, authenticated;
grant execute on function pv_mine(text)                                   to anon, authenticated;
grant execute on function pv_lot_maps(text)                               to anon, authenticated;
grant execute on function pv_record(text)                                 to anon, authenticated;


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
