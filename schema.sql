-- =====================================================================
--  Devilrays Remote Coaching — struktur database Supabase
--  Jalankan SEKALI di Supabase: SQL Editor → New query → tempel → Run
--  Aman dijalankan ulang (tabel yang sudah ada tidak dihapus).
-- =====================================================================

-- ---------- Tabel ----------------------------------------------------

-- Siapa yang menjadi coach (diisi manual, lihat Langkah 6 tutorial)
create table if not exists public.coaches (
  user_id    uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);

-- Kode atlet: 6 karakter tanpa huruf/angka yang mirip (O/0, I/1)
create or replace function public.gen_code() returns text
language sql volatile as $$
  select 'DR-' || string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
  from generate_series(1, 6)
$$;

create table if not exists public.athletes (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  grp        text not null default '',
  events     text not null default '',
  code       text not null unique default public.gen_code(),
  created_at timestamptz not null default now()
);

-- Akun keluarga ↔ atlet (satu akun bisa terhubung ke beberapa atlet, misalnya kakak-adik)
create table if not exists public.family_links (
  user_id    uuid not null references auth.users on delete cascade,
  athlete_id uuid not null references public.athletes on delete cascade,
  email      text,
  created_at timestamptz not null default now(),
  primary key (user_id, athlete_id)
);

create table if not exists public.sessions (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('swim','gym','dryland','mobility')),
  date        date not null,
  slot        text not null default '',
  focus       text not null default '',
  duration    int  not null default 0,
  volume      int  not null default 0,
  title       text not null default '',
  content     text not null default '',
  metrics     jsonb not null default '[]',
  athlete_ids uuid[] not null default '{}',   -- kosong = untuk semua atlet
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists sessions_date_idx on public.sessions (date);

create table if not exists public.reports (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid references public.sessions on delete set null,
  athlete_id uuid not null references public.athletes on delete cascade,
  date       date not null,
  kind       text,
  title      text not null default '',
  status     text not null check (status in ('full','partial','skip')),
  rpe        int  check (rpe between 0 and 10),
  duration   int  not null default 0,
  feel       int  check (feel between 1 and 5),
  sleep      numeric,
  note       text not null default '',
  results    jsonb not null default '[]',
  role       text not null default 'Atlet',
  by_user    uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, athlete_id)
);
create index if not exists reports_athlete_idx on public.reports (athlete_id, date);

create table if not exists public.settings (
  key        text primary key,          -- 'block' atau 'estimate'
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- Catatan percobaan kode (mencegah tebak-tebakan kode)
create table if not exists public.claim_attempts (
  user_id uuid not null,
  at      timestamptz not null default now()
);

-- ---------- Fungsi bantu ---------------------------------------------

create or replace function public.is_coach() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coaches where user_id = auth.uid())
$$;

create or replace function public.my_athlete_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(athlete_id), '{}') from public.family_links where user_id = auth.uid()
$$;

-- "Hari ini" menurut WIB
create or replace function public.wib_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

-- Berapa hari ke belakang keluarga masih bisa melihat & melaporkan sesi
create or replace function public.grace_days() returns int
language sql immutable as $$ select 2 $$;

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

drop trigger if exists sessions_touch on public.sessions;
create trigger sessions_touch before update on public.sessions for each row execute function public.touch_updated_at();
drop trigger if exists reports_touch on public.reports;
create trigger reports_touch before update on public.reports for each row execute function public.touch_updated_at();

-- Keluarga memasukkan kode atlet → langsung terhubung
create or replace function public.claim_athlete(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare a public.athletes;
begin
  if auth.uid() is null then raise exception 'Silakan login dulu'; end if;
  -- Kegagalan dikembalikan sebagai {"error": ...}, bukan exception,
  -- supaya catatan percobaan tetap tersimpan dan pembatas 10x/jam bekerja.
  if (select count(*) from public.claim_attempts
       where user_id = auth.uid() and at > now() - interval '1 hour') >= 10 then
    return json_build_object('error', 'Terlalu banyak percobaan. Coba lagi 1 jam lagi.');
  end if;
  insert into public.claim_attempts (user_id) values (auth.uid());
  select * into a from public.athletes where upper(code) = upper(replace(trim(p_code), ' ', ''));
  if not found then
    return json_build_object('error', 'Kode tidak ditemukan. Periksa lagi kode dari coach.');
  end if;
  insert into public.family_links (user_id, athlete_id, email)
    values (auth.uid(), a.id, auth.jwt() ->> 'email')
    on conflict do nothing;
  return json_build_object('id', a.id, 'name', a.name);
end $$;

revoke all on function public.claim_athlete(text) from public, anon;
grant execute on function public.claim_athlete(text) to authenticated;

-- ---------- Aturan keamanan (Row Level Security) ----------------------

alter table public.coaches        enable row level security;
alter table public.athletes       enable row level security;
alter table public.family_links   enable row level security;
alter table public.sessions       enable row level security;
alter table public.reports        enable row level security;
alter table public.settings       enable row level security;
alter table public.claim_attempts enable row level security;   -- tanpa policy = tertutup untuk semua

-- coaches: tiap akun hanya bisa mengecek dirinya sendiri
drop policy if exists coaches_self on public.coaches;
create policy coaches_self on public.coaches for select to authenticated
  using (user_id = auth.uid());

-- athletes: coach semua; keluarga hanya atlet yang terhubung
drop policy if exists athletes_read on public.athletes;
create policy athletes_read on public.athletes for select to authenticated
  using (public.is_coach() or id = any (public.my_athlete_ids()));
drop policy if exists athletes_coach on public.athletes;
create policy athletes_coach on public.athletes for all to authenticated
  using (public.is_coach()) with check (public.is_coach());

-- family_links: coach semua; keluarga hanya miliknya
drop policy if exists links_read on public.family_links;
create policy links_read on public.family_links for select to authenticated
  using (public.is_coach() or user_id = auth.uid());
drop policy if exists links_coach on public.family_links;
create policy links_coach on public.family_links for all to authenticated
  using (public.is_coach()) with check (public.is_coach());

-- sessions: coach semua; keluarga hanya sesi atletnya, mulai 2 hari ke belakang
drop policy if exists sessions_read on public.sessions;
create policy sessions_read on public.sessions for select to authenticated
  using (
    public.is_coach()
    or (
      date >= public.wib_today() - public.grace_days()
      and cardinality(public.my_athlete_ids()) > 0
      and (cardinality(athlete_ids) = 0 or athlete_ids && public.my_athlete_ids())
    )
  );
drop policy if exists sessions_coach on public.sessions;
create policy sessions_coach on public.sessions for all to authenticated
  using (public.is_coach()) with check (public.is_coach());

-- reports: coach semua; keluarga membaca laporan atletnya,
-- menulis hanya untuk sesi yang masih terbuka (maks. 2 hari ke belakang)
drop policy if exists reports_read on public.reports;
create policy reports_read on public.reports for select to authenticated
  using (public.is_coach() or athlete_id = any (public.my_athlete_ids()));
drop policy if exists reports_coach on public.reports;
create policy reports_coach on public.reports for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
drop policy if exists reports_family_insert on public.reports;
create policy reports_family_insert on public.reports for insert to authenticated
  with check (
    athlete_id = any (public.my_athlete_ids())
    and date >= public.wib_today() - public.grace_days()
    and exists (select 1 from public.sessions s where s.id = session_id and s.date = reports.date)
  );
drop policy if exists reports_family_update on public.reports;
create policy reports_family_update on public.reports for update to authenticated
  using (athlete_id = any (public.my_athlete_ids()) and date >= public.wib_today() - public.grace_days())
  with check (
    athlete_id = any (public.my_athlete_ids())
    and date >= public.wib_today() - public.grace_days()
    and exists (select 1 from public.sessions s where s.id = session_id and s.date = reports.date)
  );

-- settings (tanggal mulai blok, angka estimasi): semua akun login boleh membaca, hanya coach menulis
drop policy if exists settings_read on public.settings;
create policy settings_read on public.settings for select to authenticated using (true);
drop policy if exists settings_coach on public.settings;
create policy settings_coach on public.settings for all to authenticated
  using (public.is_coach()) with check (public.is_coach());

-- Akses dasar untuk akun yang login (RLS di atas tetap membatasi barisnya)
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.athletes, public.family_links, public.sessions,
  public.reports, public.settings to authenticated;
grant select on public.coaches to authenticated;
revoke all on public.athletes, public.family_links, public.sessions, public.reports,
  public.settings, public.coaches, public.claim_attempts from anon;
