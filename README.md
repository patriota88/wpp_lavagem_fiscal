# wpp_lavagem_fiscal

Sistema de lavagem de dinheiro para FiveM (Qbox/QB-Core), com foco em empresas de fachada, controle fiscal e interface de tablet (NUI).

O recurso permite que cargos autorizados de cada empresa façam operações de lavagem com regras de limite, distribuição fiscal simulada e auditoria básica via relatórios.

## Visão Geral

Este projeto foi desenvolvido para servidores FiveM que utilizam ecossistema Qbox ou QB-Core, trazendo uma mecânica de economia ilegal com camada fiscal e narrativa de "empresa legal".

Fluxo principal:
1. O jogador autorizado acessa o cofre da empresa.
2. Abre o Tablet Fiscal (NUI).
3. Executa a lavagem de dinheiro sujo dentro dos limites configurados.
4. O sistema distribui os valores conforme regra fiscal e salva relatório.

## Tecnologias Utilizadas

- Lua 5.4: lógica principal de cliente/servidor no FiveM.
- NUI (HTML): estrutura da interface do tablet.
- JavaScript: comportamento da interface e comunicação com callbacks Lua.
- CSS: estilização do painel fiscal.
- ox_lib: notificações, callbacks e utilitários.
- oxmysql: persistência dos dados no banco MySQL.
- ox_inventory: validação/remoção de dinheiro sujo e item do tablet.
- ox_target: zonas de interação nos cofres.
- ps-banking: movimentação de saldo nas contas das organizações.

## Funcionalidades Principais

- Tablet Fiscal (NUI):
  - Acesso por permissão de gang + grade.
  - Exibição do saldo atual da empresa.
  - Exibição do último relatório de distribuição.
  - Ação de saque de dividendos para diretoria autorizada.

- Sistema de Funcionários Fantasmas:
  - Geração de relatório com nomes fictícios configuráveis.
  - Distribuição aleatória do montante destinado ao relatório fiscal.
  - Registro da operação para consulta/auditoria.

- Regras de Lavagem:
  - Limite mínimo e máximo por operação.
  - Percentual da empresa configurável (`Config.TaxaEmpresa`).
  - Validação de proximidade do cofre para evitar abuso.
  - Chance de alerta fiscal para policiais online.

- Relatório Fiscal Semanal:
  - Comando para polícia em serviço (`/relatoriofiscal`).
  - Exibição em chat com dados recentes das empresas.

## Estrutura do Projeto

```text
wpp_lavagem_fiscal/
|- config.lua
|- fxmanifest.lua
|- client/
|  |- main.lua
|  |- tablet.lua
|- server/
|  |- accounting.lua
|  |- database.lua
|  |- main.lua
|- web/
|  |- index.html
|  |- script.js
|  |- style.css
```

## Requisitos

Garanta que os recursos abaixo estejam instalados e iniciados no servidor:

- qbx_core (ou qb-core)
- ox_lib
- oxmysql
- ox_inventory
- ox_target
- ps-banking

## Configuração

Ajuste os principais parâmetros em `config.lua`:

- `Config.LimitesLavagem.minimo`
- `Config.LimitesLavagem.maximo`
- `Config.TaxaEmpresa`
- `Config.ItemTablet`
- `Config.Empresas`
- `Config.FuncionariosFantasmas`

## Instalação

1. Coloque a pasta `wpp_lavagem_fiscal` dentro de `resources/[standalone]`.
2. Verifique se as dependências estão instaladas.
3. Adicione no seu `server.cfg`:

```cfg
ensure ox_lib
ensure oxmysql
ensure ox_inventory
ensure ox_target
ensure ps-banking
ensure wpp_lavagem_fiscal
```

## Comandos e Uso

- `/relatoriofiscal`
  - Disponível para policiais em serviço.
  - Mostra o relatório fiscal semanal no chat.

No dia a dia das empresas:
1. Tenha o item configurado em `Config.ItemTablet` no inventário.
2. Vá até o cofre da empresa cadastrada.
3. Abra o Tablet Fiscal e execute as operações permitidas.

## Observações

- Este recurso faz validações importantes também no servidor para evitar exploração de eventos.
- A tabela `wpp_lavagem_status` é criada automaticamente quando o recurso inicia.
- O arquivo `client/tablet.lua` está presente na estrutura, mas atualmente sem implementação.

## Créditos

Desenvolvido por Patriota_88.
