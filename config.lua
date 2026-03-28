---@diagnostic disable: undefined-global
Config = Config or {}

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

-- Cadastro das empresas participantes do sistema.
Config.Empresas = {
	casino = {
		-- Job que representa a empresa.
		job = 'casino',
		-- Níveis autorizados a usar o tablet.
		gradesPermitidos = { '01', '02' },
		-- Coordenada do cofre financeiro da empresa.
		cofre = vector3(915.97, 60.61, 80.89)
	},

	oficina_norte = {
		job = 'oficina_norte',
		gradesPermitidos = { '01', '02' },
		cofre = vector3(117.24, 6610.92, 31.87)
	},

	restaurante_pearls = {
		job = 'restaurante_pearls',
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
