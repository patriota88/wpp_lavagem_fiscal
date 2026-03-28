---@diagnostic disable: undefined-global

local RESOURCE_NAME = GetCurrentResourceName()
-- Taxa da empresa: prefira alterar em Config.TaxaEmpresa (config.lua).
-- Este fallback (0.25) só é usado se a config estiver ausente/inválida.
local TAXA_EMPRESA = tonumber(Config.TaxaEmpresa) or 0.25
-- Chance percentual de alerta para polícia. Ex.: 15 = 15%.
local CHANCE_ALERTA = 15
-- Raio máximo (em metros) para considerar que o player está no cofre.
-- Aumente apenas se o ponto de interação estiver "largo" no seu mapa.
local DISTANCIA_MAX_COFRE = 4.0

-- [Compatibilidade Multi-Framework - Servidor]
-- Este bloco torna o arquivo universal para QBCore, Qbox e MRI-Qbox.
-- A deteccao segue Config.Framework e, no modo auto, tenta:
-- qbit-core -> qbx_core -> qb-core.
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
	-- Guia de customizacao:
	-- Prioriza Config.OrganizacoesPermitidas para facilitar manutenção entre bases.
	if Config and Config.OrganizacoesPermitidas and Config.OrganizacoesPermitidas[empresaId] then
		return Config.OrganizacoesPermitidas[empresaId]
	end

	return empresaConfig and empresaConfig.job or nil
end

local function GetRanksPermitidos(empresaId, empresaConfig)
	-- Guia de customizacao:
	-- Prioriza Config.RanksPermitidos e preserva fallback legado por empresa.
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
	-- Todas as validacoes server-side usam esta funcao para manter consistencia.
	local player = GetPlayerObject(src)
	if not player then
		return nil
	end

	return player.PlayerData
end

local function GetPlayerJobData(src)
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

local function IsGradePermitido(ranksPermitidos, gradeValue)
	local gradeString = tostring(gradeValue or '')
	local grade2 = tonumber(gradeValue) and string.format('%02d', tonumber(gradeValue)) or gradeString

	for _, permitido in ipairs(ranksPermitidos or {}) do
		local expected = tostring(permitido)
		if expected == gradeString or expected == grade2 then
			return true
		end
	end

	return false
end

local function GetJobName(src)
	local playerData = GetPlayerData(src)
	if not playerData or not playerData.job then
		return nil
	end

	return playerData.job.name
end

local function IsPoliceJob(jobName)
	if not jobName then
		return false
	end

	-- Ajuste aqui caso sua cidade use nomes diferentes para polícia
	-- (ex.: sheriff, bope, prf, etc.).
	local policeJobs = {
		police = true,
		policia = true
	}

	return policeJobs[jobName] == true
end

local function EstaPertoDoCofre(src, cofreCoords)
	local ped = GetPlayerPed(src)
	if not ped or ped == 0 then
		return false
	end

	local playerCoords = GetEntityCoords(ped)
	return #(playerCoords - cofreCoords) <= DISTANCIA_MAX_COFRE
end

local function RemoverDinheiroSujo(src, valor)
	if GetResourceState('ox_inventory') ~= 'started' then
		return false, 'ox_inventory nao esta iniciado.'
	end

	-- Ordem de tentativa: black_money (padrão deste servidor) e fallback dirtymoney.
	-- Se sua economia usa outro item, altere os nomes abaixo.
	if exports.ox_inventory:RemoveItem(src, 'black_money', valor) then
		return true
	end

	if exports.ox_inventory:RemoveItem(src, 'dirtymoney', valor) then
		return true
	end

	return false, 'Voce nao possui dinheiro sujo suficiente.'
end

local function GerarRelatorioFuncionarios(valorTotal)
	-- Fonte dos nomes usada no relatório fiscal; editar em config.lua.
	local funcionarios = Config.FuncionariosFantasmas or {}
	local quantidade = #funcionarios

	if quantidade == 0 then
		return {}
	end

	local pesos = {}
	local somaPesos = 0
	for i = 1, quantidade do
		-- Peso aleatório define quanto cada nome recebe do montante de 75%.
		local peso = math.random(1, 100)
		pesos[i] = peso
		somaPesos = somaPesos + peso
	end

	local relatorio = {}
	local somaDistribuida = 0
	for i = 1, quantidade do
		local parte = math.floor((valorTotal * pesos[i]) / somaPesos)
		relatorio[i] = {
			nome = funcionarios[i],
			valor = parte
		}
		somaDistribuida = somaDistribuida + parte
	end

	-- Ajuste de arredondamento para garantir 100% da distribuição.
	local restante = valorTotal - somaDistribuida
	while restante > 0 do
		local idx = math.random(1, quantidade)
		relatorio[idx].valor = relatorio[idx].valor + 1
		restante = restante - 1
	end

	return relatorio
end

local function CreditarContaEmpresa(empresaId, valor)
	if valor <= 0 then
		return true
	end

	if GetResourceState('ps-banking') ~= 'started' then
		return false, 'ps-banking nao esta iniciado.'
	end

	-- empresaId precisa bater com o "holder" existente em ps_banking_accounts.
	-- Ex.: se a conta no banco for "casino", o empresaId também deve ser "casino".
	local ok, result = pcall(function()
		return exports['ps-banking']:AddMoney(empresaId, valor, 'lavagem-fiscal')
	end)

	if not ok then
		return false, 'Falha na chamada do ps-banking.'
	end

	if result ~= true then
		return false, 'Conta da empresa nao encontrada no ps-banking.'
	end

	return true
end

local function EnviarAlertaPolicia(empresaId, cofreCoords)
	-- Dispara para todos os policiais online. Caso queira integrar com MDT,
	-- este é o ponto ideal para também enviar blip/log externo.
	for _, playerId in ipairs(GetPlayers()) do
		local target = tonumber(playerId)
		local jobName = GetJobName(target)

		if IsPoliceJob(jobName) then
			Notify(
				target,
				('Inconsistencia Fiscal detectada em %s. Verificar setor financeiro nas proximidades do cofre.'):format(empresaId),
				'error'
			)
			TriggerClientEvent('wpp_lavagem_fiscal:client:AlertaFiscal', target, {
				empresaId = empresaId,
				coords = {
					x = cofreCoords.x,
					y = cofreCoords.y,
					z = cofreCoords.z
				}
			})
		end
	end
end

RegisterNetEvent('wpp_lavagem_fiscal:server:DepositarDinheiroSujo', function(empresaId, valorInformado)
	-- Evento principal de lavagem. O client deve enviar:
	-- 1) empresaId (string da chave em Config.Empresas)
	-- 2) valorInformado (quantia em dinheiro sujo)
	local src = source
	local empresaKey = tostring(empresaId or '')
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]

	if FRAMEWORK == 'none' then
		Notify(src, 'Nenhum framework compativel encontrado (Qbox/MRI-Qbox/QB-Core).', 'error')
		return
	end

	if not empresaConfig then
		Notify(src, 'Empresa invalida para operacao de lavagem.', 'error')
		return
	end

	if not EstaPertoDoCofre(src, empresaConfig.cofre) then
		-- Anti-abuso: impede executar lavagem fora da área do cofre configurado.
		Notify(src, 'Voce precisa estar no cofre da empresa para depositar.', 'error')
		return
	end

	-- [Seguranca de Servidor - Job/Rank]
	-- Toda autorizacao e feita com source real no servidor.
	local jobPermitido = GetEmpresaJobPermitido(empresaKey, empresaConfig)
	local ranksPermitidos = GetRanksPermitidos(empresaKey, empresaConfig)
	local jobName, gradeValue = GetPlayerJobData(src)

	if jobName ~= jobPermitido then
		Notify(src, 'Seu emprego nao tem permissao para usar este cofre.', 'error')
		return
	end

	if not IsGradePermitido(ranksPermitidos, gradeValue) then
		Notify(src, 'Seu cargo nao possui permissao para operar este cofre.', 'error')
		return
	end

	local valor = math.floor(tonumber(valorInformado) or 0)
	local minimo = (Config.LimitesLavagem and Config.LimitesLavagem.minimo) or 5000
	local maximo = (Config.LimitesLavagem and Config.LimitesLavagem.maximo) or 200000
	-- Limites de negócio: ajuste em Config.LimitesLavagem no config.lua.

	if valor < minimo or valor > maximo then
		Notify(src, ('Valor invalido. Permitido entre $%d e $%d.'):format(minimo, maximo), 'error')
		return
	end

	local removeu, erroRemocao = RemoverDinheiroSujo(src, valor)
	if not removeu then
		Notify(src, erroRemocao or 'Falha ao remover o dinheiro sujo.', 'error')
		return
	end

	local valorEmpresa = math.floor(valor * TAXA_EMPRESA)
	if type(TransferirTaxaEmpresa) == 'function' then
		local okTaxa, valorCalculado, erroTaxa = TransferirTaxaEmpresa(empresaKey, valor)
		if not okTaxa then
			if GetResourceState('ox_inventory') == 'started' then
				exports.ox_inventory:AddItem(src, 'black_money', valor)
			end

			Notify(src, erroTaxa or 'Falha ao transferir taxa da empresa.', 'error')
			return
		end

		valorEmpresa = math.floor(tonumber(valorCalculado) or 0)
	else
		local creditou, erroCredito = CreditarContaEmpresa(empresaKey, valorEmpresa)
		if not creditou then
			-- Reembolso em caso de falha de integraçao bancaria.
			if GetResourceState('ox_inventory') == 'started' then
				exports.ox_inventory:AddItem(src, 'black_money', valor)
			end

			Notify(src, erroCredito or 'Falha ao creditar conta da empresa.', 'error')
			return
		end
	end

	local valorFuncionarios = valor - valorEmpresa
	-- Regra atual:
	-- valorEmpresa = 25% (empresa)
	-- valorFuncionarios = 75% (distribuição aleatória no relatório)
	local relatorioFuncionarios = GerarRelatorioFuncionarios(valorFuncionarios)

	local dadosAtuais = GetDadosEmpresa(empresaKey)
	-- Persistência:
	-- soma o novo valor da empresa ao saldo existente e salva um relatório completo
	-- da operação (json) para auditoria/admin.
	local novoSaldo = (tonumber(dadosAtuais.saldo) or 0) + valorEmpresa
	local relatorioCompleto = {
		data = os.date('%Y-%m-%d %H:%M:%S'),
		empresa_id = empresaKey,
		valor_depositado = valor,
		valor_empresa = valorEmpresa,
		valor_funcionarios = valorFuncionarios,
		funcionarios = relatorioFuncionarios
	}

	local salvou = SalvarSaldoEmpresa(empresaKey, novoSaldo, relatorioCompleto)
	if not salvou then
		Notify(src, 'Operacao concluida, mas houve falha ao salvar o relatorio no banco.', 'error')
		return
	end

	if math.random(100) <= CHANCE_ALERTA then
		-- Gatilho probabilístico de inconsistência fiscal para polícia.
		EnviarAlertaPolicia(empresaKey, empresaConfig.cofre)
	end

	Notify(
		src,
		('Lavagem concluida: $%d para empresa e $%d distribuido no relatorio fiscal.'):format(valorEmpresa, valorFuncionarios),
		'success'
	)
end)

AddEventHandler('onResourceStart', function(resourceName)
	if resourceName ~= RESOURCE_NAME then
		return
	end

	local frameworkText = FRAMEWORK == 'none' and 'incompativel' or FRAMEWORK
	print(('[%s] Main inicializado. Framework detectado: %s'):format(RESOURCE_NAME, frameworkText))
end)
