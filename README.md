# AgroNexo

Sistema web de gestão e comercialização para a **agricultura familiar**, alinhado ao
ODS 08 (Trabalho Decente e Crescimento Econômico). Projeto de TCC — CEUNI FAMETRO.

**Acesse:** https://xxbryan-del.github.io/AgroNexo---TCC/

## Tecnologias

- HTML5, CSS3 e JavaScript puro, em um único arquivo (`index.html`)
- [Supabase](https://supabase.com): PostgreSQL, autenticação, tempo real e Row Level Security
- Chart.js (gráficos do Dashboard) e API ViaCEP (endereço automático no cadastro)
- Acessibilidade WCAG 2.1: alto contraste, tamanho de fonte e leitura em voz alta

## Telas

| Tela | Situação |
|---|---|
| Login e cadastro em 4 etapas | pronta |
| Dashboard (vendas, previsão de estoque, atividade) | pronta |
| Meus Produtos (editar, arquivar, excluir) | pronta |
| Estoque (entradas, saídas e perdas com motivo, CSV) | pronta |
| Marketplace (vitrine, carrinho, entrega e distância) e Meus Pedidos do comprador | pronta |
| Pedidos do agricultor (rotas e rastreabilidade), Relatórios | em construção |

## Banco de dados

Os scripts ficam em `supabase/` e são executados no **SQL Editor** do Supabase,
nesta ordem (cada um pode ser rodado mais de uma vez):

1. `01-seguranca.sql` — permissões (RLS), regras de pedido e baixa de estoque
2. `02-historico-dashboard.sql` — histórico de estoque e vendas por dia
3. `03-estoque.sql` — movimentações de estoque com motivo
4. `04-marketplace.sql` — pedido com entrega, localização e código de rastreio

## Publicação

Cada commit é enviado automaticamente para este repositório pelo gancho
`.githooks/post-commit`, e o GitHub Pages atualiza o site em cerca de 1 minuto.

Para ativar o envio automático em outro computador (uma vez, depois de clonar):

```bash
git config core.hooksPath .githooks
```

Sem internet, o commit fica salvo no computador e vai junto no próximo envio.
