# AgroNexo

Sistema web de gestão e comercialização para a **agricultura familiar**, alinhado ao
ODS 08 (Trabalho Decente e Crescimento Econômico). Projeto de TCC — CEUNI FAMETRO.

**Acesse:** https://xxbryan-del.github.io/AgroNexo---TCC/

## Tecnologias

- HTML5, CSS3 e JavaScript puro, em um único arquivo (`index.html`)
- [Supabase](https://supabase.com): PostgreSQL, autenticação, tempo real e Row Level Security
- Chart.js (gráficos do Dashboard e dos Relatórios) e API ViaCEP (endereço automático no cadastro)
- Leaflet + OpenStreetMap (mapa da rota de entregas) e qrcode-generator (QR de rastreio)
- Acessibilidade WCAG 2.1: alto contraste, tamanho de fonte e leitura em voz alta

## Telas

| Tela | Situação |
|---|---|
| Login e cadastro em 4 etapas | pronta |
| Dashboard (vendas, previsão de estoque, atividade) | pronta |
| Meus Produtos (editar, arquivar, excluir) | pronta |
| Estoque (entradas, saídas e perdas com motivo, CSV) | pronta |
| Marketplace (vitrine por categoria, carrinho, entrega e distância) e Meus Pedidos do comprador | pronta |
| Catálogo de produtos: 97 frutas, legumes, verduras, raízes, temperos e outros, com nomes regionais da Amazônia | pronto |
| Pedidos do agricultor: confirmar/entregar, rota de entregas (mapa + Google Maps) e QR code de rastreio | pronta |
| Página pública de rastreabilidade (`?rastreio=<código>`, sem login) | pronta |
| Relatórios: previsão de vendas, plano de colheita, faturamento, curva ABC, perdas; admin: renda gerada (ODS 08) | pronta |
| Modo offline | em construção |

## Previsão de vendas (tela Relatórios)

Calculada no navegador, sem biblioteca extra. A demanda de cada semana soma as vendas
no app e as vendas fora dele (feira, balcão) registradas na tela Estoque. O método
depende de quanto histórico existe:

| Histórico | Método |
|---|---|
| menos de 4 semanas | não prevê |
| 4 a 11 semanas | média móvel ponderada |
| 12 a 51 semanas | regressão linear (tendência) |
| 52 semanas ou mais | regressão linear + índice sazonal por mês do ano |

A faixa provável (80%) vem do erro do modelo. O sistema também esconde as últimas
4 semanas, prevê essas semanas e mostra quanto errou (confiança boa, média ou baixa).

## Banco de dados

Os scripts ficam em `supabase/` e são executados no **SQL Editor** do Supabase,
nesta ordem (cada um pode ser rodado mais de uma vez):

1. `01-seguranca.sql` — permissões (RLS), regras de pedido e baixa de estoque
2. `02-historico-dashboard.sql` — histórico de estoque e vendas por dia
3. `03-estoque.sql` — movimentações de estoque com motivo
4. `04-marketplace.sql` — pedido com entrega, localização e código de rastreio
5. `05-rastreabilidade.sql` — ficha pública do produto aberta pelo QR code
6. `06-relatorios.sql` — renda gerada na plataforma (relatório do administrador)
7. `07-dados-demonstracao.sql` — **opcional**: 60 semanas de vendas simuladas de 10
   produtos numa conta de demonstração, para apresentar a previsão (as contas ficam
   com "(dados simulados)" no nome)
8. `08-seguranca-dados.sql` — distância aproximada, limites, auditoria e endereço de
   entrega apagado após 90 dias (LGPD)
9. `09-catalogo.sql` — catálogo de referência (frutas, legumes, verduras, raízes,
   temperos e outros) e categoria em cada produto, ligada sozinha pelo nome
   ("Mandioca" → Macaxeira; "Tomate italiano" → Tomate)

## Segurança e proteção de dados

**No banco (Supabase):**
- Row Level Security em todas as tabelas: cada pessoa só vê os próprios dados; o
  endereço de entrega só aparece para o agricultor daquele pedido.
- Ninguém vira administrador pelo cadastro; o pedido só muda de status pelas regras.
- A distância até o produtor é aproximada (km inteiro, grade de ~1 km), para que a
  localização da propriedade não possa ser descoberta por triangulação.
- Auditoria (só o admin lê): quem mudou o status de um pedido, um preço ou a localização.
- Endereço de entrega apagado 90 dias após a entrega ou o cancelamento.
- Limites de tamanho nos textos e de pedidos por comprador.

**No site:**
- Content-Security-Policy: só scripts deste site e do jsDelivr; conexões só com o
  Supabase e o ViaCEP (dados não saem para outros servidores).
- Bibliotecas em versão fixa e com `integrity` (SRI).
- Todo texto vindo do banco passa por escape antes de virar HTML (contra XSS).
- Senha com no mínimo 8 caracteres, com letras e números; sessão sem "Manter
  conectado" termina após 30 minutos sem uso.

**Configurar no painel do Supabase** (não dá para fazer por código):
- Authentication → Email: "Confirm email" ligado; senha mínima de 8 caracteres,
  com letras e números; proteção contra senhas vazadas, se o plano permitir.
- Authentication → URL Configuration: só o endereço do site nos redirecionamentos.
- Database → Extensions: ligar `pg_cron` e rodar o script 08 de novo (agenda a
  limpeza diária dos endereços antigos).

Limite conhecido: o GitHub Pages não permite cabeçalhos HTTP próprios
(`frame-ancestors`, por exemplo), e o CSP mantém `'unsafe-inline'` porque os
botões usam `onclick`.

## Publicação

Cada commit é enviado automaticamente para este repositório pelo gancho
`.githooks/post-commit`, e o GitHub Pages atualiza o site em cerca de 1 minuto.

Para ativar o envio automático em outro computador (uma vez, depois de clonar):

```bash
git config core.hooksPath .githooks
```

Sem internet, o commit fica salvo no computador e vai junto no próximo envio.
