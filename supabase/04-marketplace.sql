-- ============================================================================
-- AGRONEXO — MARKETPLACE: pedido com entrega, localização e código de rastreio
-- Pré-requisito: scripts 01, 02 e 03 já aplicados.
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- É uma transação só: se qualquer linha der erro, NADA é aplicado.
-- Pode rodar mais de uma vez.
--
-- O que muda:
--   1. Localização opcional de cada usuário (comprador e agricultor), gravada só
--      pela própria pessoa. A coordenada nunca sai do banco: o comprador recebe
--      apenas a DISTÂNCIA até cada produtor (LGPD).
--   2. Pedido ganha: código da compra (carrinho), endereço de entrega,
--      observação, nome do comprador e um código de rastreio único.
--   3. Ao criar o pedido, o banco confere estoque, produto ativo e preço.
--   4. Depois de criado, só o STATUS do pedido pode mudar.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'pedidos'
                    and column_name = 'confirmado_em') then
    raise exception 'Rode primeiro os arquivos 01, 02 e 03.';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1) LOCALIZAÇÃO (opcional) de cada usuário
-- ----------------------------------------------------------------------------
alter table public.usuarios
  add column if not exists latitude  double precision,
  add column if not exists longitude double precision;

-- Cada pessoa grava só a própria localização (a tabela usuarios não tem
-- permissão de UPDATE pelo site: assim ninguém muda o próprio perfil para admin).
create or replace function public.definir_minha_localizacao(p_lat double precision, p_lng double precision)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Faça login para salvar a localização.';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Localização inválida.';
  end if;
  update public.usuarios
     set latitude  = round(p_lat::numeric, 5),   -- ~1 metro de precisão
         longitude = round(p_lng::numeric, 5)
   where id = auth.uid();
end $$;
revoke all on function public.definir_minha_localizacao(double precision, double precision) from public, anon;
grant execute on function public.definir_minha_localizacao(double precision, double precision) to authenticated;

-- ----------------------------------------------------------------------------
-- 2) PEDIDO: compra, entrega e rastreio
-- ----------------------------------------------------------------------------
alter table public.pedidos
  add column if not exists grupo              uuid,   -- mesma compra (carrinho) = mesmo grupo
  add column if not exists codigo_rastreio    uuid default gen_random_uuid(),
  add column if not exists comprador_nome     text,   -- para o agricultor saber de quem é o pedido
  add column if not exists entrega_cep        text,
  add column if not exists entrega_logradouro text,
  add column if not exists entrega_numero     text,
  add column if not exists entrega_cidade     text,
  add column if not exists entrega_uf         text,
  add column if not exists entrega_lat        double precision,
  add column if not exists entrega_lng        double precision,
  add column if not exists observacao         text;

alter table public.pedidos alter column codigo_rastreio set not null;
create unique index if not exists pedidos_codigo_rastreio on public.pedidos (codigo_rastreio);
create index if not exists pedidos_grupo on public.pedidos (grupo);

alter table public.pedidos drop constraint if exists pedidos_observacao_tamanho;
alter table public.pedidos add constraint pedidos_observacao_tamanho
  check (observacao is null or char_length(observacao) <= 300) not valid;

-- ----------------------------------------------------------------------------
-- 3) PEDIDO NOVO: o banco confere tudo e preenche o que não pode vir do navegador
-- ----------------------------------------------------------------------------
create or replace function public.preparar_pedido()
returns trigger
language plpgsql set search_path = public
as $$
declare
  v_prod record;
  v_nome text;
begin
  select id, nome, preco, estoque, ativo, agricultor_id into v_prod
    from public.produtos where id = new.produto_id;
  if not found then
    raise exception 'Produto não encontrado.';
  end if;
  new.preco_unitario := v_prod.preco;   -- preço do momento da compra

  if auth.uid() is not null then         -- pedido feito pelo site
    if v_prod.ativo is false then
      raise exception '"%" não está mais à venda.', v_prod.nome;
    end if;
    if new.quantidade > v_prod.estoque then
      raise exception 'Estoque insuficiente para "%": disponível %.', v_prod.nome, v_prod.estoque;
    end if;
    if v_prod.agricultor_id = auth.uid() then
      raise exception 'Você não pode comprar o próprio produto.';
    end if;
    new.status          := 'pendente';
    new.criado_em       := now();
    new.confirmado_em   := null;
    new.entregue_em     := null;
    new.cancelado_em    := null;
    new.codigo_rastreio := gen_random_uuid();          -- nunca escolhido pelo navegador
    new.grupo           := coalesce(new.grupo, gen_random_uuid());
    select nome into v_nome from public.usuarios where id = new.comprador_id;
    new.comprador_nome  := v_nome;
  end if;
  return new;
end $$;

-- ----------------------------------------------------------------------------
-- 4) MUDANÇA DE PEDIDO: pelo site, só o status muda (regras do script 02)
--    A comparação usa a linha inteira, então vale também para colunas futuras.
-- ----------------------------------------------------------------------------
create or replace function public.validar_pedido()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_dono uuid;
begin
  if v_uid is not null then
    new.confirmado_em := old.confirmado_em;
    new.entregue_em   := old.entregue_em;
    new.cancelado_em  := old.cancelado_em;
    if (to_jsonb(new) - array['status', 'confirmado_em', 'entregue_em', 'cancelado_em'])
       is distinct from
       (to_jsonb(old) - array['status', 'confirmado_em', 'entregue_em', 'cancelado_em']) then
      raise exception 'Só o status do pedido pode ser alterado.';
    end if;
  end if;

  if new.status = old.status then
    return new;
  end if;

  if not (   (old.status = 'pendente'   and new.status in ('confirmado', 'cancelado'))
          or (old.status = 'confirmado' and new.status in ('entregue',   'cancelado'))) then
    raise exception 'Mudança de status inválida: % → %.', old.status, new.status;
  end if;

  if v_uid is not null then
    select agricultor_id into v_dono from public.produtos where id = new.produto_id;
    if v_uid = v_dono then
      null;
    elsif v_uid = old.comprador_id and old.status = 'pendente' and new.status = 'cancelado' then
      null;
    else
      raise exception 'Você não tem permissão para mudar este pedido.';
    end if;
  end if;

  if    new.status = 'confirmado' then new.confirmado_em := now();
  elsif new.status = 'entregue'   then new.entregue_em   := now();
  elsif new.status = 'cancelado'  then new.cancelado_em  := now();
  end if;

  return new;
end $$;

-- ----------------------------------------------------------------------------
-- 5) VITRINE DE PRODUTORES com distância (substitui a versão do script 01)
--    Devolve nome, cidade, UF e a distância em km até quem está consultando.
--    As coordenadas em si nunca saem do banco.
-- ----------------------------------------------------------------------------
drop function if exists public.produtores_publicos();
create function public.produtores_publicos()
returns table (id uuid, nome text, cidade text, uf text, distancia_km numeric)
language sql stable security definer set search_path = public
as $$
  with eu as (
    select latitude, longitude from public.usuarios where id = auth.uid()
  )
  select u.id, u.nome, u.cidade, u.uf,
         case
           when eu.latitude is null or u.latitude is null then null
           else round((6371 * 2 * asin(least(1, sqrt(
                  power(sin(radians(u.latitude - eu.latitude) / 2), 2)
                  + cos(radians(eu.latitude)) * cos(radians(u.latitude))
                  * power(sin(radians(u.longitude - eu.longitude) / 2), 2)))))::numeric, 1)
         end
    from public.usuarios u
    left join eu on true
   where u.perfil = 'agricultor';
$$;
revoke all on function public.produtores_publicos() from public, anon;
grant execute on function public.produtores_publicos() to authenticated;

commit;

-- ============================================================================
-- CONFERÊNCIA
-- ============================================================================
select 'colunas novas em pedidos' as item, count(*)::text as valor
  from information_schema.columns
 where table_schema = 'public' and table_name = 'pedidos'
   and column_name in ('grupo', 'codigo_rastreio', 'comprador_nome', 'entrega_logradouro', 'entrega_lat', 'observacao')
union all
select 'pedidos com código de rastreio', count(*)::text from public.pedidos where codigo_rastreio is not null
union all
select 'produtores na vitrine', count(*)::text from public.produtores_publicos();
