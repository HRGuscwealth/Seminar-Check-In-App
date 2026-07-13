-- ===========================================================================
-- RSVP -> Check-In consolidation
-- ===========================================================================
-- Runs in the CHECK-IN Supabase project (ref yoegkistqqloqhjsruer).
--
-- Brings the RSVP page's two tables (seminars, rsvps) into this project so the
-- two apps share one database, and adds a trigger that turns every RSVP into
-- attendee rows automatically (one primary + one row per named guest, linked
-- into a "party" exactly the way the Check-In app's own CSV import does).
--
-- Safe to run more than once: everything is create-if-not-exists / or-replace,
-- and the attendee upsert is keyed on a deterministic id so re-runs and
-- back-fills never create duplicates.
--
-- Apply in the Check-In project's SQL editor. Then migrate existing rows and
-- re-point the RSVP page — see supabase/RSVP_INTEGRATION.md.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Tables (mirror the RSVP page's schema; text ids accept whatever the live
--    RSVP project currently uses, uuid or otherwise, so migrated rows copy in
--    verbatim and the RSVP app's insert-without-id keeps working).
-- ---------------------------------------------------------------------------

create table if not exists public.seminars (
  "id"         text primary key default gen_random_uuid()::text,
  "name"       text,
  "event_date" date,
  "start_time" time,
  "venue"      text,
  "capacity"   integer,
  "is_active"  boolean default false,
  "created_at" timestamptz default now()
);

create table if not exists public.rsvps (
  "id"          text primary key default gen_random_uuid()::text,
  "seminar_id"  text references public.seminars ("id") on delete cascade,
  "first_name"  text,
  "last_name"   text,
  "email"       text,
  "phone"       text,
  "retire_year" text default '',
  "guests"      jsonb default '[]'::jsonb,
  "rsvp_date"   date default current_date,
  "created_at"  timestamptz default now(),
  -- one seat per email per seminar; surfaces to the RSVP page as error 23505
  unique ("seminar_id", "email")
);
create index if not exists rsvps_seminar_id_idx on public.rsvps ("seminar_id");

-- Tag every attendee with the seminar it belongs to, so the Check-In app can
-- show one seminar's roster at a time. Nullable: legacy/manually-added
-- attendees simply have no seminar until one is assigned.
alter table public.attendees add column if not exists "seminarId" text;
create index if not exists attendees_seminarid_idx on public.attendees ("seminarId");


-- ---------------------------------------------------------------------------
-- 2. Row-level security + grants
--    RSVP landing page (anon):  read seminars, insert an rsvp — but NEVER read
--                               rsvps back (guest privacy).
--    RSVP admin / Check-In app (authenticated): full access.
-- ---------------------------------------------------------------------------

alter table public.seminars enable row level security;
alter table public.rsvps    enable row level security;

drop policy if exists seminars_anon_read on public.seminars;
create policy seminars_anon_read on public.seminars
  for select to anon using (true);

drop policy if exists seminars_auth_all on public.seminars;
create policy seminars_auth_all on public.seminars
  for all to authenticated using (true) with check (true);

drop policy if exists rsvps_anon_insert on public.rsvps;
create policy rsvps_anon_insert on public.rsvps
  for insert to anon with check (true);

drop policy if exists rsvps_auth_all on public.rsvps;
create policy rsvps_auth_all on public.rsvps
  for all to authenticated using (true) with check (true);

-- Grants belt-and-suspenders with RLS. anon may insert rsvps but not select
-- them; both roles may read seminars.
grant select on public.seminars to anon, authenticated;
grant insert, update, delete on public.seminars to authenticated;

revoke all on public.rsvps from anon;
grant insert on public.rsvps to anon;
grant select, insert, update, delete on public.rsvps to authenticated;


-- ---------------------------------------------------------------------------
-- 3. RPC the RSVP admin page calls to switch the active seminar.
-- ---------------------------------------------------------------------------

create or replace function public.set_active_seminar(target text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.seminars set is_active = ("id" = target);
end;
$$;

grant execute on function public.set_active_seminar(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. The bridge: RSVP row -> attendee rows.
--    Fires on insert (new RSVP or back-fill) and on update (pre-event edits).
--    security definer so it can write attendees even when the caller is the
--    anon RSVP page.
--
--    Idempotency: attendee ids are derived from the rsvp id, so the SAME rsvp
--    always maps to the SAME attendee rows. On conflict we refresh only the
--    person's own details (name / contact / retirement) and deliberately leave
--    check-in fields (checkInStatus, assignedTeamMember, follow-ups, …) alone,
--    so an RSVP edit never clobbers what staff did on the day.
-- ---------------------------------------------------------------------------

create or replace function public.rsvp_to_attendees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  primary_id  text := 'rsvp_' || NEW."id"::text;
  fname       text := coalesce(NEW.first_name, '');
  lname       text := coalesce(NEW.last_name, '');
  now_iso     text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  g           jsonb;
  gname       text;
  gfirst      text;
  glast       text;
  gid         text;
  gspouse     boolean;
  sp          int;
begin
  -- Primary attendee (one per RSVP)
  insert into public.attendees
    ("id", "firstName", "lastName", "searchName", "phone", "email",
     "retirementDate", "checkInStatus", "source", "seminarId",
     "partyId", "primaryAttendeeId", "isAdditionalGuest", "relationship",
     "assignedTeamMember", "updatedAt")
  values
    (primary_id, fname, lname, lower(trim(fname || ' ' || lname)),
     NEW.phone, NEW.email, coalesce(NEW.retire_year, ''),
     'not_checked_in', 'rsvp', NEW.seminar_id,
     primary_id, null, false, '',
     '', now_iso)
  on conflict ("id") do update set
     "firstName"      = excluded."firstName",
     "lastName"       = excluded."lastName",
     "searchName"     = excluded."searchName",
     "phone"          = excluded."phone",
     "email"          = excluded."email",
     "retirementDate" = excluded."retirementDate",
     "seminarId"      = excluded."seminarId",
     "updatedAt"      = excluded."updatedAt";

  -- Named guests -> additional attendees in the same party
  for g in select * from jsonb_array_elements(coalesce(NEW.guests, '[]'::jsonb))
  loop
    gname := trim(coalesce(g->>'name', ''));
    continue when gname = '';

    gid     := primary_id || '_g_' || coalesce(nullif(g->>'id', ''), md5(gname));
    gspouse := coalesce((g->>'spouse')::boolean, false);

    sp := position(' ' in gname);          -- split "First Last" on the first space
    if sp > 0 then
      gfirst := substring(gname from 1 for sp - 1);
      glast  := substring(gname from sp + 1);
    else
      gfirst := gname;
      glast  := '';
    end if;

    insert into public.attendees
      ("id", "firstName", "lastName", "searchName", "phone", "email",
       "retirementDate", "checkInStatus", "source", "seminarId",
       "partyId", "primaryAttendeeId", "isAdditionalGuest", "relationship",
       "assignedTeamMember", "updatedAt")
    values
      (gid, gfirst, glast, lower(trim(gfirst || ' ' || glast)),
       '', '', '',
       'not_checked_in', 'rsvp', NEW.seminar_id,
       primary_id, primary_id, true,
       case when gspouse then 'Spouse' else 'Guest' end,
       '', now_iso)
    on conflict ("id") do update set
       "firstName"    = excluded."firstName",
       "lastName"     = excluded."lastName",
       "searchName"   = excluded."searchName",
       "relationship" = excluded."relationship",
       "seminarId"    = excluded."seminarId",
       "updatedAt"    = excluded."updatedAt";
  end loop;

  return NEW;
end;
$$;

drop trigger if exists rsvp_to_attendees_trg on public.rsvps;
create trigger rsvp_to_attendees_trg
  after insert or update on public.rsvps
  for each row execute function public.rsvp_to_attendees();
