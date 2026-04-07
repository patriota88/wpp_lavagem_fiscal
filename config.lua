---@diagnostic disable: undefined-global
Config = Config or {}

-- Framework alvo do recurso.
-- Opcoes:
--   'auto'   -> detecta automaticamente entre qbit-core, qbx_core e qb-core
--   'qbox'   -> forca bridge qbox/mri-qbox (exports.qbx_core)
--   'qbcore' -> forca bridge qb-core
Config.Framework = 'auto'

-- Ative para exibir logs detalhados no console do servidor.
Config.Debug = false

-- Ajuste os limites de valor aceitos por operação de lavagem.
Config.LimitesLavagem = {
	minimo = 5000,
	maximo = 200000
}

-- Percentual destinado para a conta da empresa (ex.: 0.25 = 25%).
Config.TaxaEmpresa = 0.25

-- Nome do item físico necessário no inventário para abrir o tablet.
Config.ItemTablet = 'tablet_fiscal'

-- Item de dinheiro sujo usado no depósito do cofre.
-- Exemplo padrão no ox_inventory: 'black_money'.
Config.DirtyMoneyItem = 'black_money'

-- Limites globais de depósito no cofre (fallback).
-- Se a empresa tiver minDeposit/maxDeposit próprios, eles têm prioridade.
Config.minDeposit = 5000
Config.maxDeposit = 200000

-- Nível mínimo na hierarquia da gangue (ex: Subchefe/02) para conseguir acessar o tablet da empresa.
Config.NivelMinimoGerencia = 3

-- Duracao total da janela de lavagem (em segundos) usada no cronometro do tablet.
Config.TempoLavagemSegundos = 1800

-- Mapa de organizacoes permitidas por empresa do sistema.
-- Chave: empresaId (a mesma chave usada em Config.Empresas)
-- Valor: nome do gang que pode operar aquela empresa
--
-- Observacao para devs:
-- 1) Este mapa tem prioridade na validacao de permissao.
-- 2) Se uma empresa nao existir aqui, o script usa fallback de Config.Empresas[empresaId].gang.
Config.OrganizacoesPermitidas = {
	casino = 'casino',
	oficina_norte = 'oficina_norte',
	restaurante_pearls = 'restaurante_pearls'
}

-- Mapa de ranks/grades permitidos por empresa.
-- Chave: empresaId
-- Valor: lista de grades aceitas (string ou numero).
--
-- Observacao para devs:
-- 1) Este mapa tem prioridade sobre Config.Empresas[empresaId].gradesPermitidos.
-- 2) A comparacao no codigo normaliza formatos como "01", "1" e 1.
Config.RanksPermitidos = {
	casino = { '01', '02' },
	oficina_norte = { '01', '02' },
	restaurante_pearls = { '01', '02' }
}

-- Cadastro das empresas participantes do sistema.
Config.Empresas = {
	casino = {
		-- gang que representa a empresa.
		gang = 'casino',
		-- Limites específicos desta empresa para depósito no cofre.
		minDeposit = 5000,
		maxDeposit = 200000,
		-- Níveis autorizados a usar o tablet.
		gradesPermitidos = { '01', '02' },
		-- Coordenada do cofre financeiro da empresa.
		cofre = vector3(915.97, 60.61, 80.89)
	},

	oficina_norte = {
		gang = 'oficina_norte',
		minDeposit = 5000,
		maxDeposit = 200000,
		gradesPermitidos = { '01', '02' },
		cofre = vector3(117.24, 6610.92, 31.87)
	},

	restaurante_pearls = {
		gang = 'restaurante_pearls',
		minDeposit = 5000,
		maxDeposit = 200000,
		gradesPermitidos = { '01', '02' },
		cofre = vector3(-1826.85, -1195.88, 14.31)
	}
}

-- Lista usada para gerar nomes no relatório fiscal.
Config.FuncionariosFantasmas = {
	'Joao Vitor',
	'Mariana Soares',
	'Carlos Eduardo',
	'Fernanda Alves',
	'Rafael Moreira',
	'Patricia Nogueira',
	'Bruno Henrique',
	'Camila Teixeira'
}
