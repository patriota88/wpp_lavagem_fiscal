---@diagnostic disable: undefined-global

-- [Compatibilidade Multi-Framework - Servidor]
-- Este arquivo trata permissões sensíveis (consulta/saque), então o bridge
-- precisa refletir exatamente a mesma estratégia em QBCore, Qbox e MRI-Qbox.
local function DetectFramework()
	local configured = string.lower(tostring((Config and Config.Framework) or 'auto'))

	if configured == 'qbox' or configured == 'mri-qbox' or configured == 'mri_qbox' then
		return 'qbox'
	end

	if configured == 'qbcore' or configured == 'qb-core' then
		return 'qbcore'
	end

	if GetResourceState('qbit-core') == 'started' then
		return 'qbox'
	end

	if GetResourceState('qbx_core') == 'started' then
		return 'qbox'
	end

	if GetResourceState('qb-core') == 'started' then
		return 'qbcore'
	end

	return 'none'
end

local FRAMEWORK = DetectFramework()
local QBCore = FRAMEWORK == 'qbcore' and GetResourceState('qb-core') == 'started' and exports['qb-core']:GetCoreObject() or nil

local function IsDebugEnabled()
	return Config and Config.Debug == true
end

local function DebugLog(message)
	if IsDebugEnabled() then
		print(('[wpp_lavagem_fiscal][DEBUG] %s'):format(message))
	end
end

local function Notify(src, message, nType)
	TriggerClientEvent('ox_lib:notify', src, {
		title = 'Lavagem Fiscal',
		description = message,
		type = nType or 'inform'
	})

	if FRAMEWORK == 'qbcore' then
		TriggerClientEvent('QBCore:Notify', src, message, nType or 'primary')
	end
end

local function GetEmpresaJobPermitido(empresaId, empresaConfig)
	-- Prioriza tabela nova de organização permitida por empresa.
	if Config and Config.OrganizacoesPermitidas and Config.OrganizacoesPermitidas[empresaId] then
		return Config.OrganizacoesPermitidas[empresaId]
	end

	return empresaConfig and empresaConfig.job or nil
end

local function GetRanksPermitidos(empresaId, empresaConfig)
	-- Prioriza tabela nova de ranks e mantém fallback legado.
	if Config and Config.RanksPermitidos and Config.RanksPermitidos[empresaId] then
		return Config.RanksPermitidos[empresaId]
	end

	return (empresaConfig and empresaConfig.gradesPermitidos) or {}
end

local function GetPlayerObject(src)
	if FRAMEWORK == 'qbox' then
		return exports.qbx_core:GetPlayer(src)
	end

	if FRAMEWORK == 'qbcore' and QBCore then
		return QBCore.Functions.GetPlayer(src)
	end

	return nil
end

local function GetPlayerData(src)
	-- [Bridge de PlayerData]
	-- Uniformiza o acesso a dados de personagem para validacao de seguranca.
	local player = GetPlayerObject(src)
	if not player then
		return nil
	end

	return player.PlayerData
end

local function GetPlayerName(player)
	local playerData = player and player.PlayerData or nil
	if not playerData then
		return 'Desconhecido'
	end

	local charinfo = playerData.charinfo or {}
	local firstname = charinfo.firstname or ''
	local lastname = charinfo.lastname or ''
	local fullName = (firstname .. ' ' .. lastname):gsub('^%s+', ''):gsub('%s+$', '')

	if fullName == '' then
		return playerData.name or 'Desconhecido'
	end

	return fullName
end

local function GetPlayerJobData(player)
	-- Normaliza nome do job e grade para lidar com diferenças entre versões
	-- de Qbox/QB-Core (grade em tabela, número ou string).
	if not player or not player.PlayerData or not player.PlayerData.job then
		return nil, nil
	end

	local job = player.PlayerData.job
	local jobName = job.name
	local gradeValue = nil

	if job.grade ~= nil then
		if type(job.grade) == 'table' then
			gradeValue = job.grade.level or job.grade.grade or job.grade.name
		else
			gradeValue = job.grade
		end
	end

	if gradeValue == nil and job.gradeLevel ~= nil then
		gradeValue = job.gradeLevel
	end

	if gradeValue == nil and job.grade_name ~= nil then
		gradeValue = job.grade_name
	end

	return jobName, gradeValue
end

local function GetPlayerJobDataBySource(src)
	local playerData = GetPlayerData(src)
	if not playerData or not playerData.job then
		return nil, nil
	end

	local job = playerData.job
	local jobName = job.name
	local gradeValue = nil

	if type(job.grade) == 'table' then
		gradeValue = job.grade.level or job.grade.grade or job.grade.name
	else
		gradeValue = job.grade
	end

	if gradeValue == nil and job.gradeLevel ~= nil then
		gradeValue = job.gradeLevel
	end

	if gradeValue == nil and job.grade_name ~= nil then
		gradeValue = job.grade_name
	end

	return jobName, gradeValue
end

local function IsPoliceJob(jobName)
	if not jobName then
		return false
	end

	-- Adicione aqui outros jobs policiais da sua cidade, se necessário.
	local policeJobs = {
		police = true,
		policia = true
	}

	return policeJobs[jobName] == true
end

local function IsPoliceOnDuty(player)
	if not player or not player.PlayerData or not player.PlayerData.job then
		return false
	end

	local job = player.PlayerData.job
	local jobName = job.name
	if not IsPoliceJob(jobName) then
		return false
	end

	-- Regra principal: precisa estar em serviço.
	-- Em servidores sem flag onduty, altere para true se quiser liberar para todo policial.
	return job.onduty == true
end

local function IsGradePermitido(ranksPermitidos, gradeValue)
	local permitidos = ranksPermitidos or {}
	-- Permite comparação em múltiplos formatos: "01", "1", 1.
	local gradeString = tostring(gradeValue or '')
	local grade2 = tonumber(gradeValue) and string.format('%02d', tonumber(gradeValue)) or gradeString

	for _, permitido in ipairs(permitidos) do
		local expected = tostring(permitido)
		if expected == gradeString or expected == grade2 then
			return true
		end
	end

	return false
end

local function DepositarBancoPessoal(player, valor)
	if valor <= 0 then
		return true
	end

	if not player or not player.Functions or not player.Functions.AddMoney then
		return false
	end

	-- Pagamento final para conta pessoal do diretor (conta bancária).
	player.Functions.AddMoney('bank', valor, 'Pagamento de Dividendos')
	return true
end

-- Transfere automaticamente a taxa de lavagem para a conta da organização no ps-banking.
-- Retorna: sucesso(boolean), valorEmpresa(number), erro(string|nil)
function TransferirTaxaEmpresa(empresaId, valorLavagem)
	-- Esta função é o ponto oficial para repassar a taxa da lavagem.
	-- Se mudar regra de percentual, altere Config.TaxaEmpresa no config.lua.
	local valorBase = math.floor(tonumber(valorLavagem) or 0)
	local taxa = tonumber(Config.TaxaEmpresa) or 0.25
	local valorEmpresa = math.floor(valorBase * taxa)

	if valorEmpresa <= 0 then
		return true, 0
	end

	if GetResourceState('ps-banking') ~= 'started' then
		return false, 0, 'ps-banking nao esta iniciado.'
	end

	local ok, result = pcall(function()
		return exports['ps-banking']:AddMoney(empresaId, valorEmpresa, 'lavagem-fiscal')
	end)

	if not ok then
		return false, 0, 'Falha na chamada de AddMoney no ps-banking.'
	end

	if result ~= true then
		return false, 0, 'Conta da organizacao nao encontrada no ps-banking.'
	end

	return true, valorEmpresa
end

local function GerarTabelaRelatorioSemanal(rows)
	-- Monta um relatório legível em texto para chat/console.
	-- Se quiser formato JSON para webhooks, este é o melhor ponto de ajuste.
	local linhas = {
		'===== RELATORIO SEMANAL - LAVAGEM FISCAL =====',
		('Gerado em: %s'):format(os.date('%d/%m/%Y %H:%M:%S')),
		'Periodo: ultimos 7 dias (baseado no campo data do ultimo_relatorio)',
		'-------------------------------------------------------------'
	}

	for _, row in ipairs(rows) do
		local empresaId = tostring(row.empresa_id)
		local saldo = tonumber(row.saldo_lavado) or 0
		local relatorio = {}

		if type(row.ultimo_relatorio) == 'string' and row.ultimo_relatorio ~= '' then
			-- O banco guarda JSON; aqui convertemos para tabela Lua com segurança.
			local ok, decoded = pcall(json.decode, row.ultimo_relatorio)
			if ok and type(decoded) == 'table' then
				relatorio = decoded
			end
		end

		local dataRelatorio = relatorio.data or 'N/A'
		table.insert(linhas, ('Empresa: %s | Saldo Atual: $%d | Ultimo Registro: %s'):format(empresaId, saldo, dataRelatorio))

		local funcionarios = relatorio.funcionarios
		if type(funcionarios) == 'table' and #funcionarios > 0 then
			table.insert(linhas, '  Funcionarios Fantasmas (ultima distribuicao):')
			for _, item in ipairs(funcionarios) do
				local nome = tostring(item.nome or 'Sem Nome')
				local valor = tonumber(item.valor) or 0
				table.insert(linhas, ('    - %-24s $%d'):format(nome, valor))
			end
		else
			table.insert(linhas, '  Sem dados de funcionarios no ultimo relatorio.')
		end

		table.insert(linhas, '-------------------------------------------------------------')
	end

	if #rows == 0 then
		table.insert(linhas, 'Nenhum dado encontrado para o periodo.')
		table.insert(linhas, '-------------------------------------------------------------')
	end

	return table.concat(linhas, '\n')
end

-- Gera relatorio textual para uso futuro por comando policial.
-- Exportado/global para facilitar consumo em outros arquivos.
function GerarRelatorioSemanalFiscal()
	-- Consulta base para relatório operacional/policial.
	local rows = MySQL.query.await(
		'SELECT empresa_id, saldo_lavado, ultimo_relatorio FROM wpp_lavagem_status',
		{}
	) or {}

	local seteDias = os.time() - (7 * 24 * 60 * 60)
	local filtradas = {}

	for _, row in ipairs(rows) do
		local incluir = true
		if type(row.ultimo_relatorio) == 'string' and row.ultimo_relatorio ~= '' then
			local ok, decoded = pcall(json.decode, row.ultimo_relatorio)
			if ok and type(decoded) == 'table' and decoded.data then
				-- Data esperada: YYYY-MM-DD HH:MM:SS (mesmo formato salvo no main.lua).
				local y, m, d, h, min, s = decoded.data:match('^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)$')
				if y and m and d and h and min and s then
					local year = tonumber(y) or 0
					local month = tonumber(m) or 0
					local day = tonumber(d) or 0
					local hour = tonumber(h) or 0
					local minute = tonumber(min) or 0
					local second = tonumber(s) or 0
					local ts = os.time({
						year = year,
						month = month,
						day = day,
						hour = hour,
						min = minute,
						sec = second
					})
					incluir = ts >= seteDias
				end
			end
		end

		if incluir then
			filtradas[#filtradas + 1] = row
		end
	end

	return GerarTabelaRelatorioSemanal(filtradas)
end

exports('TransferirTaxaEmpresa', TransferirTaxaEmpresa)
exports('GerarRelatorioSemanalFiscal', GerarRelatorioSemanalFiscal)

lib.callback.register('wpp_lavagem_fiscal:server:getEmpresaDados', function(source, empresaId)
	-- Callback usado pelo tablet no client para carregar saldo/relatório.
	-- Importante: possui validação de permissão no servidor (não confiar no client).
	local src = source
	local empresaKey = tostring(empresaId or '')
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]

	if FRAMEWORK == 'none' then
		return {
			ok = false,
			message = 'Framework incompativel. Necessario Qbox/MRI-Qbox ou QB-Core.'
		}
	end

	if not empresaConfig then
		return {
			ok = false,
			message = 'Empresa invalida.'
		}
	end

	local player = GetPlayerObject(src)
	if not player then
		return {
			ok = false,
			message = 'Jogador nao encontrado.'
		}
	end

	local jobPermitido = GetEmpresaJobPermitido(empresaKey, empresaConfig)
	local ranksPermitidos = GetRanksPermitidos(empresaKey, empresaConfig)

	local jobName, gradeValue = GetPlayerJobDataBySource(src)
	if jobName ~= jobPermitido then
		return {
			ok = false,
			message = 'Sem permissao para visualizar os dados desta empresa.'
		}
	end

	if not IsGradePermitido(ranksPermitidos, gradeValue) then
		return {
			ok = false,
			message = 'Acesso restrito aos cargos de diretoria.'
		}
	end

	local dados = GetDadosEmpresa(empresaKey)
	-- Retorno já sanitizado para evitar nils na NUI.
	return {
		ok = true,
		empresaId = empresaKey,
		saldo = tonumber(dados.saldo) or 0,
		ultimo_relatorio = type(dados.ultimo_relatorio) == 'table' and dados.ultimo_relatorio or {}
	}
end)

RegisterNetEvent('wpp_lavagem_fiscal:server:SacarDividendos', function(empresaId)
	-- Evento financeiro sensível: toda autorização é revalidada no servidor.
	local src = source
	local empresaKey = tostring(empresaId or '')
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]

	if FRAMEWORK == 'none' then
		Notify(src, 'Framework incompativel. Necessario Qbox/MRI-Qbox ou QB-Core.', 'error')
		return
	end

	if not empresaConfig then
		Notify(src, 'Empresa invalida para saque de dividendos.', 'error')
		return
	end

	local player = GetPlayerObject(src)
	if not player then
		Notify(src, 'Jogador nao encontrado no servidor.', 'error')
		return
	end

	-- [Seguranca de Servidor]
	-- Esta trava valida o jogador real (source) no servidor, impedindo bypass por NUI.
	local jobPermitido = GetEmpresaJobPermitido(empresaKey, empresaConfig)
	local ranksPermitidos = GetRanksPermitidos(empresaKey, empresaConfig)

	local jobName, gradeValue = GetPlayerJobDataBySource(src)
	if jobName ~= jobPermitido then
		Notify(src, 'Seu emprego nao pertence a esta empresa.', 'error')
		return
	end

	if not IsGradePermitido(ranksPermitidos, gradeValue) then
		Notify(src, 'Somente diretoria (cargos 01 e 02) pode sacar dividendos.', 'error')
		return
	end

	local dados = GetDadosEmpresa(empresaKey)
	local saldo = math.floor(tonumber(dados.saldo) or 0)

	if saldo <= 0 then
		Notify(src, 'Nao ha dividendos disponiveis para saque.', 'error')
		return
	end

	if GetResourceState('ps-banking') ~= 'started' then
		Notify(src, 'ps-banking nao esta iniciado.', 'error')
		return
	end

	local okRemove, removeResult = pcall(function()
		return exports['ps-banking']:RemoveMoney(empresaKey, saldo, 'saque-dividendos')
	end)

	if not okRemove or removeResult ~= true then
		Notify(src, 'Falha ao debitar saldo da organizacao no ps-banking.', 'error')
		return
	end

	if not DepositarBancoPessoal(player, saldo) then
		-- Reverte a retirada da conta da empresa se falhar depósito pessoal.
		-- Evita perda de saldo por falha parcial no meio da transação.
		exports['ps-banking']:AddMoney(empresaKey, saldo, 'rollback-saque-dividendos')
		Notify(src, 'Falha ao depositar dividendos na sua conta bancaria.', 'error')
		return
	end

	local manteveRelatorio = type(dados.ultimo_relatorio) == 'table' and dados.ultimo_relatorio or {}
	local salvou = SalvarSaldoEmpresa(empresaKey, 0, manteveRelatorio)
	if not salvou then
		Notify(src, 'Saque realizado, mas houve falha ao atualizar saldo no banco de dados.', 'error')
		return
	end

	local diretor = GetPlayerName(player)
	if IsDebugEnabled() then
		-- Log de auditoria administrativa de saque (somente com Config.Debug = true).
		DebugLog(('Saque de dividendos | Diretor: %s | Empresa: %s | Valor: $%d'):format(diretor, empresaKey, saldo))
	end

	Notify(src, ('Saque de dividendos realizado: $%d depositado em sua conta bancaria.'):format(saldo), 'success')
end)

RegisterCommand('relatoriofiscal', function(source)
	-- Comando preparado para uso por policiais em serviço.
	-- Se quiser integrar com MDT/Discord depois, reaproveite GerarRelatorioSemanalFiscal().
	local src = source

	if src == 0 then
		-- Permite execução no console para administração/debug.
		print(GerarRelatorioSemanalFiscal())
		return
	end

	if FRAMEWORK == 'none' then
		Notify(src, 'Framework incompativel. Necessario Qbox/MRI-Qbox ou QB-Core.', 'error')
		return
	end

	local player = GetPlayerObject(src)
	if not player then
		Notify(src, 'Jogador nao encontrado no servidor.', 'error')
		return
	end

	if not IsPoliceOnDuty(player) then
		Notify(src, 'Apenas policiais em servico podem ver o relatorio fiscal.', 'error')
		return
	end

	local relatorioTexto = GerarRelatorioSemanalFiscal()
	-- Envio linha a linha no chat para manter leitura estável sem truncar em uma única mensagem.
	TriggerClientEvent('chat:addMessage', src, {
		color = { 52, 152, 219 },
		args = { 'Relatorio Fiscal', '------------------------------' }
	})

	for linha in relatorioTexto:gmatch('[^\n]+') do
		TriggerClientEvent('chat:addMessage', src, {
			color = { 236, 240, 241 },
			args = { 'Relatorio Fiscal', linha }
		})
	end

	TriggerClientEvent('chat:addMessage', src, {
		color = { 52, 152, 219 },
		args = { 'Relatorio Fiscal', '------------------------------' }
	})
end, false)
