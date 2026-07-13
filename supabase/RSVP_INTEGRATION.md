# Merging the RSVP page into the Check-In database

Goal: one Supabase project holds everything, and every RSVP shows up in the
Check-In app automatically. We move the RSVP page's two tables (`seminars`,
`rsvps`) into the **Check-In** project (`yoegkistqqloqhjsruer`), add a trigger
that expands each RSVP into attendee rows, then point the RSVP page at this
project. The old RSVP project (`vtxxcgerwnquoeatjroq`) can be retired afterward.

Do the steps in order. Steps 1–3 are reversible; keep the old project until
step 5 confirms everything works.

---

## 1. Create the tables + trigger (Check-In project)

Supabase dashboard → **Check-In** project → SQL Editor → paste all of
[`rsvp_integration.sql`](./rsvp_integration.sql) → **Run**. It creates
`seminars`, `rsvps`, their RLS/grants, the `set_active_seminar` RPC, and the
`rsvp_to_attendees` trigger. It's safe to re-run.

## 2. Copy existing RSVP data over

We move the current seminars and RSVPs across as JSON — this preserves the
`guests` array and every id exactly. Inserting the RSVPs fires the trigger, so
existing guests back-fill into `attendees` in the same step.

**a. In the OLD RSVP project** (`vtxxcgerwnquoeatjroq`) SQL editor, run each of
these and copy the single JSON value from the result:

```sql
select coalesce(json_agg(s), '[]') from public.seminars s;   -- copy result -> SEMINARS_JSON
select coalesce(json_agg(r), '[]') from public.rsvps r;      -- copy result -> RSVPS_JSON
```

**b. In the CHECK-IN project** SQL editor, paste each JSON where shown. Run the
seminars block first (the trigger needs the seminars to exist for the FK):

```sql
insert into public.seminars
select * from json_populate_recordset(null::public.seminars, '<PASTE SEMINARS_JSON>')
on conflict ("id") do nothing;

insert into public.rsvps
select * from json_populate_recordset(null::public.rsvps, '<PASTE RSVPS_JSON>')
on conflict ("id") do nothing;   -- trigger fires here -> attendees back-fill
```

**c. Verify** in the Check-In project:

```sql
select count(*) from public.rsvps;
select count(*) from public.attendees where "source" = 'rsvp';   -- >= rsvp count (primaries + guests)
select "firstName","lastName","relationship","isAdditionalGuest","partyId"
from public.attendees where "source" = 'rsvp' order by "partyId","isAdditionalGuest";
```

Open the Check-In app and confirm the RSVP guests appear and their spouses/guests
sit under the same person (search by a known name).

## 3. Point the RSVP page at the Check-In project

In the **RSVP-Page** repo, edit `js/config.js`:

```js
window.RSVP_CONFIG = {
  supabaseUrl: 'https://yoegkistqqloqhjsruer.supabase.co',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlvZWdraXN0cXFsb3FoanNydWVyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM5NjM2OTAsImV4cCI6MjA5OTUzOTY5MH0.kShB4exoYxK7W_WwDP6sESBqIWlZUhckK_wkn3CdooA'
};
```

Commit + push (GitHub Pages redeploys). That anon key is the Check-In project's
public key — safe to ship; RLS is what actually protects the data.

## 4. RSVP admin login

The RSVP admin page (`admin.html`) signs in with Supabase Auth. It now talks to
the Check-In project, so sign in with a user that exists **there** — the shared
staff account `hrg@uscwealth.com` works. (Optionally add a dedicated admin user
in Check-In project → Authentication → Users.)

## 5. Smoke-test the full loop, then retire the old project

1. On the live RSVP page, submit a test reservation with a guest.
2. In the Check-In app, search for that test name — the person **and** their
   guest should be there within a refresh, guest nested under the same party.
3. Delete the test rsvp (Check-In project → Table editor → `rsvps`), and its
   attendee rows if you like.
4. Once you've watched a real cycle work, the old RSVP project
   (`vtxxcgerwnquoeatjroq`) is dead weight — pause or delete it.

---

## Multiple seminars — one roster at a time

Each seminar keeps its own RSVP/guest list automatically: every `rsvps` row has a
`seminar_id`, and the trigger stamps that onto each attendee's `seminarId`. You do
**not** make separate tables per seminar.

The Check-In app is scoped to one seminar at a time:

- **Admin Dashboard → "Active Seminar"** dropdown at the top picks which seminar's
  roster, stats, check-ins, scheduled calls, and exports are shown. The choice is
  stored in the shared `settings` table (`checkinSeminarId`), so every kiosk shows
  the same seminar.
- Default when unset: the seminar the RSVP admin marked active, else the soonest by date.
- Walk-ins and CSV-imported guests are stamped with the currently-selected seminar.
- Adding a seminar never touches the schema — just insert a `seminars` row (below).

Because the app can only *edit* seminars (not create them), insert each real
seminar once in the Check-In project's SQL editor:

```sql
insert into public.seminars (name, event_date, start_time, venue, capacity, is_active)
values ('Your Seminar Title', '2026-10-15', '18:00', 'Houston, Texas', 40, true);
```

## How it behaves / limits

- **New RSVP → attendees:** instant, on insert. No polling, no second database.
- **Idempotent:** attendee ids are `rsvp_<rsvpId>` (+ `_g_<guestId>` per guest),
  so re-running the back-fill or editing an RSVP never duplicates people.
- **Pre-event RSVP edits** (name/phone/email/retirement) flow through on update.
  Check-in fields (checked-in status, assigned team member, follow-ups) are
  never overwritten by an RSVP edit.
- **Not handled (rare, by design):** deleting an RSVP or removing a guest from
  one does *not* delete the already-created attendee — so a checked-in guest is
  never silently dropped. Remove those in the Check-In app if needed.
- Guest first/last name is split on the first space (`"Daniel Whitfield"` →
  first `Daniel`, last `Whitfield`); `spouse:true` guests get relationship
  `Spouse`, others `Guest`.
