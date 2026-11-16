-- ============================================================================
-- AGRONEXO — CATÁLOGO DE PRODUTOS (frutas, legumes, verduras, raízes, temperos)
-- Pré-requisito: scripts 01 e 02 já aplicados (de preferência, 01 a 08).
-- Como usar: Supabase → SQL Editor → New query → cole o arquivo inteiro → Run.
-- É uma transação só. Pode rodar mais de uma vez (atualiza o catálogo).
--
-- O que muda:
--   1. Tabela "catalogo": quase 100 itens de referência, com categoria, emoji,
--      unidade mais comum e nomes regionais (macaxeira = mandioca = aipim).
--      Inclui os produtos da Amazônia (açaí, cupuaçu, tucumã, pupunha, jambu...).
--   2. Cada produto ganha categoria e o vínculo com o item do catálogo.
--   3. Produto novo é ligado ao catálogo sozinho pelo nome: "Tomate italiano"
--      vira Tomate (legumes); "Mandioca" vira Macaxeira (raízes).
--      Produto fora do catálogo continua permitido (categoria "outros" ou a
--      escolhida pelo agricultor).
--   4. Produtos que já existem são ligados ao catálogo agora.
--   Todo mundo que fez login lê o catálogo; só o administrador altera.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'eh_admin')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'produtos' and column_name = 'ativo') then
    raise exception 'Rode primeiro os arquivos 01 e 02 (de preferência, 01 a 08).';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1) Nome comparável: sem acento, minúsculo, hífen vira espaço
--    ("Cheiro-Verde" = "cheiro verde"; "Açaí" = "acai")
-- ----------------------------------------------------------------------------
create or replace function public.normalizar_nome(p text)
returns text
language sql immutable
as $$
  select trim(regexp_replace(regexp_replace(lower(translate(coalesce(p, ''),
           'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
           'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc')), '[-_]+', ' ', 'g'), '\s+', ' ', 'g'));
$$;

-- ----------------------------------------------------------------------------
-- 2) CATÁLOGO
-- ----------------------------------------------------------------------------
create table if not exists public.catalogo (
  id         bigint generated always as identity primary key,
  nome       text not null unique,
  categoria  text not null check (categoria in ('frutas', 'legumes', 'verduras', 'raizes', 'temperos', 'outros')),
  emoji      text not null default '🧺',
  unidade    text not null default 'kg',
  sinonimos  text[] not null default '{}'   -- nomes regionais e variações
);

alter table public.catalogo enable row level security;
drop policy if exists "catalogo_leitura" on public.catalogo;
create policy "catalogo_leitura" on public.catalogo
  for select to authenticated using (true);
drop policy if exists "catalogo_so_admin_altera" on public.catalogo;
create policy "catalogo_so_admin_altera" on public.catalogo
  for all to authenticated using (public.eh_admin()) with check (public.eh_admin());
revoke all on public.catalogo from anon;

-- Unidade = a mais comum na feira. 🧺 = fruta ou legume sem emoji próprio.
-- "Chicória" segue o uso amazônico (coentro-de-pasto, tempero), não a verdura do Sudeste.
insert into public.catalogo (nome, categoria, emoji, unidade, sinonimos) values
  -- Frutas
  ('Abacate',            'frutas',   '🥑', 'kg',    '{}'),
  ('Abacaxi',            'frutas',   '🍍', 'un',    array['ananás']),
  ('Açaí (polpa)',       'frutas',   '🫐', 'litro', array['açaí', 'vinho de açaí']),
  ('Acerola',            'frutas',   '🍒', 'kg',    '{}'),
  ('Araçá-boi',          'frutas',   '🧺', 'kg',    '{}'),
  ('Bacaba',             'frutas',   '🧺', 'kg',    '{}'),
  ('Banana nanica',      'frutas',   '🍌', 'duzia', array['banana-d''água', 'banana caturra']),
  ('Banana pacovã',      'frutas',   '🍌', 'kg',    array['pacovã', 'banana-da-terra']),
  ('Banana prata',       'frutas',   '🍌', 'duzia', array['banana']),
  ('Biribá',             'frutas',   '🧺', 'un',    '{}'),
  ('Buriti',             'frutas',   '🧺', 'kg',    array['miriti']),
  ('Cacau',              'frutas',   '🧺', 'kg',    '{}'),
  ('Caju',               'frutas',   '🧺', 'kg',    '{}'),
  ('Camu-camu',          'frutas',   '🧺', 'kg',    '{}'),
  ('Carambola',          'frutas',   '🧺', 'kg',    '{}'),
  ('Coco verde',         'frutas',   '🥥', 'un',    array['coco']),
  ('Cubiu',              'frutas',   '🧺', 'kg',    array['tomate-de-índio']),
  ('Cupuaçu',            'frutas',   '🧺', 'kg',    '{}'),
  ('Goiaba',             'frutas',   '🧺', 'kg',    '{}'),
  ('Graviola',           'frutas',   '🧺', 'kg',    '{}'),
  ('Ingá',               'frutas',   '🧺', 'kg',    '{}'),
  ('Jabuticaba',         'frutas',   '🧺', 'kg',    '{}'),
  ('Jaca',               'frutas',   '🧺', 'kg',    '{}'),
  ('Jambo',              'frutas',   '🧺', 'kg',    '{}'),
  ('Laranja',            'frutas',   '🍊', 'kg',    '{}'),
  ('Limão',              'frutas',   '🍋', 'kg',    '{}'),
  ('Maçã',               'frutas',   '🍎', 'kg',    '{}'),
  ('Mamão',              'frutas',   '🧺', 'kg',    array['papaia']),
  ('Manga',              'frutas',   '🥭', 'kg',    '{}'),
  ('Maracujá',           'frutas',   '🧺', 'kg',    '{}'),
  ('Melancia',           'frutas',   '🍉', 'un',    '{}'),
  ('Melão',              'frutas',   '🍈', 'un',    '{}'),
  ('Morango',            'frutas',   '🍓', 'caixa', '{}'),
  ('Pupunha',            'frutas',   '🧺', 'kg',    '{}'),
  ('Taperebá',           'frutas',   '🧺', 'kg',    array['cajá']),
  ('Tangerina',          'frutas',   '🍊', 'kg',    array['mexerica', 'bergamota', 'ponkan']),
  ('Tucumã',             'frutas',   '🧺', 'kg',    '{}'),
  ('Uva',                'frutas',   '🍇', 'kg',    '{}'),
  -- Legumes
  ('Abóbora',            'legumes',  '🎃', 'kg',    array['jerimum', 'moranga']),
  ('Abobrinha',          'legumes',  '🥒', 'kg',    '{}'),
  ('Berinjela',          'legumes',  '🍆', 'kg',    '{}'),
  ('Chuchu',             'legumes',  '🧺', 'kg',    '{}'),
  ('Feijão-de-metro',    'legumes',  '🧺', 'maço',  array['feijão-de-corda verde']),
  ('Jiló',               'legumes',  '🧺', 'kg',    '{}'),
  ('Maxixe',             'legumes',  '🧺', 'kg',    '{}'),
  ('Milho verde',        'legumes',  '🌽', 'un',    array['milho', 'espiga de milho']),
  ('Pepino',             'legumes',  '🥒', 'kg',    '{}'),
  ('Pimentão',           'legumes',  '🫑', 'kg',    '{}'),
  ('Quiabo',             'legumes',  '🧺', 'kg',    '{}'),
  ('Tomate',             'legumes',  '🍅', 'kg',    '{}'),
  ('Tomate cereja',      'legumes',  '🍅', 'caixa', '{}'),
  ('Vagem',              'legumes',  '🧺', 'kg',    '{}'),
  -- Verduras
  ('Acelga',             'verduras', '🥬', 'maço',  '{}'),
  ('Agrião',             'verduras', '🥬', 'maço',  '{}'),
  ('Alface americana',   'verduras', '🥬', 'un',    '{}'),
  ('Alface crespa',      'verduras', '🥬', 'un',    array['alface']),
  ('Brócolis',           'verduras', '🥦', 'un',    '{}'),
  ('Cariru',             'verduras', '🥬', 'maço',  '{}'),
  ('Couve',              'verduras', '🥬', 'maço',  array['couve-manteiga']),
  ('Couve-flor',         'verduras', '🥦', 'un',    '{}'),
  ('Espinafre',          'verduras', '🥬', 'maço',  '{}'),
  ('Jambu',              'verduras', '🥬', 'maço',  '{}'),
  ('Mostarda',           'verduras', '🥬', 'maço',  array['folha de mostarda']),
  ('Repolho',            'verduras', '🥬', 'un',    '{}'),
  ('Rúcula',             'verduras', '🥬', 'maço',  '{}'),
  ('Taioba',             'verduras', '🥬', 'maço',  '{}'),
  -- Raízes, tubérculos e bulbos
  ('Alho',               'raizes',   '🧄', 'kg',    '{}'),
  ('Batata',             'raizes',   '🥔', 'kg',    array['batata-inglesa']),
  ('Batata-doce',        'raizes',   '🍠', 'kg',    '{}'),
  ('Beterraba',          'raizes',   '🧺', 'kg',    '{}'),
  ('Cará',               'raizes',   '🧺', 'kg',    '{}'),
  ('Cebola',             'raizes',   '🧅', 'kg',    '{}'),
  ('Cenoura',            'raizes',   '🥕', 'kg',    '{}'),
  ('Gengibre',           'raizes',   '🧺', 'kg',    '{}'),
  ('Inhame',             'raizes',   '🧺', 'kg',    '{}'),
  ('Macaxeira',          'raizes',   '🧺', 'kg',    array['mandioca', 'aipim']),
  ('Rabanete',           'raizes',   '🧺', 'maço',  '{}'),
  -- Temperos e ervas
  ('Alfavaca',           'temperos', '🌿', 'maço',  '{}'),
  ('Cebolinha',          'temperos', '🌿', 'maço',  '{}'),
  ('Cheiro-verde',       'temperos', '🌿', 'maço',  array['salsa e cebolinha']),
  ('Chicória',           'temperos', '🌿', 'maço',  array['coentro-de-pasto', 'coentrão']),
  ('Coentro',            'temperos', '🌿', 'maço',  '{}'),
  ('Hortelã',            'temperos', '🌿', 'maço',  '{}'),
  ('Manjericão',         'temperos', '🌿', 'maço',  '{}'),
  ('Pimenta-de-cheiro',  'temperos', '🌶️', 'kg',    '{}'),
  ('Pimenta malagueta',  'temperos', '🌶️', 'kg',    array['malagueta']),
  ('Salsa',              'temperos', '🌿', 'maço',  array['salsinha']),
  ('Urucum',             'temperos', '🧺', 'kg',    array['colorau']),
  -- Outros produtos da agricultura familiar
  ('Amendoim',           'outros',   '🥜', 'kg',    '{}'),
  ('Castanha-do-brasil', 'outros',   '🌰', 'kg',    array['castanha-do-pará', 'castanha']),
  ('Cogumelo',           'outros',   '🍄', 'caixa', '{}'),
  ('Farinha de mandioca','outros',   '🧺', 'kg',    array['farinha d''água', 'farinha']),
  ('Feijão',             'outros',   '🫘', 'kg',    '{}'),
  ('Mel',                'outros',   '🍯', 'pote',  '{}'),
  ('Ovos caipira',       'outros',   '🥚', 'duzia', array['ovos', 'ovo caipira']),
  ('Queijo coalho',      'outros',   '🧀', 'kg',    '{}'),
  ('Queijo minas',       'outros',   '🧀', 'kg',    array['queijo'])
on conflict (nome) do update
   set categoria = excluded.categoria, emoji = excluded.emoji,
       unidade = excluded.unidade, sinonimos = excluded.sinonimos;

-- ----------------------------------------------------------------------------
-- 3) PRODUTO: categoria e vínculo com o catálogo
-- ----------------------------------------------------------------------------
alter table public.produtos
  add column if not exists categoria   text not null default 'outros',
  add column if not exists catalogo_id bigint references public.catalogo(id) on delete set null;
alter table public.produtos drop constraint if exists produtos_categoria_valida;
alter table public.produtos add constraint produtos_categoria_valida
  check (categoria in ('frutas', 'legumes', 'verduras', 'raizes', 'temperos', 'outros'));
create index if not exists produtos_categoria on public.produtos (categoria);

-- Acha o item do catálogo pelo nome do produto: nome ou nome regional igual
-- ("Mandioca" → Macaxeira) ou nome que começa com ele ("Tomate italiano" → Tomate).
-- Empate: vence o nome mais longo ("Tomate cereja orgânico" → Tomate cereja).
create or replace function public.item_do_catalogo(p_nome text)
returns bigint
language sql stable set search_path = public
as $$
  select c.id
    from public.catalogo c
    cross join lateral (select public.normalizar_nome(p_nome) as v) n
    cross join lateral (
      select max(case when n.v = t.k then 1000 + char_length(t.k)
                      when n.v like t.k || ' %' then char_length(t.k) end) as nota
        from (select public.normalizar_nome(c.nome) as k
              union all
              select public.normalizar_nome(s) from unnest(c.sinonimos) s) t
    ) m
   where m.nota is not null
   order by m.nota desc
   limit 1;
$$;

create or replace function public.vincular_catalogo()
returns trigger
language plpgsql set search_path = public
as $$
declare
  v_cat text;
begin
  if new.catalogo_id is null then
    new.catalogo_id := public.item_do_catalogo(new.nome);
  end if;
  -- Categoria vem do catálogo quando a pessoa não escolheu outra
  if new.catalogo_id is not null and coalesce(new.categoria, 'outros') = 'outros' then
    select categoria into v_cat from public.catalogo where id = new.catalogo_id;
    new.categoria := coalesce(v_cat, 'outros');
  end if;
  new.categoria := coalesce(new.categoria, 'outros');
  return new;
end $$;

drop trigger if exists trg_vincular_catalogo on public.produtos;
create trigger trg_vincular_catalogo
  before insert or update of nome, catalogo_id on public.produtos
  for each row execute function public.vincular_catalogo();

revoke all on function public.normalizar_nome(text) from public, anon;
grant execute on function public.normalizar_nome(text) to authenticated;
revoke all on function public.item_do_catalogo(text) from public, anon;
grant execute on function public.item_do_catalogo(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4) Produtos que já existem: ligados ao catálogo agora
-- ----------------------------------------------------------------------------
update public.produtos p
   set catalogo_id = public.item_do_catalogo(p.nome)
 where p.catalogo_id is null
   and public.item_do_catalogo(p.nome) is not null;

commit;

-- ============================================================================
-- CONFERÊNCIA: itens do catálogo e produtos à venda em cada categoria
-- ============================================================================
select c.categoria,
       count(*)::text as itens_no_catalogo,
       (select count(*) from public.produtos p where p.categoria = c.categoria)::text as produtos_cadastrados
  from public.catalogo c
 group by c.categoria
 order by c.categoria;
