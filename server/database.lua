---@diagnostic disable: undefined-global

-- Cache local em memória para reduzir consultas repetidas no banco.
-- Estrutura:
-- SaldosCache[empresaId] = {
--     saldo = number,
--     tempo_fim = number,
--     total_lavado = number,
--     saldo_empresa = number,
--     saldo_cliente = number,
--     ultimo_relatorio = table
-- }
local SaldosCache = {}

local function DecodeRelatorio(jsonString)
	if type(jsonString) ~= 'string' or jsonString == '' then
		return {}
	end

	local ok, decoded = pcall(json.decode, jsonString)
	if ok and type(decoded) == 'table' then
		return decoded
	end

	return {}
end

local function CarregarSaldosCache()
	-- 1) Lê todos os registros da tabela no banco.
	-- 2) Converte o JSON de ultimo_relatorio para tabela Lua.
	-- 3) Guarda tudo em memória para acesso rápido durante o runtime.
	local rows = MySQL.query.await(
		'SELECT empresa_id, saldo_lavado, tempo_fim, total_lavado, saldo_empresa, saldo_cliente, ultimo_relatorio FROM wpp_lavagem_status',
		{}
	)

	SaldosCache = {}

	-- Se a tabela estiver vazia (ou sem retorno em formato de tabela),
	-- mantemos o cache vazio sem interromper o recurso.
	if type(rows) ~= 'table' or #rows == 0 then
		return
	end

	for _, row in ipairs(rows) do
		local cacheKey = tostring(row.empresa_id)
		SaldosCache[cacheKey] = {
			saldo = tonumber(row.saldo_lavado) or 0,
			tempo_fim = tonumber(row.tempo_fim) or 0,
			total_lavado = tonumber(row.total_lavado) or 0,
			saldo_empresa = tonumber(row.saldo_empresa) or 0,
			saldo_cliente = tonumber(row.saldo_cliente) or 0,
			ultimo_relatorio = DecodeRelatorio(row.ultimo_relatorio)
		}
	end
end

local function GarantirTabelaLavagemStatus()
	MySQL.query.await(
		[[
			CREATE TABLE IF NOT EXISTS `wpp_lavagem_status` (
				`empresa_id` VARCHAR(50) NOT NULL,
				`saldo_lavado` DECIMAL(15,2) NOT NULL DEFAULT 0,
				`tempo_fim` BIGINT NULL,
				`total_lavado` BIGINT NOT NULL DEFAULT 0,
				`saldo_empresa` BIGINT NOT NULL DEFAULT 0,
				`saldo_cliente` BIGINT NOT NULL DEFAULT 0,
				`ultimo_relatorio` LONGTEXT NULL,
				`dono_identifier` VARCHAR(80) NULL,
				PRIMARY KEY (`empresa_id`)
			) ENGINE=InnoDB
			DEFAULT CHARSET=utf8mb4
			COLLATE=utf8mb4_unicode_ci
		]],
		{}
	)

	local hasTempoFim = MySQL.single.await(
		[[
			SELECT COLUMN_NAME
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_SCHEMA = DATABASE()
			  AND TABLE_NAME = 'wpp_lavagem_status'
			  AND COLUMN_NAME = 'tempo_fim'
			LIMIT 1
		]],
		{}
	)

	if not hasTempoFim then
		MySQL.query.await('ALTER TABLE wpp_lavagem_status ADD COLUMN tempo_fim BIGINT NULL', {})
	end

	local hasTotalLavado = MySQL.single.await(
		[[
			SELECT COLUMN_NAME
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_SCHEMA = DATABASE()
			  AND TABLE_NAME = 'wpp_lavagem_status'
			  AND COLUMN_NAME = 'total_lavado'
			LIMIT 1
		]],
		{}
	)

	if not hasTotalLavado then
		MySQL.query.await('ALTER TABLE wpp_lavagem_status ADD COLUMN total_lavado BIGINT NOT NULL DEFAULT 0', {})
	end

	local hasSaldoEmpresa = MySQL.single.await(
		[[
			SELECT COLUMN_NAME
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_SCHEMA = DATABASE()
			  AND TABLE_NAME = 'wpp_lavagem_status'
			  AND COLUMN_NAME = 'saldo_empresa'
			LIMIT 1
		]],
		{}
	)

	if not hasSaldoEmpresa then
		MySQL.query.await('ALTER TABLE wpp_lavagem_status ADD COLUMN saldo_empresa BIGINT NOT NULL DEFAULT 0', {})
	end

	local hasSaldoCliente = MySQL.single.await(
		[[
			SELECT COLUMN_NAME
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_SCHEMA = DATABASE()
			  AND TABLE_NAME = 'wpp_lavagem_status'
			  AND COLUMN_NAME = 'saldo_cliente'
			LIMIT 1
		]],
		{}
	)

	if not hasSaldoCliente then
		MySQL.query.await('ALTER TABLE wpp_lavagem_status ADD COLUMN saldo_cliente BIGINT NOT NULL DEFAULT 0', {})
	end
end

-- Atualiza o saldo de uma empresa no banco e sincroniza o cache em seguida.
-- Opcionalmente também recebe ultimoRelatorio para persistir o JSON da operação.
-- Usa INSERT ... ON DUPLICATE KEY UPDATE para criar/atualizar no mesmo comando.
function SalvarSaldoEmpresa(empresaId, valor, ultimoRelatorio, donoIdentifier, tempoFim, totalLavado, saldoEmpresa, saldoCliente)
	if not empresaId then
		return false
	end

	local saldo = tonumber(valor) or 0
	local relatorioTabela = type(ultimoRelatorio) == 'table' and ultimoRelatorio or {}
	local relatorioJson = json.encode(relatorioTabela)
	local dono = nil
	if type(donoIdentifier) == 'string' and donoIdentifier ~= '' then
		dono = donoIdentifier
	end

	local tempoFimValor = nil
	if tempoFim ~= nil then
		tempoFimValor = tonumber(tempoFim) or 0
	end

	local totalLavadoValor = nil
	if totalLavado ~= nil then
		totalLavadoValor = tonumber(totalLavado) or 0
	end

	local saldoEmpresaValor = nil
	if saldoEmpresa ~= nil then
		saldoEmpresaValor = tonumber(saldoEmpresa) or 0
	end

	local saldoClienteValor = nil
	if saldoCliente ~= nil then
		saldoClienteValor = tonumber(saldoCliente) or 0
	end

	local affectedRows = MySQL.update.await(
		[[
			INSERT INTO wpp_lavagem_status (empresa_id, saldo_lavado, tempo_fim, total_lavado, saldo_empresa, saldo_cliente, ultimo_relatorio, dono_identifier)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON DUPLICATE KEY UPDATE
				saldo_lavado = VALUES(saldo_lavado),
				tempo_fim = COALESCE(VALUES(tempo_fim), tempo_fim),
				total_lavado = COALESCE(VALUES(total_lavado), total_lavado),
				saldo_empresa = COALESCE(VALUES(saldo_empresa), saldo_empresa),
				saldo_cliente = COALESCE(VALUES(saldo_cliente), saldo_cliente),
				ultimo_relatorio = VALUES(ultimo_relatorio),
				dono_identifier = COALESCE(VALUES(dono_identifier), dono_identifier)
		]],
		{ empresaId, saldo, tempoFimValor, totalLavadoValor, saldoEmpresaValor, saldoClienteValor, relatorioJson, dono }
	)

	if not affectedRows then
		return false
	end

	local cacheKey = tostring(empresaId)
	if not SaldosCache[cacheKey] then
		SaldosCache[cacheKey] = {
			saldo = saldo,
			tempo_fim = tempoFimValor or 0,
			total_lavado = totalLavadoValor or 0,
			saldo_empresa = saldoEmpresaValor or 0,
			saldo_cliente = saldoClienteValor or 0,
			ultimo_relatorio = relatorioTabela
		}
	else
		SaldosCache[cacheKey].saldo = saldo
		if tempoFimValor ~= nil then
			SaldosCache[cacheKey].tempo_fim = tempoFimValor
		end
		if totalLavadoValor ~= nil then
			SaldosCache[cacheKey].total_lavado = totalLavadoValor
		end
		if saldoEmpresaValor ~= nil then
			SaldosCache[cacheKey].saldo_empresa = saldoEmpresaValor
		end
		if saldoClienteValor ~= nil then
			SaldosCache[cacheKey].saldo_cliente = saldoClienteValor
		end
		SaldosCache[cacheKey].ultimo_relatorio = relatorioTabela
	end

	return true
end

-- Retorna os dados da empresa priorizando cache.
-- Se não houver no cache, busca no banco, decodifica JSON e grava no cache.
function GetDadosEmpresa(empresaId)
	if not empresaId then
		return {
			saldo = 0,
			tempo_fim = 0,
			total_lavado = 0,
			saldo_empresa = 0,
			saldo_cliente = 0,
			ultimo_relatorio = {}
		}
	end

	local cacheKey = tostring(empresaId)
	local cached = SaldosCache[cacheKey]
	if cached then
		return {
			saldo = cached.saldo,
			tempo_fim = tonumber(cached.tempo_fim) or 0,
			total_lavado = tonumber(cached.total_lavado) or 0,
			saldo_empresa = tonumber(cached.saldo_empresa) or 0,
			saldo_cliente = tonumber(cached.saldo_cliente) or 0,
			ultimo_relatorio = cached.ultimo_relatorio
		}
	end

	local row = MySQL.single.await(
		'SELECT saldo_lavado, tempo_fim, total_lavado, saldo_empresa, saldo_cliente, ultimo_relatorio FROM wpp_lavagem_status WHERE empresa_id = ? LIMIT 1',
		{ empresaId }
	)

	if not row then
		SaldosCache[cacheKey] = {
			saldo = 0,
			tempo_fim = 0,
			ultimo_relatorio = {}
		}

		return {
			saldo = 0,
			tempo_fim = 0,
			total_lavado = 0,
			saldo_empresa = 0,
			saldo_cliente = 0,
			ultimo_relatorio = {}
		}
	end

	local dados = {
		saldo = tonumber(row.saldo_lavado) or 0,
		tempo_fim = tonumber(row.tempo_fim) or 0,
		total_lavado = tonumber(row.total_lavado) or 0,
		saldo_empresa = tonumber(row.saldo_empresa) or 0,
		saldo_cliente = tonumber(row.saldo_cliente) or 0,
		ultimo_relatorio = DecodeRelatorio(row.ultimo_relatorio)
	}

	SaldosCache[cacheKey] = dados
	return dados
end

AddEventHandler('onResourceStart', function(resourceName)
	if resourceName ~= GetCurrentResourceName() then
		return
	end

	-- Garante a estrutura da tabela antes de qualquer SELECT/INSERT.
	GarantirTabelaLavagemStatus()

	-- Na inicialização do recurso, o cache é preenchido com a tabela inteira.
	-- Depois disso, o script consulta a memória local e escreve no banco apenas
	-- quando houver atualização de saldo.
	CarregarSaldosCache()
end)
