-- ============================================================================
-- AGRONEXO — HISTÓRICO DE VENDAS E ESTOQUE (base do Dashboard e da previsão)
-- Pré-requisito: 01-seguranca.sql já aplicado.
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- É uma transação só: se qualquer linha der erro, NADA é aplicado.
-- Pode rodar mais de uma vez.
--
-- Por que isso existe: previsão de vendas só é boa se os dados forem precisos.
--   1. Data real da venda: o pedido passa a guardar QUANDO foi confirmado
--      (antes só havia a data em que o comprador pediu).
--   2. Histórico de estoque: toda entrada, saída, venda, cancelamento e exclusão
--      fica registrada — inclusive de produtos apagados.
--   3. Arquivar em vez de apagar: o produto sai da vitrine, o histórico fica.
--   4. Vendas por dia calculadas no banco (horário de Brasília): o Dashboard e a
--      previsão usam exatamente os mesmos números.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'pedidos'
                    and column_name = 'preco_unitario') then
    raise exception 'Rode primeiro o arquivo 01-seguranca.sql.';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1) DATAS DE CADA ETAPA DO PEDIDO
-- ----------------------------------------------------------------------------
alter table public.pedidos
  add column if not exists confirmado_em timestamptz,
  add column if not exists entregue_em   timestamptz,
  add column if not exists cancelado_em  timestamptz;

-- Pedidos antigos não têm essas datas. A melhor aproximação disponível é a data
-- do pedido; os novos já terão a data exata.
update public.pedidos set confirmado_em = criado_em
 where status in ('confirmado', 'entregue') and confirmado_em is null;
update public.pedidos set entregue_em = criado_em
 where status = 'entregue' and entregue_em is null;
update public.pedidos set cancelado_em = criado_em
 where status = 'cancelado' and cancelado_em is null;

-- ----------------------------------------------------------------------------
-- 2) PRODUTO ARQUIVADO (sai da vitrine sem apagar o histórico)
--    Produto que já teve pedido nem pode ser apagado (o pedido aponta para ele).
-- ----------------------------------------------------------------------------
alter table public.produtos add column if not exists ativo boolean not null default true;

-- ----------------------------------------------------------------------------
-- 3) HISTÓRICO DE ESTOQUE
--    produto_id SEM chave estrangeira de propósito: o registro continua
--    existindo depois que o produto é apagado (nome e unidade ficam guardados).
-- ----------------------------------------------------------------------------
create table if not exists public.movimentacoes_estoque (
  id            bigint generated always as identity primary key,
  produto_id    bigint,
  agricultor_id uuid   not null,
  produto_nome  text   not null,
  unidade       text,
  tipo          text   not null check (tipo in (
                  'saldo_inicial', -- estoque que já existia quando o histórico começou
                  'cadastro',      -- produto novo
                  'entrada',       -- reposição (estoque aumentou à mão)
                  'ajuste',        -- saída manual: perda, doação, correção
                  'venda',         -- baixa automática por pedido confirmado
                  'cancelamento',  -- estoque devolvido por pedido cancelado
                  'arquivado', 'reativado', 'exclusao')),
  quantidade    int    not null,  -- variação: positivo entrou, negativo saiu
  estoque_apos  int    not null,
  pedido_id     bigint,
  autor_id      uuid   default auth.uid(),
  criado_em     timestamptz not null default now()
);
create index if not exists movimentacoes_agricultor_data
  on public.movimentacoes_estoque (agricultor_id, criado_em desc);
create index if not exists movimentacoes_produto_data
  on public.movimentacoes_estoque (produto_id, criado_em desc);

-- Ponto de partida: o estoque atual de cada produto vira "saldo inicial"
insert into public.movimentacoes_estoque
       (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos)
select p.id, p.agricultor_id, p.nome, p.unidade, 'saldo_inicial', p.estoque, p.estoque
  from public.produtos p
 where not exists (select 1 from public.movimentacoes_estoque m where m.produto_id = p.id);

alter table public.movimentacoes_estoque enable row level security;
drop policy if exists "historico_do_agricultor_ou_admin" on public.movimentacoes_estoque;
create policy "historico_do_agricultor_ou_admin" on public.movimentacoes_estoque
  for select to authenticated
  using (agricultor_id = auth.uid() or public.eh_admin());
-- Sem policy de INSERT/UPDATE/DELETE: só os triggers escrevem aqui,
-- e ninguém consegue editar ou apagar o histórico pelo site.

-- Registra toda mudança de estoque/produto.
-- Quando a mudança vem de um pedido, baixar_estoque() avisa por uma variável
-- da transação ("agronexo.origem"), e o registro sai como venda ou cancelamento.
create or replace function public.registrar_movimentacao()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_origem text := coalesce(current_setting('agronexo.origem', true), '');
  v_tipo   text;
  v_pedido bigint;
begin
  if tg_op = 'INSERT' then
    insert into public.movimentacoes_estoque
           (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos)
    values (new.id, new.agricultor_id, new.nome, new.unidade, 'cadastro', new.estoque, new.estoque);
    return new;
  end if;

  if tg_op = 'DELETE' then
    insert into public.movimentacoes_estoque
           (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos)
    values (old.id, old.agricultor_id, old.nome, old.unidade, 'exclusao', -old.estoque, 0);
    return old;
  end if;

  -- UPDATE
  if new.estoque is distinct from old.estoque then
    if v_origem like 'venda:%' then
      v_tipo := 'venda';        v_pedido := split_part(v_origem, ':', 2)::bigint;
    elsif v_origem like 'cancelamento:%' then
      v_tipo := 'cancelamento'; v_pedido := split_part(v_origem, ':', 2)::bigint;
    elsif new.estoque > old.estoque then
      v_tipo := 'entrada';
    else
      v_tipo := 'ajuste';
    end if;
    insert into public.movimentacoes_estoque
           (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos, pedido_id)
    values (new.id, new.agricultor_id, new.nome, new.unidade, v_tipo,
            new.estoque - old.estoque, new.estoque, v_pedido);
  end if;

  if new.ativo is distinct from old.ativo then
    insert into public.movimentacoes_estoque
           (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos)
    values (new.id, new.agricultor_id, new.nome, new.unidade,
            case when new.ativo then 'reativado' else 'arquivado' end, 0, new.estoque);
  end if;

  return new;
end $$;

drop trigger if exists trg_registrar_movimentacao on public.produtos;
create trigger trg_registrar_movimentacao
  after insert or update or delete on public.produtos
  for each row execute function public.registrar_movimentacao();

-- ----------------------------------------------------------------------------
-- 4) PEDIDOS — mesmas regras do 01, agora gravando a data de cada etapa
-- ----------------------------------------------------------------------------
create or replace function public.preparar_pedido()
returns trigger
language plpgsql set search_path = public
as $$
declare
  v_preco numeric(10,2);
begin
  select preco into v_preco from public.produtos where id = new.produto_id;
  if v_preco is null then
    raise exception 'Produto não encontrado.';
  end if;
  new.preco_unitario := v_preco;
  if auth.uid() is not null then
    new.status        := 'pendente';
    new.criado_em     := now();
    new.confirmado_em := null;
    new.entregue_em   := null;
    new.cancelado_em  := null;
  end if;
  return new;
end $$;

create or replace function public.validar_pedido()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_dono uuid;
begin
  -- Pelo site, as datas só mudam pelas regras abaixo (ninguém "volta no tempo")
  if v_uid is not null then
    new.confirmado_em := old.confirmado_em;
    new.entregue_em   := old.entregue_em;
    new.cancelado_em  := old.cancelado_em;
  end if;

  if new.produto_id     is distinct from old.produto_id
  or new.comprador_id   is distinct from old.comprador_id
  or new.quantidade     is distinct from old.quantidade
  or (old.preco_unitario is not null and new.preco_unitario is distinct from old.preco_unitario)
  or new.criado_em      is distinct from old.criado_em then
    raise exception 'Só o status do pedido pode ser alterado.';
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

create or replace function public.baixar_estoque()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.status = 'pendente' and new.status = 'confirmado' then
    perform set_config('agronexo.origem', 'venda:' || new.id, true);
    update public.produtos
       set estoque = estoque - new.quantidade
     where id = new.produto_id
       and estoque >= new.quantidade;
    if not found then
      raise exception 'Estoque insuficiente para confirmar este pedido.';
    end if;
  elsif old.status = 'confirmado' and new.status = 'cancelado' then
    perform set_config('agronexo.origem', 'cancelamento:' || new.id, true);
    update public.produtos
       set estoque = estoque + new.quantidade
     where id = new.produto_id;
  end if;
  perform set_config('agronexo.origem', '', true);
  return new;
end $$;

-- ----------------------------------------------------------------------------
-- 5) VENDAS POR DIA (base do gráfico e da previsão)
--    security_invoker = a visão respeita a RLS de quem consulta:
--    agricultor vê as próprias vendas, comprador as próprias compras, admin tudo.
--    Venda = pedido confirmado ou entregue; conta na data da CONFIRMAÇÃO.
--    Pedido cancelado depois de confirmado sai da conta.
-- ----------------------------------------------------------------------------
create or replace view public.vendas_diarias
with (security_invoker = true) as
select (pe.confirmado_em at time zone 'America/Sao_Paulo')::date as dia,
       pr.agricultor_id,
       pe.produto_id,
       pr.nome                                as produto_nome,
       pr.unidade,
       count(*)                               as pedidos,
       sum(pe.quantidade)                     as quantidade,
       sum(pe.quantidade * pe.preco_unitario) as receita
  from public.pedidos pe
  join public.produtos pr on pr.id = pe.produto_id
 where pe.status in ('confirmado', 'entregue')
   and pe.confirmado_em is not null
 group by 1, 2, 3, 4, 5;

revoke all on public.vendas_diarias from anon;
grant select on public.vendas_diarias to authenticated;

-- ----------------------------------------------------------------------------
-- 6) TEMPO REAL também para o histórico (o feed "Atividade recente" atualiza sozinho)
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and tablename = 'movimentacoes_estoque') then
    alter publication supabase_realtime add table public.movimentacoes_estoque;
  end if;
end $$;

commit;

-- ============================================================================
-- CONFERÊNCIA
-- ============================================================================
select 'histórico (linhas)' as item, count(*)::text as valor from public.movimentacoes_estoque
union all
select 'pedidos com data de confirmação', count(*)::text from public.pedidos where confirmado_em is not null
union all
select 'dias com venda', count(distinct dia)::text from public.vendas_diarias
union all
select 'produtos arquivados', count(*)::text from public.produtos where not ativo;
