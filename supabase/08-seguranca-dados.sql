-- ============================================================================
-- AGRONEXO — SEGURANÇA E PROTEÇÃO DE DADOS PESSOAIS (LGPD)
-- Pré-requisito: scripts 01 a 06 já aplicados (o 07 é opcional).
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- É uma transação só: se qualquer linha der erro, NADA é aplicado.
-- Pode rodar mais de uma vez.
--
-- O que muda:
--   1. Localização: a distância até o produtor passa a ser APROXIMADA (km
--      inteiro, a partir de uma grade de ~1 km). Antes, mudando a própria
--      localização 3 vezes e lendo as distâncias com 100 m de precisão, dava
--      para descobrir onde fica a casa/propriedade do agricultor (triangulação).
--      As coordenadas guardadas também ficam menos precisas (~11 m).
--   2. Limites de tamanho nos textos (endereço, nome, emoji...) e de valor
--      (preço, estoque): ninguém grava 1 MB num campo de endereço.
--   3. Limite de pedidos por comprador (evita enxurrada de pedidos falsos).
--   4. Funções internas fechadas para quem não fez login.
--   5. Registro de auditoria: quem mudou o status de um pedido, o preço de um
--      produto ou a localização, e quando. Só o administrador lê; ninguém apaga.
--   6. Endereço de entrega apagado 90 dias depois da entrega ou cancelamento
--      (fica só cidade/UF para as estatísticas). LGPD: dado pessoal guardado
--      só pelo tempo necessário.
--      ATENÇÃO: ao rodar este script, os endereços de entregas com mais de
--      90 dias JÁ são apagados (a conferência no fim mostra quantos).
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'pedidos'
                    and column_name = 'grupo') then
    raise exception 'Rode primeiro os arquivos 01 a 06.';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1) LOCALIZAÇÃO: distância aproximada e coordenadas menos precisas
-- ----------------------------------------------------------------------------
-- 4 casas decimais ≈ 11 metros: suficiente para a rota, sem apontar a porta da casa
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
     set latitude  = round(p_lat::numeric, 4),
         longitude = round(p_lng::numeric, 4)
   where id = auth.uid();
end $$;
revoke all on function public.definir_minha_localizacao(double precision, double precision) from public, anon;
grant execute on function public.definir_minha_localizacao(double precision, double precision) to authenticated;

-- Coordenadas que já estavam guardadas com mais precisão
update public.usuarios
   set latitude = round(latitude::numeric, 4), longitude = round(longitude::numeric, 4)
 where latitude is not null
   and (latitude <> round(latitude::numeric, 4) or longitude <> round(longitude::numeric, 4));

-- O produtor é posto no centro de uma grade de ~1 km (2 casas decimais) e a
-- distância sai em km inteiro: a triangulação acha no máximo o "quarteirão grande".
create or replace function public.produtores_publicos()
returns table (id uuid, nome text, cidade text, uf text, distancia_km numeric)
language sql stable security definer set search_path = public
as $$
  with eu as (
    select latitude, longitude from public.usuarios where id = auth.uid()
  )
  select u.id, u.nome, u.cidade, u.uf,
         case when eu.latitude is null or u.latitude is null then null
              else greatest(1, round(d.km))::numeric
         end
    from public.usuarios u
    left join eu on true
    left join lateral (
      select 6371 * 2 * asin(least(1, sqrt(
               power(sin(radians(g.lat - eu.latitude) / 2), 2)
               + cos(radians(eu.latitude)) * cos(radians(g.lat))
               * power(sin(radians(g.lng - eu.longitude) / 2), 2)))) as km
        from (select round(u.latitude::numeric, 2)::double precision  as lat,
                     round(u.longitude::numeric, 2)::double precision as lng) g
    ) d on true
   where u.perfil = 'agricultor';
$$;
revoke all on function public.produtores_publicos() from public, anon;
grant execute on function public.produtores_publicos() to authenticated;

-- ----------------------------------------------------------------------------
-- 2) LIMITES DE TAMANHO E DE VALOR
--    NOT VALID = vale para o que for criado ou alterado daqui em diante.
-- ----------------------------------------------------------------------------
alter table public.pedidos drop constraint if exists pedidos_tamanhos;
alter table public.pedidos add constraint pedidos_tamanhos check (
      coalesce(char_length(entrega_cep), 0)        <= 9
  and coalesce(char_length(entrega_logradouro), 0) <= 150
  and coalesce(char_length(entrega_numero), 0)     <= 20
  and coalesce(char_length(entrega_cidade), 0)     <= 80
  and coalesce(char_length(entrega_uf), 0)         <= 2
  and coalesce(char_length(comprador_nome), 0)     <= 120
  and quantidade <= 100000
  and (entrega_lat is null or entrega_lat between -90 and 90)
  and (entrega_lng is null or entrega_lng between -180 and 180)
) not valid;

alter table public.produtos drop constraint if exists produtos_limites;
alter table public.produtos add constraint produtos_limites check (
      coalesce(char_length(emoji), 0)   <= 16
  and coalesce(char_length(unidade), 0) <= 20
  and preco <= 100000
  and estoque <= 10000000
  and coalesce(estoque_minimo, 0) <= 10000000
) not valid;

-- Cadastro: o perfil é criado a partir do que veio do navegador; aqui cada
-- campo é cortado no tamanho máximo (mesma regra de perfil do script 01).
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.usuarios (id, nome, perfil, cnpj, inscricao_estadual,
                               cep, logradouro, numero, cidade, uf)
  values (
    new.id,
    left(coalesce(nullif(trim(meta->>'nome'), ''), 'Sem nome'), 120),
    case when meta->>'perfil' = 'comprador' then 'comprador' else 'agricultor' end,
    left(meta->>'cnpj', 18),
    left(meta->>'inscricao_estadual', 20),
    left(meta->>'cep', 9),
    left(meta->>'logradouro', 150),
    left(meta->>'numero', 20),
    left(meta->>'cidade', 80),
    upper(left(meta->>'uf', 2))
  );
  return new;
end $$;

-- ----------------------------------------------------------------------------
-- 3) PEDIDO NOVO: mesmas regras do script 04 + limite por comprador
--    + coordenada da entrega com 4 casas (~11 m)
-- ----------------------------------------------------------------------------
create index if not exists pedidos_comprador_data on public.pedidos (comprador_id, criado_em desc);

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
  new.entrega_lat := round(new.entrega_lat::numeric, 4);
  new.entrega_lng := round(new.entrega_lng::numeric, 4);

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
    -- Limites contra enxurrada de pedidos (cada produto do carrinho conta 1)
    if (select count(*) from public.pedidos
         where comprador_id = auth.uid() and criado_em > now() - interval '1 hour') >= 60 then
      raise exception 'Muitos pedidos em pouco tempo. Aguarde alguns minutos e tente de novo.';
    end if;
    if (select count(*) from public.pedidos
         where comprador_id = auth.uid() and status = 'pendente') >= 40 then
      raise exception 'Você já tem muitos pedidos aguardando os produtores. Aguarde as confirmações antes de pedir mais.';
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
-- 4) FUNÇÕES INTERNAS: só para quem fez login
--    (sem login, o RLS já barrava; aqui a porta nem abre)
-- ----------------------------------------------------------------------------
revoke execute on function public.ajustar_estoque(bigint, text, int, text) from public, anon;
grant  execute on function public.ajustar_estoque(bigint, text, int, text) to authenticated;
revoke execute on function public.eh_admin() from public, anon;
grant  execute on function public.eh_admin() to authenticated;

-- ----------------------------------------------------------------------------
-- 5) AUDITORIA: quem fez o quê, e quando
--    Só os triggers escrevem (não há policy de INSERT/UPDATE/DELETE);
--    só o administrador lê. Sem dado pessoal desnecessário: a localização
--    nova NÃO é copiada para cá, só o fato de ter mudado.
-- ----------------------------------------------------------------------------
create table if not exists public.auditoria (
  id          bigint generated always as identity primary key,
  tabela      text   not null,
  registro_id text   not null,
  acao        text   not null,
  detalhes    jsonb,
  autor_id    uuid   default auth.uid(),   -- vazio = comando do SQL Editor ou rotina automática
  criado_em   timestamptz not null default now()
);
create index if not exists auditoria_registro on public.auditoria (tabela, registro_id);
create index if not exists auditoria_data on public.auditoria (criado_em desc);

alter table public.auditoria enable row level security;
drop policy if exists "auditoria_so_admin" on public.auditoria;
create policy "auditoria_so_admin" on public.auditoria
  for select to authenticated
  using (public.eh_admin());
revoke all on public.auditoria from anon;

create or replace function public.registrar_auditoria()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_table_name = 'pedidos' then
    if tg_op = 'INSERT' then
      insert into public.auditoria (tabela, registro_id, acao, detalhes)
      values ('pedidos', new.id::text, 'criado',
              jsonb_build_object('produto_id', new.produto_id, 'quantidade', new.quantidade));
    elsif new.status is distinct from old.status then
      insert into public.auditoria (tabela, registro_id, acao, detalhes)
      values ('pedidos', new.id::text, 'status', jsonb_build_object('de', old.status, 'para', new.status));
    end if;
    -- (endereços apagados pela rotina viram UM registro-resumo, feito pela própria rotina)
  elsif tg_table_name = 'produtos' then
    if new.preco is distinct from old.preco then
      insert into public.auditoria (tabela, registro_id, acao, detalhes)
      values ('produtos', new.id::text, 'preco', jsonb_build_object('de', old.preco, 'para', new.preco));
    end if;
  elsif tg_table_name = 'usuarios' then
    if new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude then
      insert into public.auditoria (tabela, registro_id, acao)
      values ('usuarios', new.id::text, 'localizacao_alterada');
    end if;
  end if;
  return null;   -- trigger AFTER: o valor de retorno é ignorado
end $$;

drop trigger if exists trg_auditoria_pedidos on public.pedidos;
create trigger trg_auditoria_pedidos
  after insert or update on public.pedidos
  for each row execute function public.registrar_auditoria();
drop trigger if exists trg_auditoria_produtos on public.produtos;
create trigger trg_auditoria_produtos
  after update of preco on public.produtos
  for each row execute function public.registrar_auditoria();
drop trigger if exists trg_auditoria_usuarios on public.usuarios;
create trigger trg_auditoria_usuarios
  after update of latitude, longitude on public.usuarios
  for each row execute function public.registrar_auditoria();

-- ----------------------------------------------------------------------------
-- 6) ENDEREÇO DE ENTREGA SÓ PELO TEMPO NECESSÁRIO
--    90 dias depois da entrega ou do cancelamento, rua, número, CEP, coordenadas
--    e observação são apagados. Ficam: cidade/UF, produto, quantidade, valor e
--    datas (registro da venda, que o agricultor precisa guardar).
-- ----------------------------------------------------------------------------
create or replace function public.anonimizar_entregas_antigas(p_dias int default 90)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_qtd int;
begin
  update public.pedidos
     set entrega_cep = null, entrega_logradouro = null, entrega_numero = null,
         entrega_lat = null, entrega_lng = null, observacao = null
   where status in ('entregue', 'cancelado')
     and coalesce(entregue_em, cancelado_em) < now() - make_interval(days => greatest(30, coalesce(p_dias, 90)))
     and (entrega_cep is not null or entrega_logradouro is not null or entrega_numero is not null
          or entrega_lat is not null or entrega_lng is not null or observacao is not null);
  get diagnostics v_qtd = row_count;
  if v_qtd > 0 then
    insert into public.auditoria (tabela, registro_id, acao, detalhes)
    values ('pedidos', 'varios', 'enderecos_apagados',
            jsonb_build_object('quantidade', v_qtd, 'depois_de_dias', greatest(30, coalesce(p_dias, 90))));
  end if;
  return v_qtd;
end $$;
-- Ninguém chama pelo site: só o SQL Editor e a rotina automática abaixo
revoke all on function public.anonimizar_entregas_antigas(int) from public, anon, authenticated;

-- Rotina diária (00h15 de Brasília), se a extensão pg_cron estiver ligada.
-- Para ligar: Supabase → Database → Extensions → pg_cron → Enable; depois rode
-- este script de novo. Sem ela, rode à mão de vez em quando:
--   select public.anonimizar_entregas_antigas(90);
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'agronexo-apagar-enderecos-antigos';
    perform cron.schedule('agronexo-apagar-enderecos-antigos', '15 3 * * *',
                          'select public.anonimizar_entregas_antigas(90)');
  end if;
end $$;

commit;

-- ============================================================================
-- CONFERÊNCIA
-- ============================================================================
select 'endereços apagados agora (entregas com mais de 90 dias)' as item,
       public.anonimizar_entregas_antigas(90)::text as valor
union all
select 'rotina diária agendada (pg_cron)',
       case when exists (select 1 from pg_extension where extname = 'pg_cron')
            then 'sim' else 'não: ligue o pg_cron e rode o script de novo' end
union all
select 'tabelas vigiadas pela auditoria (pedidos, produtos, usuarios)',
       count(distinct event_object_table)::text
  from information_schema.triggers
 where trigger_schema = 'public' and trigger_name like 'trg_auditoria_%';
