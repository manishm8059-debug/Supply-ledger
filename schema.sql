-- Supply Ledger: database setup for Supabase.
-- Run this once: Supabase dashboard -> SQL Editor -> New query -> paste -> Run.
-- It is safe to run again (it skips what already exists).

-- 1) People ---------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  name text,
  party text,
  role text not null default 'partner' check (role in ('owner','partner')),
  created_at timestamptz not null default now()
);

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'owner');
$$;

-- Every new user gets a profile. The very FIRST user ever created becomes the owner.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role)
  values (
    new.id, new.email, split_part(new.email, '@', 1),
    case when exists (select 1 from public.profiles where role = 'owner') then 'partner' else 'owner' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Users that already exist (if any) get a profile too. The oldest one becomes the owner.
insert into public.profiles (id, email, name, role)
select u.id, u.email, split_part(u.email, '@', 1),
       case when u.id = (select id from auth.users order by created_at asc limit 1)
                 and not exists (select 1 from public.profiles where role = 'owner')
            then 'owner' else 'partner' end
from auth.users u
on conflict (id) do nothing;

-- 2) Items and rates ------------------------------------------------------
create table if not exists public.items (
  id text primary key,
  item text not null,
  unit text not null default 'pcs',
  cat text not null default 'Other',
  hist jsonb not null default '[]'::jsonb
);

-- 3) Goods taken by a party (one row per entry) ---------------------------
create table if not exists public.entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,   -- the partner account this entry belongs to
  created_by uuid not null default auth.uid(),
  date date not null,
  party text not null,
  item text not null,
  qty numeric not null check (qty > 0),
  unit text not null default 'pcs',
  note text,
  rate numeric,
  confirmed boolean not null default false,
  confirmed_at timestamptz,
  edited_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists entries_owner_idx on public.entries (owner_id, date desc);

-- 4) Payments and opening balances ----------------------------------------
create table if not exists public.records (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('payment','opening')),
  date date not null,
  party text not null,
  amount numeric not null,
  mode text,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists records_owner_idx on public.records (owner_id, date desc);

-- 5) Security: who can see and change what --------------------------------
alter table public.profiles enable row level security;
alter table public.items    enable row level security;
alter table public.entries  enable row level security;
alter table public.records  enable row level security;

grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.items, public.entries, public.records to authenticated;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (public.is_owner() or id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists items_select on public.items;
drop policy if exists items_write on public.items;
create policy items_select on public.items for select to authenticated using (true);
create policy items_write  on public.items for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- Partners see only their own entries. The owner sees everything.
-- A partner can add entries, and change or delete them only until the owner confirms them.
-- A partner can never set a rate or confirm an entry.
drop policy if exists entries_select on public.entries;
drop policy if exists entries_insert on public.entries;
drop policy if exists entries_update on public.entries;
drop policy if exists entries_delete on public.entries;
create policy entries_select on public.entries for select to authenticated
  using (public.is_owner() or owner_id = auth.uid());
create policy entries_insert on public.entries for insert to authenticated
  with check (public.is_owner() or (owner_id = auth.uid() and created_by = auth.uid()
              and confirmed = false and confirmed_at is null and rate is null));
create policy entries_update on public.entries for update to authenticated
  using (public.is_owner() or (owner_id = auth.uid() and confirmed = false))
  with check (public.is_owner() or (owner_id = auth.uid() and created_by = auth.uid()
              and confirmed = false and confirmed_at is null and rate is null));
create policy entries_delete on public.entries for delete to authenticated
  using (public.is_owner() or (owner_id = auth.uid() and confirmed = false));

-- Payments and opening balances: partners can only read their own. Only the owner writes.
drop policy if exists records_select on public.records;
drop policy if exists records_write on public.records;
create policy records_select on public.records for select to authenticated
  using (public.is_owner() or owner_id = auth.uid());
create policy records_write on public.records for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- 6) Your sizes (rate is empty until you set it in the app) ----------------
insert into public.items (id, item, unit, cat, hist) values
 ('polybag-6-5x8',         'Polybag 6.5x8',          'pcs', 'Polybag', '[]'),
 ('polybag-8x10',          'Polybag 8x10',           'pcs', 'Polybag', '[]'),
 ('polybag-10x12',         'Polybag 10x12',          'pcs', 'Polybag', '[]'),
 ('polybag-10x14',         'Polybag 10x14',          'pcs', 'Polybag', '[]'),
 ('polybag-12-5x16',       'Polybag 12.5x16',        'pcs', 'Polybag', '[]'),
 ('box-2-5x1-75x12-3ply',  'Box 2.5x1.75x12 3PLY',   'pcs', 'Box',     '[]'),
 ('flap-box-brown-4x4x1-5','Flap Box Brown 4x4x1.5', 'pcs', 'Box',     '[]'),
 ('flap-box-brown-4-5x3x1','Flap Box Brown 4.5x3x1', 'pcs', 'Box',     '[]'),
 ('flap-box-brown-6x4x2',  'Flap Box Brown 6x4x2',   'pcs', 'Box',     '[]'),
 ('flap-box-brown-7x5-5x2','Flap Box Brown 7x5.5x2', 'pcs', 'Box',     '[]'),
 ('box-3-5x2x12-7-3ply',   'Box 3.5x2x12.7 3PLY',    'pcs', 'Box',     '[]'),
 ('box-3x2-5x8-3ply',      'Box 3x2.5x8 3PLY',       'pcs', 'Box',     '[]'),
 ('box-6x6x6',             'Box 6x6x6',              'pcs', 'Box',     '[]'),
 ('box-5x5x5',             'Box 5x5x5',              'pcs', 'Box',     '[]'),
 ('box-6x4x4',             'Box 6x4x4',              'pcs', 'Box',     '[]')
on conflict (id) do nothing;