create table if not exists public.products (
  sku text primary key,
  name text not null,
  price_mxn integer not null check (price_mxn > 0),
  active boolean not null default true
);

insert into public.products (sku, name, price_mxn) values
  ('frikko-1t', 'Mini split Frikko Solo Frio', 4399),
  ('nube-15t', 'Aire Minisplit Mirage Nex Frío/Calor', 4999),
  ('viento-2t', 'Benelux Aire acondicionado inverter ac minisplit', 5199)
on conflict (sku) do update
set name = excluded.name, price_mxn = excluded.price_mxn, active = true;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  customer_phone text not null,
  customer_email text not null,
  total_mxn bigint not null check (total_mxn > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_sku text not null references public.products(sku),
  product_name text not null,
  quantity integer not null check (quantity between 1 and 10),
  unit_price_mxn integer not null check (unit_price_mxn > 0)
);

alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

revoke all on table public.products, public.orders, public.order_items
  from public, anon, authenticated;

create or replace function public.create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
begin
  if p_customer_name is null
    or pg_catalog.length(pg_catalog.btrim(p_customer_name)) not between 2 and 100 then
    raise exception 'Nombre invalido' using errcode = '22023';
  end if;

  if p_customer_phone is null
    or p_customer_phone !~ '^[+()0-9 .-]{7,25}$'
    or pg_catalog.length(pg_catalog.regexp_replace(p_customer_phone, '[^0-9]', '', 'g')) not between 7 and 15 then
    raise exception 'Telefono invalido' using errcode = '22023';
  end if;

  if p_customer_email is null
    or pg_catalog.length(p_customer_email) > 254
    or p_customer_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Correo invalido' using errcode = '22023';
  end if;

  if p_items is null then
    raise exception 'Carrito invalido' using errcode = '22023';
  end if;

  if pg_catalog.jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Carrito invalido' using errcode = '22023';
  end if;

  if pg_catalog.jsonb_array_length(p_items) not between 1 and 10 then
    raise exception 'Carrito invalido' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_items) as item(value)
    where pg_catalog.jsonb_typeof(item.value -> 'sku') is distinct from 'string'
      or pg_catalog.jsonb_typeof(item.value -> 'quantity') is distinct from 'number'
      or (item.value ->> 'quantity') !~ '^[1-9][0-9]?$'
  ) then
    raise exception 'Cantidad invalida' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_items) as item(value)
    where (item.value ->> 'quantity')::integer not between 1 and 10
  ) then
    raise exception 'Cantidad invalida' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_items) as item(value)
    group by item.value ->> 'sku'
    having pg_catalog.count(*) > 1
  ) then
    raise exception 'Productos repetidos en el carrito' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_items) as item(value)
    left join public.products as product
      on product.sku = item.value ->> 'sku' and product.active
    where product.sku is null
  ) then
    raise exception 'Producto no disponible' using errcode = '22023';
  end if;

  insert into public.orders (customer_name, customer_phone, customer_email, total_mxn)
  values (
    pg_catalog.btrim(p_customer_name),
    pg_catalog.btrim(p_customer_phone),
    pg_catalog.lower(pg_catalog.btrim(p_customer_email)),
    1
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, product_sku, product_name, quantity, unit_price_mxn)
  select
    v_order_id,
    product.sku,
    product.name,
    (item.value ->> 'quantity')::integer,
    product.price_mxn
  from pg_catalog.jsonb_array_elements(p_items) as item(value)
  join public.products as product on product.sku = item.value ->> 'sku' and product.active;

  update public.orders
  set total_mxn = (
    select pg_catalog.sum(unit_price_mxn * quantity)
    from public.order_items
    where order_id = v_order_id
  )
  where id = v_order_id;

  return v_order_id;
end;
$$;

revoke all on function public.create_order(text, text, text, jsonb) from public;
revoke all on function public.create_order(text, text, text, jsonb) from authenticated;
grant usage on schema public to anon;
grant execute on function public.create_order(text, text, text, jsonb) to anon;
