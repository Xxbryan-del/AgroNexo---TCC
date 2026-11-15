-- ============================================================================
-- AGRONEXO — MOVIMENTAÇÕES DE ESTOQUE COM MOTIVO (tela Estoque)
-- Pré-requisito: 01-seguranca.sql e 02-historico-dashboard.sql já aplicados.
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- É uma transação só: se qualquer linha der erro, NADA é aplicado.
-- Pode rodar mais de uma vez.
--
-- Por que isso existe:
--   1. MOTIVO de cada entrada/saída manual. Para a previsão, "saiu 5 kg" não basta:
--      perda (estragou/venceu) é desperdício; venda na feira é demanda real.
--   2. AJUSTE ATÔMICO: a conta "estoque + 10" é feita dentro do banco, numa
--      única instrução. Nunca conflita com uma venda confirmada ao mesmo tempo.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'movimentacoes_estoque') then
    raise exception 'Rode primeiro o arquivo 02-historico-dashboard.sql.';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1) Coluna de motivo no histórico
-- ----------------------------------------------------------------------------
alter table public.movimentacoes_estoque add column if not exists motivo text;

alter table public.movimentacoes_estoque drop constraint if exists movimentacoes_motivo_valido;
alter table public.movimentacoes_estoque add constraint movimentacoes_motivo_valido check (
  motivo is null or motivo in (
    'colheita',    -- entrada: colheita / produção própria
    'compra',      -- entrada: comprado de terceiros
    'perda',       -- saída: estragou, venceu, quebrou
    'venda_fora',  -- saída: vendido fora do app (feira, balcão, encomenda)
    'doacao',      -- saída: doado
    'consumo',     -- saída: consumo da família
    'correcao',    -- entrada ou saída: correção de lançamento
    'contagem'     -- estoque acertado depois de contar o que existe de fato
  ));

-- ----------------------------------------------------------------------------
-- 2) Trigger do histórico, agora gravando o motivo
--    (mesma função do script 02, com o caso "manual:<motivo>" a mais)
-- ----------------------------------------------------------------------------
create or replace function public.registrar_movimentacao()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_origem text := coalesce(current_setting('agronexo.origem', true), '');
  v_tipo   text;
  v_pedido bigint;
  v_motivo text;
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
    else
      v_tipo := case when new.estoque > old.estoque then 'entrada' else 'ajuste' end;
      if v_origem like 'manual:%' then
        v_motivo := split_part(v_origem, ':', 2);
      end if;
    end if;
    insert into public.movimentacoes_estoque
           (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos, pedido_id, motivo)
    values (new.id, new.agricultor_id, new.nome, new.unidade, v_tipo,
            new.estoque - old.estoque, new.estoque, v_pedido, v_motivo);
  end if;

  if new.ativo is distinct from old.ativo then
    insert into public.movimentacoes_estoque
           (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos)
    values (new.id, new.agricultor_id, new.nome, new.unidade,
            case when new.ativo then 'reativado' else 'arquivado' end, 0, new.estoque);
  end if;

  return new;
end $$;

-- ----------------------------------------------------------------------------
-- 3) Função chamada pela tela Estoque
--    No site: await db.rpc('ajustar_estoque', { p_produto: 1, p_operacao: 'saida',
--                                               p_quantidade: 3, p_motivo: 'perda' })
--      entrada  → estoque + quantidade   (motivo: colheita, compra, correcao)
--      saida    → estoque − quantidade   (motivo: perda, venda_fora, doacao, consumo, correcao)
--      contagem → estoque = quantidade   (motivo gravado: contagem)
--    SECURITY INVOKER: roda com as permissões de quem chamou, então a RLS de
--    produtos vale (só o dono altera). Devolve o estoque novo.
-- ----------------------------------------------------------------------------
create or replace function public.ajustar_estoque(
  p_produto bigint, p_operacao text, p_quantidade int, p_motivo text default null)
returns int
language plpgsql security invoker set search_path = public
as $$
declare
  v_motivo text := p_motivo;
  v_novo   int;
begin
  if p_quantidade is null or p_quantidade < 0
     or (p_operacao <> 'contagem' and p_quantidade = 0) then
    raise exception 'Informe uma quantidade válida.';
  end if;

  if p_operacao = 'entrada' then
    if v_motivo is null or v_motivo not in ('colheita', 'compra', 'correcao') then
      raise exception 'Escolha o motivo da entrada.';
    end if;
  elsif p_operacao = 'saida' then
    if v_motivo is null or v_motivo not in ('perda', 'venda_fora', 'doacao', 'consumo', 'correcao') then
      raise exception 'Escolha o motivo da saída.';
    end if;
  elsif p_operacao = 'contagem' then
    v_motivo := 'contagem';
  else
    raise exception 'Operação inválida.';
  end if;

  -- Avisa o trigger do histórico qual foi o motivo
  perform set_config('agronexo.origem', 'manual:' || v_motivo, true);

  update public.produtos
     set estoque = case p_operacao
                     when 'entrada' then estoque + p_quantidade
                     when 'saida'   then estoque - p_quantidade
                     else p_quantidade
                   end
   where id = p_produto
     and agricultor_id = auth.uid()
     and (p_operacao <> 'saida' or estoque >= p_quantidade)
  returning estoque into v_novo;

  perform set_config('agronexo.origem', '', true);

  if v_novo is null then
    raise exception 'Não foi possível registrar: estoque insuficiente ou produto não encontrado.';
  end if;
  return v_novo;
end $$;

revoke all on function public.ajustar_estoque(bigint, text, int, text) from public, anon;
grant execute on function public.ajustar_estoque(bigint, text, int, text) to authenticated;

commit;

-- ============================================================================
-- CONFERÊNCIA
-- ============================================================================
select 'função ajustar_estoque' as item,
       case when exists (select 1 from pg_proc where proname = 'ajustar_estoque') then 'ok' else 'faltando' end as valor
union all
select 'coluna motivo',
       case when exists (select 1 from information_schema.columns
                          where table_name = 'movimentacoes_estoque' and column_name = 'motivo') then 'ok' else 'faltando' end
union all
select 'linhas no histórico', count(*)::text from public.movimentacoes_estoque;
