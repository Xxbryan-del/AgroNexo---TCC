-- ============================================================================
-- AGRONEXO — CORREÇÕES DE SEGURANÇA E REGRAS DE NEGÓCIO
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- É tudo uma transação só: se qualquer linha der erro, NADA é aplicado.
-- Pode rodar mais de uma vez sem duplicar nada.
--
-- O que este script corrige:
--   1. Qualquer pessoa podia se cadastrar como administrador
--   2. CNPJ, inscrição estadual e endereço de todos os usuários estavam públicos (LGPD)
--   3. Agricultor podia cadastrar produto em nome de outro agricultor
--   4. Não existia permissão para editar produto nem para confirmar pedido
--   5. A baixa de estoque nunca acontecia (o pedido nasce "pendente") e o estoque podia ficar negativo
--   6. A receita usava o preço ATUAL do produto, não o preço do momento da venda
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0) Função auxiliar: "quem está logado é administrador?"
--    SECURITY DEFINER para ler a tabela usuarios sem cair na própria RLS
--    (sem isso, a policy de usuarios chamaria a si mesma em loop).
-- ----------------------------------------------------------------------------
create or replace function public.eh_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.usuarios where id = auth.uid() and perfil = 'admin');
$$;

-- ----------------------------------------------------------------------------
-- 1) CADASTRO: o perfil nunca vira "admin" pela tela pública
--    O trigger lê os dados enviados no signUp. Antes ele aceitava qualquer perfil
--    vindo do navegador, então bastava mandar perfil = 'admin'.
-- ----------------------------------------------------------------------------
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
    -- Só aceita "comprador"; qualquer outra coisa (inclusive "admin") vira "agricultor".
    -- Administrador é promovido manualmente (ver o fim deste arquivo).
    case when meta->>'perfil' = 'comprador' then 'comprador' else 'agricultor' end,
    meta->>'cnpj',
    meta->>'inscricao_estadual',
    meta->>'cep',
    meta->>'logradouro',
    meta->>'numero',
    meta->>'cidade',
    upper(left(meta->>'uf', 2))
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 2) PREÇO DO MOMENTO DA VENDA no pedido
--    (feito antes dos triggers de pedido, porque o preenchimento abaixo é um UPDATE)
-- ----------------------------------------------------------------------------
alter table public.pedidos add column if not exists preco_unitario numeric(10,2);

update public.pedidos pe
   set preco_unitario = pr.preco
  from public.produtos pr
 where pr.id = pe.produto_id
   and pe.preco_unitario is null;

-- ----------------------------------------------------------------------------
-- 3) REGRAS DE VALOR nos produtos
--    NOT VALID = vale para tudo que for criado ou alterado daqui em diante,
--    sem quebrar o script se já existir algum produto antigo fora da regra.
-- ----------------------------------------------------------------------------
alter table public.produtos drop constraint if exists produtos_preco_positivo;
alter table public.produtos add  constraint produtos_preco_positivo check (preco > 0) not valid;
alter table public.produtos drop constraint if exists produtos_estoque_nao_negativo;
alter table public.produtos add  constraint produtos_estoque_nao_negativo check (estoque >= 0) not valid;
alter table public.produtos drop constraint if exists produtos_minimo_nao_negativo;
alter table public.produtos add  constraint produtos_minimo_nao_negativo check (estoque_minimo >= 0) not valid;
alter table public.produtos drop constraint if exists produtos_nome_tamanho;
alter table public.produtos add  constraint produtos_nome_tamanho check (char_length(trim(nome)) between 1 and 80) not valid;

-- ----------------------------------------------------------------------------
-- 4) PEDIDO NOVO: sempre nasce "pendente" e grava o preço daquele momento
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
  -- Pelo site (usuário logado), o pedido sempre começa pendente:
  -- ninguém consegue criar um pedido já "confirmado" para mexer no estoque.
  if auth.uid() is not null then
    new.status := 'pendente';
    new.criado_em := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_preparar_pedido on public.pedidos;
create trigger trg_preparar_pedido
  before insert on public.pedidos
  for each row execute function public.preparar_pedido();

-- ----------------------------------------------------------------------------
-- 5) MUDANÇA DE STATUS do pedido: quem pode e para onde
--      pendente   → confirmado  (agricultor dono do produto)
--      pendente   → cancelado   (agricultor dono OU o próprio comprador)
--      confirmado → entregue    (agricultor dono)
--      confirmado → cancelado   (agricultor dono; o estoque volta)
--    Fora o status, nada no pedido pode ser alterado depois de criado.
-- ----------------------------------------------------------------------------
create or replace function public.validar_pedido()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_dono uuid;
begin
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

  -- v_uid vazio = comando rodado no SQL Editor (dono do banco): passa sem checar perfil
  if v_uid is not null then
    select agricultor_id into v_dono from public.produtos where id = new.produto_id;
    if v_uid = v_dono then
      null; -- agricultor dono do produto: pode todas as mudanças acima
    elsif v_uid = old.comprador_id and old.status = 'pendente' and new.status = 'cancelado' then
      null; -- comprador só pode desistir enquanto o pedido está pendente
    else
      raise exception 'Você não tem permissão para mudar este pedido.';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_validar_pedido on public.pedidos;
create trigger trg_validar_pedido
  before update on public.pedidos
  for each row execute function public.validar_pedido();

-- ----------------------------------------------------------------------------
-- 6) BAIXA AUTOMÁTICA DE ESTOQUE (RN03) — agora na CONFIRMAÇÃO do pedido
--    Antes o trigger só rodava quando o pedido era CRIADO já confirmado,
--    o que nunca acontece. Mantive o nome baixar_estoque (citado no artigo e nos slides).
--    A checagem "estoque >= quantidade" é feita no mesmo UPDATE, então dois
--    pedidos confirmados ao mesmo tempo não conseguem deixar o estoque negativo.
-- ----------------------------------------------------------------------------
create or replace function public.baixar_estoque()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.status = 'pendente' and new.status = 'confirmado' then
    update public.produtos
       set estoque = estoque - new.quantidade
     where id = new.produto_id
       and estoque >= new.quantidade;
    if not found then
      raise exception 'Estoque insuficiente para confirmar este pedido.';
    end if;
  elsif old.status = 'confirmado' and new.status = 'cancelado' then
    update public.produtos
       set estoque = estoque + new.quantidade
     where id = new.produto_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_baixa_estoque on public.pedidos;
create trigger trg_baixa_estoque
  after update of status on public.pedidos
  for each row
  when (old.status is distinct from new.status)
  execute function public.baixar_estoque();

-- ----------------------------------------------------------------------------
-- 7) RLS — apaga TODAS as policies antigas destas 3 tabelas e recria do zero.
--    No Postgres as policies se somam (OU): uma policy antiga "using (true)"
--    esquecida anularia todas as outras.
-- ----------------------------------------------------------------------------
alter table public.usuarios enable row level security;
alter table public.produtos enable row level security;
alter table public.pedidos  enable row level security;

do $$
declare p record;
begin
  for p in select policyname, tablename from pg_policies
            where schemaname = 'public' and tablename in ('usuarios', 'produtos', 'pedidos')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- USUARIOS: cada um lê só o próprio cadastro; o admin lê todos.
-- Ninguém insere pelo site (o trigger handle_new_user cria o perfil) e ninguém
-- altera o próprio perfil (assim ninguém se promove a admin).
create policy "usuario_le_proprio_ou_admin" on public.usuarios
  for select to authenticated
  using (id = auth.uid() or public.eh_admin());

-- PRODUTOS: catálogo visível para quem está logado; cada agricultor mexe só nos seus.
create policy "produtos_leitura_logados" on public.produtos
  for select to authenticated
  using (true);

create policy "agricultor_insere_proprios" on public.produtos
  for insert to authenticated
  with check (
    agricultor_id = auth.uid()
    and exists (select 1 from public.usuarios u where u.id = auth.uid() and u.perfil = 'agricultor')
  );

create policy "agricultor_edita_proprios" on public.produtos
  for update to authenticated
  using (agricultor_id = auth.uid())
  with check (agricultor_id = auth.uid());

create policy "agricultor_apaga_proprios" on public.produtos
  for delete to authenticated
  using (agricultor_id = auth.uid());

-- PEDIDOS: só comprador cria; comprador e agricultor do produto veem e mudam o status
-- (o trigger validar_pedido decide quais mudanças cada um pode fazer); admin vê todos.
create policy "comprador_cria_pedido" on public.pedidos
  for insert to authenticated
  with check (
    comprador_id = auth.uid()
    and exists (select 1 from public.usuarios u where u.id = auth.uid() and u.perfil = 'comprador')
  );

create policy "partes_leem_pedido" on public.pedidos
  for select to authenticated
  using (
    comprador_id = auth.uid()
    or exists (select 1 from public.produtos p where p.id = produto_id and p.agricultor_id = auth.uid())
    or public.eh_admin()
  );

create policy "partes_atualizam_pedido" on public.pedidos
  for update to authenticated
  using (
    comprador_id = auth.uid()
    or exists (select 1 from public.produtos p where p.id = produto_id and p.agricultor_id = auth.uid())
  )
  with check (
    comprador_id = auth.uid()
    or exists (select 1 from public.produtos p where p.id = produto_id and p.agricultor_id = auth.uid())
  );

-- ----------------------------------------------------------------------------
-- 8) VITRINE DE PRODUTORES (para o marketplace do Bloco 5)
--    O comprador precisa ver o nome e a cidade de quem vende, mas não o CNPJ
--    nem o endereço. Esta função entrega só esses campos.
--    No site: const { data } = await db.rpc('produtores_publicos');
-- ----------------------------------------------------------------------------
create or replace function public.produtores_publicos()
returns table (id uuid, nome text, cidade text, uf text)
language sql stable security definer set search_path = public
as $$
  select u.id, u.nome, u.cidade, u.uf
    from public.usuarios u
   where u.perfil = 'agricultor';
$$;
revoke all on function public.produtores_publicos() from public, anon;
grant execute on function public.produtores_publicos() to authenticated;

commit;

-- ============================================================================
-- CONFERÊNCIA — o resultado aparece embaixo do editor depois do Run.
--   • "policy": as 9 regras novas (nenhuma antiga deve sobrar)
--   • "ADMIN — confira": todas as contas admin que existem HOJE. Qualquer uma
--     que você não reconheça foi criada pela falha antiga.
--   • "produto fora da regra": produtos antigos com preço/estoque inválido
-- ============================================================================
select 'policy' as tipo, tablename || ' · ' || policyname as item
  from pg_policies
 where schemaname = 'public' and tablename in ('usuarios', 'produtos', 'pedidos')
union all
select 'ADMIN — confira', a.email || ' (' || u.nome || ')'
  from public.usuarios u join auth.users a on a.id = u.id
 where u.perfil = 'admin'
union all
select 'produto fora da regra', p.id || ' · ' || p.nome || ' · preço ' || p.preco || ' · estoque ' || p.estoque
  from public.produtos p
 where p.preco <= 0 or p.estoque < 0 or p.estoque_minimo < 0
order by 1, 2;

-- ============================================================================
-- COMANDOS AVULSOS (rode só quando precisar, trocando o email)
-- ============================================================================
-- Criar o administrador do jeito certo:
--   1) Authentication → Users → Add user → Create new user (marque "Auto Confirm User")
--   2) Rode:
-- update public.usuarios set perfil = 'admin', nome = 'Administrador'
--  where id = (select id from auth.users where email = 'EMAIL_DO_ADMIN');
--
-- Rebaixar um admin que não deveria existir:
-- update public.usuarios set perfil = 'comprador'
--  where id = (select id from auth.users where email = 'EMAIL_SUSPEITO');
