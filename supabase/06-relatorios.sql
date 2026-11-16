-- ============================================================================
-- AGRONEXO — RELATÓRIOS: impacto da plataforma (visão do administrador)
-- Pré-requisito: scripts 01 a 05 já aplicados.
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- Pode rodar mais de uma vez.
--
-- Os relatórios do AGRICULTOR não precisam deste script: eles usam a visão
-- vendas_diarias (script 02) e o histórico de estoque com motivo (script 03).
--
-- Este script cria só a função do ADMINISTRADOR: renda gerada por mês e por
-- agricultor. Ela devolve totais já somados no banco (em vez de o navegador
-- baixar pedido por pedido de toda a plataforma). Para quem não é admin,
-- volta vazia.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'pedidos'
                    and column_name = 'grupo') then
    raise exception 'Rode primeiro os arquivos 01 a 05.';
  end if;
end $$;

-- Renda gerada: pedidos confirmados ou entregues, pelo mês da CONFIRMAÇÃO
-- (mesma regra da visão vendas_diarias), no horário de Brasília.
-- p_meses: quantos meses para trás, contando o mês atual (1 a 60).
drop function if exists public.relatorio_impacto(int);
create function public.relatorio_impacto(p_meses int default 24)
returns table (mes date, agricultor_id uuid, agricultor text, cidade text, uf text,
               pedidos bigint, itens bigint, receita numeric)
language sql stable security definer set search_path = public
as $$
  select date_trunc('month', pe.confirmado_em at time zone 'America/Sao_Paulo')::date,
         u.id, u.nome, u.cidade, u.uf,
         count(*),
         sum(pe.quantidade)::bigint,
         coalesce(sum(pe.quantidade * pe.preco_unitario), 0)
    from public.pedidos pe
    join public.produtos pr on pr.id = pe.produto_id
    join public.usuarios u  on u.id = pr.agricultor_id
   where public.eh_admin()
     and pe.status in ('confirmado', 'entregue')
     and pe.confirmado_em >=
         (date_trunc('month', now() at time zone 'America/Sao_Paulo')
          - make_interval(months => greatest(1, least(coalesce(p_meses, 24), 60)) - 1))
         at time zone 'America/Sao_Paulo'
   group by 1, 2, 3, 4, 5
   order by 1, 2;
$$;

revoke all on function public.relatorio_impacto(int) from public, anon;
grant execute on function public.relatorio_impacto(int) to authenticated;

commit;

-- CONFERÊNCIA (no SQL Editor você não é o admin do site, então a função em si
-- voltaria vazia: aqui só confirmamos que ela foi criada)
select routine_name as funcao_criada
  from information_schema.routines
 where routine_schema = 'public' and routine_name = 'relatorio_impacto';
