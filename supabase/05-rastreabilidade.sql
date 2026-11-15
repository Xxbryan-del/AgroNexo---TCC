-- ============================================================================
-- AGRONEXO — RASTREABILIDADE: página pública aberta pelo QR code do pedido
-- Pré-requisito: scripts 01 a 04 já aplicados.
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- Pode rodar mais de uma vez.
--
-- O QR code leva ao site com ?rastreio=<código do pedido>. Qualquer pessoa
-- (sem login) vê a ORIGEM do produto: produto, produtor, município, colheita
-- mais recente antes da venda e as etapas do pedido.
-- NÃO aparecem: nome do comprador, endereço de rua, CNPJ nem coordenadas.
-- O código é um UUID aleatório: não dá para "adivinhar" o de outro pedido.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'pedidos'
                    and column_name = 'codigo_rastreio')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'movimentacoes_estoque'
                    and column_name = 'motivo') then
    raise exception 'Rode primeiro os arquivos 01, 02, 03 e 04.';
  end if;
end $$;

drop function if exists public.rastreio_publico(uuid);
create function public.rastreio_publico(p_codigo uuid)
returns table (
  produto text, emoji text, unidade text, quantidade int,
  produtor text, produtor_cidade text, produtor_uf text,
  colheita_em timestamptz, colheita_quantidade int,
  status text, pedido_em timestamptz, confirmado_em timestamptz,
  entregue_em timestamptz, cancelado_em timestamptz,
  entrega_cidade text, entrega_uf text)
language sql stable security definer set search_path = public
as $$
  select pr.nome, pr.emoji, pr.unidade, pe.quantidade,
         u.nome, u.cidade, u.uf,
         col.criado_em, col.quantidade,
         pe.status, pe.criado_em, pe.confirmado_em, pe.entregue_em, pe.cancelado_em,
         pe.entrega_cidade, pe.entrega_uf
    from public.pedidos pe
    join public.produtos pr on pr.id = pe.produto_id
    join public.usuarios u  on u.id = pr.agricultor_id
    -- Lote: a colheita registrada mais recente ANTES da confirmação da venda
    left join lateral (
      select m.criado_em, m.quantidade
        from public.movimentacoes_estoque m
       where m.produto_id = pe.produto_id
         and m.tipo = 'entrada' and m.motivo = 'colheita'
         and m.criado_em <= coalesce(pe.confirmado_em, now())
       order by m.criado_em desc
       limit 1
    ) col on true
   where pe.codigo_rastreio = p_codigo;
$$;

revoke all on function public.rastreio_publico(uuid) from public;
grant execute on function public.rastreio_publico(uuid) to anon, authenticated;

commit;

-- CONFERÊNCIA: mostra a ficha pública do pedido mais recente
select * from public.rastreio_publico(
  (select codigo_rastreio from public.pedidos order by criado_em desc limit 1));
