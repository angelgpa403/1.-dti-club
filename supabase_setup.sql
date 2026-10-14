-- DTI Club: esquema seguro para Supabase
-- Ejecuta este archivo completo en Supabase > SQL Editor.
-- El saldo no se puede modificar desde el navegador: solo mediante funciones SQL controladas.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  coins integer not null default 0 check (coins >= 0),
  streak integer not null default 0 check (streak >= 0),
  last_claim_date date,
  created_at timestamptz not null default now()
);

create table if not exists public.daily_claims (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  claim_date date not null,
  amount integer not null default 10 check (amount = 10),
  created_at timestamptz not null default now(),
  unique(user_id, claim_date)
);

create table if not exists public.redemptions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  reward_id text not null,
  reward_name text not null,
  cost integer not null check (cost > 0),
  status text not null default 'Pendiente'
    check (status in ('Pendiente','Aprobado','Entregado','Rechazado')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.daily_claims enable row level security;
alter table public.redemptions enable row level security;

drop policy if exists "Read own profile" on public.profiles;
create policy "Read own profile" on public.profiles for select to authenticated
using (id = auth.uid());

drop policy if exists "Read own claims" on public.daily_claims;
create policy "Read own claims" on public.daily_claims for select to authenticated
using (user_id = auth.uid());

drop policy if exists "Read own redemptions" on public.redemptions;
create policy "Read own redemptions" on public.redemptions for select to authenticated
using (user_id = auth.uid());

-- No policies de INSERT/UPDATE/DELETE para perfiles, claims ni canjes:
-- los usuarios normales no pueden editar saldo ni crear reclamaciones directamente.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Reclamo atómico: la restricción única bloquea doble reclamación en el mismo día UTC.
create or replace function public.claim_daily()
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  today_utc date := (now() at time zone 'utc')::date;
  previous_date date;
  old_streak integer;
begin
  if uid is null then raise exception 'Debes iniciar sesión.'; end if;

  insert into public.profiles(id) values (uid) on conflict (id) do nothing;

  select last_claim_date, streak into previous_date, old_streak
  from public.profiles where id = uid for update;

  if previous_date = today_utc then
    raise exception 'ALREADY_CLAIMED: Ya reclamaste hoy.';
  end if;

  insert into public.daily_claims(user_id, claim_date, amount)
  values (uid, today_utc, 10);

  update public.profiles
  set coins = coins + 10,
      streak = case
        when previous_date = today_utc - 1 then old_streak + 1
        else 1
      end,
      last_claim_date = today_utc
  where id = uid;

  return json_build_object(
    'awarded', 10,
    'streak', case when previous_date = today_utc - 1 then old_streak + 1 else 1 end,
    'claim_date', today_utc
  );
end;
$$;

-- El coste y el nombre se fijan en el servidor; no confiamos en el precio del navegador.
create or replace function public.request_redemption(p_reward_id text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  r_name text;
  r_cost integer;
  current_coins integer;
  new_id bigint;
begin
  if uid is null then raise exception 'Debes iniciar sesión.'; end if;

  select name, cost into r_name, r_cost
  from (values
    ('vip_permanente', 'VIP permanente', 1200),
    ('custom_makeup', 'Custom Makeup', 900),
    ('fast_walk', 'Fast Walk', 500),
    ('custom_dress', 'Custom Dress', 750),
    ('pose_pack', 'Pose Pack', 650),
    ('special_pass', 'Pase especial', 1500)
  ) as rewards(id, name, cost)
  where id = p_reward_id;

  if r_name is null then raise exception 'Recompensa no válida.'; end if;

  select coins into current_coins from public.profiles where id = uid for update;
  if current_coins is null then raise exception 'Perfil no encontrado.'; end if;
  if current_coins < r_cost then raise exception 'INSUFFICIENT_COINS: No tienes monedas suficientes.'; end if;

  update public.profiles set coins = coins - r_cost where id = uid;
  insert into public.redemptions(user_id, reward_id, reward_name, cost)
  values (uid, p_reward_id, r_name, r_cost)
  returning id into new_id;

  return json_build_object('redemption_id', new_id, 'status', 'Pendiente');
end;
$$;

revoke all on function public.claim_daily() from public;
grant execute on function public.claim_daily() to authenticated;
revoke all on function public.request_redemption(text) from public;
grant execute on function public.request_redemption(text) to authenticated;

-- No compartas nunca la service_role key. Solo se usa la publishable/anon key en el navegador.
