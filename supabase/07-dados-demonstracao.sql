-- ============================================================================
-- AGRONEXO — DADOS DE DEMONSTRAÇÃO (opcional, para a apresentação do TCC)
-- Pré-requisito: scripts 01 a 06 já aplicados.
--
-- Gera 60 semanas (pouco mais de 1 ano) de vendas SIMULADAS para uma conta de
-- demonstração. Assim a banca vê a previsão funcionando com todos os métodos
-- (média móvel, regressão e sazonalidade), o que um sistema recém-lançado
-- ainda não teria com dados reais.
--
-- ANTES DE RODAR
--   1. No site, cadastre DUAS contas novas, só para a demonstração:
--        • uma de AGRICULTOR  (ex.: seu.email+agricultor@gmail.com)
--        • uma de COMPRADOR   (ex.: seu.email+comprador@gmail.com)
--   2. Troque os dois emails logo abaixo (v_email_agricultor e v_email_comprador).
--   3. SQL Editor → New query → cole o arquivo inteiro → Run.
--
-- O QUE O SCRIPT FAZ
--   • Renomeia as duas contas para "... (dados simulados)": ninguém confunde
--     com dados reais, nem na tela nem no artigo.
--   • APAGA os produtos, pedidos e histórico DESSA conta de agricultor e gera
--     tudo de novo (pode rodar mais de uma vez: sempre recomeça do zero e,
--     pela semente fixa, gera os mesmos números).
--   • Recusa rodar se a conta tiver pedidos de outros compradores (seriam
--     dados reais).
--   • Cria 10 produtos (legumes, verduras, frutas, raízes, temperos e outros)
--     com tendência, sazonalidade e ruído diferentes; vendas
--     pelo app quase todo dia, feira aos sábados (venda fora do app), colheita
--     e perdas às segundas, consumo da família no dia 1º, alguns cancelamentos,
--     os pedidos de ontem ainda "a entregar" (para a rota) e 2 de hoje
--     "a confirmar" (para mostrar a confirmação ao vivo na apresentação).
--
-- PARA REMOVER depois da apresentação: veja o bloco comentado no fim do arquivo.
-- ============================================================================

begin;

do $$
declare
  -- >>> TROQUE PELOS EMAILS DAS DUAS CONTAS DE DEMONSTRAÇÃO <<<
  v_email_agricultor text := 'agricultor.demo@exemplo.com';
  v_email_comprador  text := 'comprador.demo@exemplo.com';

  v_agr    uuid;
  v_comp   uuid;
  v_cnome  text; v_ccep text; v_clog text; v_ccid text; v_cuf text;
  v_hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  v_dias   int  := 420;              -- 60 semanas, terminando ontem (o teste da previsão também usa a sazonalidade)
  v_inicio date;
  v_prod   record;
  v_id     bigint;
  v_dia    date;
  v_t      int;
  v_estoque int;
  v_semana double precision;         -- demanda esperada da semana (app + fora)
  v_qtd    int;
  v_k      int;
  v_parte  int;
  v_i      int;
  v_colhido int;                     -- colheita da semana anterior (base das perdas)
  v_hora   timestamptz;
  v_conf   timestamptz;
  v_pedido bigint;
  v_status text;
begin
  if v_email_agricultor like '%@exemplo.com' or v_email_comprador like '%@exemplo.com' then
    raise exception 'Troque os dois emails no começo do script pelos das contas de demonstração.';
  end if;

  select id into v_agr  from auth.users where lower(email) = lower(trim(v_email_agricultor));
  select id into v_comp from auth.users where lower(email) = lower(trim(v_email_comprador));
  if v_agr is null then raise exception 'Conta % não encontrada: cadastre-a pelo site primeiro.', v_email_agricultor; end if;
  if v_comp is null then raise exception 'Conta % não encontrada: cadastre-a pelo site primeiro.', v_email_comprador; end if;
  if not exists (select 1 from public.usuarios where id = v_agr and perfil = 'agricultor') then
    raise exception 'A conta % precisa ser de agricultor.', v_email_agricultor;
  end if;
  if not exists (select 1 from public.usuarios where id = v_comp and perfil = 'comprador') then
    raise exception 'A conta % precisa ser de comprador.', v_email_comprador;
  end if;
  if exists (select 1 from public.pedidos pe
               join public.produtos pr on pr.id = pe.produto_id
              where pr.agricultor_id = v_agr and pe.comprador_id <> v_comp) then
    raise exception 'A conta % tem pedidos de outros compradores (dados reais). Use uma conta só para a demonstração.', v_email_agricultor;
  end if;

  perform setseed(0.2026);           -- mesma semente = mesmos números a cada execução
  v_inicio := v_hoje - v_dias;

  update public.usuarios set nome = 'Sítio Demonstração (dados simulados)'   where id = v_agr;
  update public.usuarios set nome = 'Mercado Demonstração (dados simulados)' where id = v_comp;
  select nome, cep, logradouro, cidade, uf into v_cnome, v_ccep, v_clog, v_ccid, v_cuf
    from public.usuarios where id = v_comp;

  -- Recomeça do zero (só desta conta de demonstração)
  delete from public.pedidos where produto_id in (select id from public.produtos where agricultor_id = v_agr);
  delete from public.produtos where agricultor_id = v_agr;
  delete from public.movimentacoes_estoque where agricultor_id = v_agr;

  -- semana: demanda média por semana (app + fora) no começo · cresce: crescimento em 1 ano
  -- amp/pico: força e mês de pico da sazonalidade · perda: fração perdida · pend: pedido "a confirmar" hoje
  for v_prod in
    select * from (values
      ('Tomate',        '🍅', 'kg',     7.50::numeric, 45, 10, 0.06, 0.20, 0.25,  8, 4),
      ('Alface crespa', '🥬', 'un',     2.50::numeric, 70, 15, 0.12, 0.10, 0.15,  1, 0),
      ('Queijo minas',  '🧀', 'kg',    38.00::numeric,  9,  3, 0.02, 0.35, 0.10, 12, 0),
      ('Ovos caipira',  '🥚', 'duzia', 14.00::numeric, 28,  6, 0.03, 0.00, 0.10, 12, 3),
      ('Mel',           '🍯', 'pote',  30.00::numeric,  7,  2, 0.00, 0.15, 0.35,  7, 0),
      ('Banana prata',  '🍌', 'duzia',  6.00::numeric, 30,  8, 0.08, 0.10, 0.10,  9, 0),
      ('Abacaxi',       '🍍', 'un',     7.00::numeric, 18,  5, 0.06, 0.12, 0.30, 12, 0),
      ('Cupuaçu',       '🧺', 'kg',    12.00::numeric, 10,  3, 0.05, 0.20, 0.45,  3, 2),
      ('Macaxeira',     '🧺', 'kg',     5.00::numeric, 35, 10, 0.03, 0.05, 0.05,  8, 0),
      ('Cheiro-verde',  '🌿', 'maço',   2.50::numeric, 45, 10, 0.15, 0.08, 0.10,  6, 0)
    ) as t(nome, emoji, unidade, preco, semana, minimo, perda, cresce, amp, pico, pend)
  loop
    insert into public.produtos (agricultor_id, nome, emoji, preco, unidade, estoque, estoque_minimo, criado_em)
    values (v_agr, v_prod.nome, v_prod.emoji, v_prod.preco, v_prod.unidade, 0, v_prod.minimo,
            (v_inicio + time '06:00') at time zone 'America/Sao_Paulo')
    returning id into v_id;
    -- O trigger do histórico registrou o cadastro com a hora de agora: leva para o 1º dia
    update public.movimentacoes_estoque
       set criado_em = (v_inicio + time '06:00') at time zone 'America/Sao_Paulo'
     where produto_id = v_id and tipo = 'cadastro';

    v_estoque := 0;
    v_colhido := 0;
    for v_t in 0 .. v_dias - 1 loop
      v_dia := v_inicio + v_t;
      v_semana := v_prod.semana
                * (1 + v_prod.cresce * v_t / 365.0)
                * (1 + v_prod.amp * cos(2 * pi() * (extract(month from v_dia) - v_prod.pico) / 12));

      -- Segunda-feira (e o 1º dia): perdas da semana que passou e colheita
      if extract(isodow from v_dia) = 1 or v_t = 0 then
        v_qtd := least(v_estoque, round(v_colhido * v_prod.perda * (0.5 + random()))::int);
        if v_qtd > 0 then
          v_estoque := v_estoque - v_qtd;
          insert into public.movimentacoes_estoque
                 (produto_id, agricultor_id, produto_nome, unidade, tipo, motivo, quantidade, estoque_apos, criado_em)
          values (v_id, v_agr, v_prod.nome, v_prod.unidade, 'ajuste', 'perda', -v_qtd, v_estoque,
                  (v_dia + time '06:30') at time zone 'America/Sao_Paulo');
        end if;
        v_qtd := greatest(0, ceil(v_semana * (1 + v_prod.perda) * (1.0 + random() * 0.2)) - floor(v_estoque * 0.5))::int;
        if v_qtd > 0 then
          v_estoque := v_estoque + v_qtd;
          insert into public.movimentacoes_estoque
                 (produto_id, agricultor_id, produto_nome, unidade, tipo, motivo, quantidade, estoque_apos, criado_em)
          values (v_id, v_agr, v_prod.nome, v_prod.unidade, 'entrada', 'colheita', v_qtd, v_estoque,
                  (v_dia + time '07:00') at time zone 'America/Sao_Paulo');
        end if;
        v_colhido := v_qtd;
      end if;

      -- Sábado: feira (venda fora do app), cerca de 30% da demanda da semana
      if extract(isodow from v_dia) = 6 then
        v_qtd := least(v_estoque, round(v_semana * 0.30 * (0.7 + random() * 0.6))::int);
        if v_qtd > 0 then
          v_estoque := v_estoque - v_qtd;
          insert into public.movimentacoes_estoque
                 (produto_id, agricultor_id, produto_nome, unidade, tipo, motivo, quantidade, estoque_apos, criado_em)
          values (v_id, v_agr, v_prod.nome, v_prod.unidade, 'ajuste', 'venda_fora', -v_qtd, v_estoque,
                  (v_dia + time '07:30') at time zone 'America/Sao_Paulo');
        end if;
      end if;

      -- Vendas pelo app (cerca de 70% da demanda), em 1 a 3 pedidos; domingo vende menos
      v_qtd := round(v_semana * 0.70 / 7
                     * (case when extract(isodow from v_dia) = 7 then 0.4 else 1.1 end)
                     * (0.5 + random()))::int;
      v_qtd := least(v_qtd, v_estoque);
      if v_qtd > 0 then
        v_k := least(v_qtd, 1 + floor(random() * 3)::int);
        for v_i in 1 .. v_k loop
          v_parte := v_qtd / v_k + case when v_i <= v_qtd % v_k then 1 else 0 end;
          v_hora := (v_dia + time '08:00' + make_interval(mins => (v_i - 1) * 180 + floor(random() * 90)::int))
                    at time zone 'America/Sao_Paulo';
          v_conf := v_hora + interval '1 hour';
          v_status := case when random() < 0.04 then 'cancelado'
                           when v_dia >= v_hoje - 1 then 'confirmado'   -- pedidos de ontem: ainda a entregar
                           else 'entregue' end;
          insert into public.pedidos
                 (produto_id, comprador_id, quantidade, status, criado_em, confirmado_em, entregue_em, cancelado_em,
                  grupo, comprador_nome, entrega_cep, entrega_logradouro, entrega_numero, entrega_cidade, entrega_uf)
          values (v_id, v_comp, v_parte, v_status, v_hora,
                  case when v_status <> 'cancelado' then v_conf end,
                  case when v_status = 'entregue'   then v_conf + interval '1 day' end,
                  case when v_status = 'cancelado'  then v_hora + interval '2 hours' end,
                  gen_random_uuid(), v_cnome, v_ccep, v_clog, 'S/N', v_ccid, v_cuf)
          returning id into v_pedido;
          if v_status <> 'cancelado' then   -- só pedido confirmado baixa o estoque
            v_estoque := v_estoque - v_parte;
            insert into public.movimentacoes_estoque
                   (produto_id, agricultor_id, produto_nome, unidade, tipo, quantidade, estoque_apos, pedido_id, criado_em)
            values (v_id, v_agr, v_prod.nome, v_prod.unidade, 'venda', -v_parte, v_estoque, v_pedido, v_conf);
          end if;
        end loop;
      end if;

      -- Dia 1º: consumo da família (menos o mel)
      if extract(day from v_dia) = 1 and v_prod.unidade <> 'pote' then
        v_qtd := least(v_estoque, greatest(1, round(v_prod.semana * 0.04))::int);
        if v_qtd > 0 then
          v_estoque := v_estoque - v_qtd;
          insert into public.movimentacoes_estoque
                 (produto_id, agricultor_id, produto_nome, unidade, tipo, motivo, quantidade, estoque_apos, criado_em)
          values (v_id, v_agr, v_prod.nome, v_prod.unidade, 'ajuste', 'consumo', -v_qtd, v_estoque,
                  (v_dia + time '20:00') at time zone 'America/Sao_Paulo');
        end if;
      end if;
    end loop;

    -- Estoque final no produto. O trigger registra essa mudança como "entrada"
    -- agora; ela não aconteceu de verdade (o histórico acima já explica o saldo),
    -- então o registro é apagado.
    update public.produtos set estoque = v_estoque where id = v_id;
    delete from public.movimentacoes_estoque
     where produto_id = v_id and criado_em = now() and tipo in ('entrada', 'ajuste') and motivo is null;

    -- Pedido de hoje "a confirmar" (não mexe no estoque até o agricultor confirmar no site)
    if v_prod.pend > 0 and v_estoque >= v_prod.pend then
      insert into public.pedidos
             (produto_id, comprador_id, quantidade, status, criado_em,
              grupo, comprador_nome, entrega_cep, entrega_logradouro, entrega_numero, entrega_cidade, entrega_uf)
      values (v_id, v_comp, v_prod.pend, 'pendente', now() - interval '40 minutes',
              gen_random_uuid(), v_cnome, v_ccep, v_clog, 'S/N', v_ccid, v_cuf);
    end if;
  end loop;
end $$;

commit;

-- ============================================================================
-- CONFERÊNCIA: o que foi gerado para a conta de demonstração
-- ============================================================================
select pr.emoji || ' ' || pr.nome                                   as produto,
       count(pe.id) filter (where pe.status in ('confirmado', 'entregue')) as pedidos_vendidos,
       count(pe.id) filter (where pe.status = 'cancelado')          as cancelados,
       count(pe.id) filter (where pe.status = 'pendente')           as a_confirmar,
       coalesce(sum(pe.quantidade * pe.preco_unitario)
                filter (where pe.status in ('confirmado', 'entregue')), 0) as receita_no_app,
       pr.estoque || ' ' || pr.unidade                              as estoque_atual
  from public.produtos pr
  join public.usuarios u on u.id = pr.agricultor_id and u.nome = 'Sítio Demonstração (dados simulados)'
  left join public.pedidos pe on pe.produto_id = pr.id
 group by pr.id, pr.emoji, pr.nome, pr.estoque, pr.unidade
 order by pr.nome;

-- ============================================================================
-- PARA REMOVER OS DADOS DE DEMONSTRAÇÃO (tire os "--" das 3 linhas e rode):
-- ============================================================================
-- delete from public.pedidos where produto_id in (select pr.id from public.produtos pr join public.usuarios u on u.id = pr.agricultor_id where u.nome = 'Sítio Demonstração (dados simulados)');
-- delete from public.produtos where agricultor_id in (select id from public.usuarios where nome = 'Sítio Demonstração (dados simulados)');
-- delete from public.movimentacoes_estoque where agricultor_id in (select id from public.usuarios where nome = 'Sítio Demonstração (dados simulados)');
