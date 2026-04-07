---@diagnostic disable: undefined-global

local RESOURCE_NAME = GetCurrentResourceName()
local TABLET_MODEL = GetHashKey('prop_cs_tablet')
local TABLET_ANIM_DICT = 'amb@world_human_seat_wall_tablet@female@base'
local TABLET_ANIM_CLIP = 'base'

local targetZones = {}
local nuiOpen = false
local tabletEntity = nil

-- [Compatibilidade Multi-Framework]
-- Este bloco centraliza a escolha do core para permitir o mesmo script em:
-- 1) QBCore (qb-core)
-- 2) Qbox
-- 3) MRI-Qbox (detecção via qbit-core, bridge via exports.qbx_core)
--
-- Como funciona:
-- - Config.Framework = 'auto': tenta qbit-core -> qbx_core -> qb-core.
-- - Config.Framework = 'qbox': força bridge qbox/mri-qbox.
-- - Config.Framework = 'qbcore': força bridge qb-core.
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
local QBCore = nil
if FRAMEWORK == 'qbcore' and GetResourceState('qb-core') == 'started' then
	QBCore = exports['qb-core']:GetCoreObject()
end

local function GetEmpresagangPermitido(empresaId, empresaConfig)
	-- Prioriza a tabela nova de compatibilidade e mantém fallback legado.
	if Config and Config.OrganizacoesPermitidas and Config.OrganizacoesPermitidas[empresaId] then
		return Config.OrganizacoesPermitidas[empresaId]
	end

	return empresaConfig and empresaConfig.gang or nil
end

local function GetRanksPermitidos(empresaId, empresaConfig)
	-- Prioriza a tabela nova de compatibilidade e mantém fallback legado.
	if Config and Config.RanksPermitidos and Config.RanksPermitidos[empresaId] then
		return Config.RanksPermitidos[empresaId]
	end

	return (empresaConfig and empresaConfig.gradesPermitidos) or {}
end

local function GetPlayerData()
	-- [Bridge de PlayerData]
	-- Mantém uma API única para o restante do script, independente da base.
	if FRAMEWORK == 'qbox' then
		local ok, data = pcall(function()
			return exports.qbx_core:GetPlayerData()
		end)
		if ok and type(data) == 'table' then
			return data
		end
	end

	if FRAMEWORK == 'qbcore' and QBCore and QBCore.Functions and QBCore.Functions.GetPlayerData then
		local ok, data = pcall(function()
			return QBCore.Functions.GetPlayerData()
		end)
		if ok and type(data) == 'table' then
			return data
		end
	end

	-- Fallback runtime para bases custom que sincronizam dados no state bag.
	if LocalPlayer and LocalPlayer.state then
		return {
			gang = LocalPlayer.state.gang,
			items = LocalPlayer.state.items
		}
	end

	return nil
end

local function HasItem(itemName)
	-- [Bridge de Inventário]
	-- Padrão oficial: ox_inventory (mantido por compatibilidade total entre bases).
	-- Fallback: consulta item via dados do framework apenas para cenários custom.
	if GetResourceState('ox_inventory') == 'started' then
		local count = exports.ox_inventory:Search('count', itemName) or 0
		return count > 0
	end

	local playerData = GetPlayerData()
	local items = playerData and playerData.items or nil
	if type(items) ~= 'table' then
		return false
	end

	for _, item in pairs(items) do
		local name = item and (item.name or item.item)
		local amount = tonumber(item and (item.amount or item.count)) or 0
		if name == itemName and amount > 0 then
			return true
		end
	end

	return false
end

local function Notify(message, nType)
	TriggerEvent('ox_lib:notify', {
		title = 'Lavagem Fiscal',
		description = message,
		type = nType or 'inform'
	})

	if FRAMEWORK == 'qbcore' and QBCore then
		TriggerEvent('QBCore:Notify', message, nType or 'primary')
	end
end

local function GetPlayergangData()
	-- Dados do gang sempre passam pela bridge única GetPlayerData().
	local playerData = GetPlayerData()
	local gang = playerData and playerData.gang or nil

	if not gang then
		return nil, nil
	end

	local gangName = gang.name
	local gradeValue = nil

	if type(gang.grade) == 'table' then
		gradeValue = gang.grade.level or gang.grade.grade or gang.grade.name
	else
		gradeValue = gang.grade
	end

	if gradeValue == nil and gang.gradeLevel ~= nil then
		gradeValue = gang.gradeLevel
	end

	if gradeValue == nil and gang.grade_name ~= nil then
		gradeValue = gang.grade_name
	end

	return gangName, gradeValue
end

local function IsGradePermitido(ranksPermitidos, gradeValue)
	-- Aceita tanto "01/02" quanto "1/2" conforme variação entre frameworks.
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

local function IsMembroDaEmpresa(empresaId)
	-- Regra operacional do cofre: qualquer membro da organização da empresa pode interagir.
	-- A validação administrativa (dono/gerência) fica exclusivamente no servidor.
	local empresaConfig = Config.Empresas and Config.Empresas[empresaId]
	if not empresaConfig then
		return false
	end

	local gangPermitido = GetEmpresagangPermitido(empresaId, empresaConfig)
	local gangName = GetPlayergangData()
	if not gangName or gangName ~= gangPermitido then
		return false
	end

	return true
end

local function GetLimitesDeposito(empresaId)
	local empresaConfig = Config.Empresas and Config.Empresas[empresaId] or {}

	local min = tonumber(empresaConfig.minDeposit)
		or tonumber((Config and Config.minDeposit))
		or tonumber(Config and Config.LimitesLavagem and Config.LimitesLavagem.minimo)
		or 5000
	local max = tonumber(empresaConfig.maxDeposit)
		or tonumber((Config and Config.maxDeposit))
		or tonumber(Config and Config.LimitesLavagem and Config.LimitesLavagem.maximo)
		or 200000

	min = math.floor(min)
	max = math.floor(max)

	if min < 1 then
		min = 1
	end

	if max < min then
		max = min
	end

	return min, max
end

local function AbrirDialogoDeposito(empresaId)
	local min, max = GetLimitesDeposito(empresaId)
	local input = lib.inputDialog('Depositar Dinheiro Sujo', {
		{
			type = 'number',
			label = ('Quantidade (Min: R$ %d | Max: R$ %d)'):format(min, max),
			required = true,
			min = min,
			max = max
		}
	})

	if not input or not input[1] then
		return
	end

	local valor = math.floor(tonumber(input[1]) or 0)
	if valor < min or valor > max then
		Notify(('Valor inválido. Permitido entre R$ %d e R$ %d.'):format(min, max), 'error')
		return
	end

	TriggerServerEvent('wpp_lavagem_fiscal:server:DepositarCofre', empresaId, valor)
end

local function TemItemTabletFiscal()
	local itemName = (Config and Config.ItemTablet) or 'tablet_fiscal'

	-- VERIFICACAO DE INVENTARIO (ADS):
	-- O helper HasItem prioriza ox_inventory e mantém fallback de framework.
	return HasItem(itemName)
end

local function StopTabletAnimation()
	-- Sempre limpar prop e animação para evitar "tablet preso" na mão.
	local ped = PlayerPedId()
	if tabletEntity and DoesEntityExist(tabletEntity) then
		DeleteEntity(tabletEntity)
		tabletEntity = nil
	end

	StopAnimTask(ped, TABLET_ANIM_DICT, TABLET_ANIM_CLIP, 2.0)
	ClearPedSecondaryTask(ped)
end

local function StartTabletAnimation()
	-- Animação visual de uso do tablet fiscal.
	local ped = PlayerPedId()
	lib.requestAnimDict(TABLET_ANIM_DICT)
	TaskPlayAnim(ped, TABLET_ANIM_DICT, TABLET_ANIM_CLIP, 8.0, -8.0, -1, 49, 0.0, false, false, false)

	lib.requestModel(TABLET_MODEL)
	tabletEntity = CreateObject(TABLET_MODEL, 0.0, 0.0, 0.0, true, true, false)
	AttachEntityToEntity(tabletEntity, ped, GetPedBoneIndex(ped, 57005), 0.17, 0.10, -0.13, 20.0, 180.0, 180.0, true, true, false, true, 1, true)
	SetModelAsNoLongerNeeded(TABLET_MODEL)
end

local function FecharTabletFiscal()
	-- Fluxo central de fechamento: NUI, foco e animação/prop.
	-- Reutilizado por comando, evento e callbacks da própria NUI.
	if nuiOpen then
		SendNUIMessage({
			action = 'closeTabletFiscal',
			open = false
		})
	end

	nuiOpen = false
	SetNuiFocus(false, false)
	SetNuiFocusKeepInput(false)
	StopTabletAnimation()
end

local function AbrirTabletFiscal(_)
	-- Evita múltiplas aberturas simultâneas da interface.
	if nuiOpen then
		return
	end

	local PlayerData = nil
	if QBCore and QBCore.Functions and QBCore.Functions.GetPlayerData then
		PlayerData = QBCore.Functions.GetPlayerData()
	else
		PlayerData = GetPlayerData()
	end

	if not PlayerData or not PlayerData.gang or not PlayerData.gang.name then
		Notify('Falha ao obter dados do jogador.', 'error')
		return
	end

	local playerGang = PlayerData.gang.name
	local playerGrade = nil
	if type(PlayerData.gang.grade) == 'table' then
		playerGrade = tonumber(PlayerData.gang.grade.level)
	else
		playerGrade = tonumber(PlayerData.gang.grade)
	end

	local empresaEncontrada = nil

	for k, v in pairs(Config.Empresas or {}) do
		if v.gang == playerGang then
			empresaEncontrada = k
			break
		end
	end

	print('^3[DEBUG] Gangue: ' .. tostring(playerGang) .. ' | Nível: ' .. tostring(playerGrade) .. ' | Empresa: ' .. tostring(empresaEncontrada) .. '^7')

	if empresaEncontrada == nil then
		Notify('Empresa invalida', 'error')
		return
	end

	if not playerGrade or playerGrade < (tonumber(Config.NivelMinimoGerencia) or 3) then
		Notify('Cargo insuficiente', 'error')
		return
	end

	print('^6--- [DEBUG] O Cliente recebeu a ordem para abrir a interface! ---^7')
	StartTabletAnimation()

	SendNUIMessage({
		action = 'openTabletFiscal',
		open = true,
		empresaId = empresaEncontrada,
		saldo = 0,
		tempoRestante = 0,
		ultimoRelatorio = {}
	})

	nuiOpen = true
	SetNuiFocus(true, true)
	print('^6--- [DEBUG] SetNuiFocus foi ativado para a interface do tablet. ---^7')
	SetNuiFocusKeepInput(false)

	-- Sincroniza dados reais (saldo + cronometro) no servidor ao abrir o tablet.
	TriggerServerEvent('wpp_lavagem_fiscal:server:SolicitarStatusTablet', empresaEncontrada)
end

RegisterNetEvent('wpp_lavagem:abrirTablet', function(empresaId)
	print('^6[DEBUG] Cliente recebeu comando para abrir!^7')
	AbrirTabletFiscal(empresaId)
end)

RegisterNetEvent('wpp_lavagem_fiscal:client:AbrirTabletFiscal', function(empresaId)
	print('--- [DEBUG] Recebido evento para abrir o Tablet ---')
	AbrirTabletFiscal(empresaId)
end)

RegisterNetEvent('wpp_lavagem_fiscal:client:StatusTabletFiscal', function(payload)
	if not nuiOpen then
		return
	end

	if not payload or payload.ok ~= true then
		Notify((payload and payload.message) or 'Falha ao sincronizar dados do tablet.', 'error')
		FecharTabletFiscal()
		return
	end

	SendNUIMessage({
		action = 'updateTabletFiscal',
		empresaId = payload.empresaId,
		saldo = payload.saldo,
		saldoEmpresa = payload.saldo_empresa,
		saldoCliente = payload.saldo_cliente,
		totalLavado = payload.total_lavado,
		tempoRestante = payload.tempo_restante,
		ultimoRelatorio = payload.ultimo_relatorio
	})
end)

local function CriarInteracoesCofres()
	-- Cria 1 zona por empresa definida em Config.Empresas.
	if GetResourceState('ox_target') ~= 'started' then
		print(('[%s] ox_target nao encontrado. Interacoes de cofre desativadas.'):format(RESOURCE_NAME))
		return
	end

	for empresaId, empresaConfig in pairs(Config.Empresas or {}) do
		local gangPermitido = GetEmpresagangPermitido(empresaId, empresaConfig)
		local zoneId = exports.ox_target:addSphereZone({
			coords = empresaConfig.cofre,
			radius = 1.8,
			debug = Config.Debug == true,
			options = {
				{
					-- O texto e ícone da interação podem ser customizados aqui.
					name = ('wpp_lavagem_fiscal_%s'):format(empresaId),
					label = 'Depositar Dinheiro Sujo',
					icon = 'fa-solid fa-money-bill-transfer',
					distance = 2.0,
					canInteract = function()
						return IsMembroDaEmpresa(empresaId)
					end,
					onSelect = function()
						AbrirDialogoDeposito(empresaId)
					end
				}
			}
		})

		targetZones[#targetZones + 1] = zoneId
		print(('[DEBUG] ox_target criado para %s nas coordenadas %.2f, %.2f, %.2f com gang %s'):format(
			tostring(empresaId),
			tonumber(empresaConfig.cofre.x) or 0.0,
			tonumber(empresaConfig.cofre.y) or 0.0,
			tonumber(empresaConfig.cofre.z) or 0.0,
			tostring(gangPermitido)
		))
	end
end

local function RemoverInteracoesCofres()
	-- Limpeza em stop/restart para não duplicar zonas de target.
	if GetResourceState('ox_target') ~= 'started' then
		return
	end

	for _, zoneId in ipairs(targetZones) do
		exports.ox_target:removeZone(zoneId)
	end

	targetZones = {}
end

RegisterNetEvent('wpp_lavagem_fiscal:client:FecharTablet', function()
	-- Evento externo para fechar o tablet (útil para integrações futuras).
	FecharTabletFiscal()
end)

RegisterCommand('fechartabletfiscal', function()
	-- Comando de emergência para o jogador recuperar controle de foco/NUI.
	FecharTabletFiscal()
end, false)

RegisterNUICallback('close', function(_, cb)
	FecharTabletFiscal()
	cb({ ok = true })
end)

RegisterNUICallback('closeTabletFiscal', function(_, cb)
	FecharTabletFiscal()
	cb({ ok = true })
end)

RegisterNUICallback('closeTablet', function(_, cb)
	FecharTabletFiscal()
	cb({ ok = true })
end)

local function AtualizarNuiEmpresa(empresaId)
	local response = lib.callback.await('wpp_lavagem_fiscal:server:getEmpresaDados', false, empresaId)
	if response and response.ok then
		SendNUIMessage({
			action = 'updateTabletFiscal',
			empresaId = response.empresaId,
			saldo = response.saldo,
			saldoEmpresa = response.saldo_empresa,
			saldoCliente = response.saldo_cliente,
			totalLavado = response.total_lavado,
			tempoRestante = response.tempo_restante,
			ultimoRelatorio = response.ultimo_relatorio
		})
	end
end

RegisterNUICallback('requestCompanyWithdraw', function(data, cb)
	local empresaId = data and data.empresaId and tostring(data.empresaId) or nil
	if not empresaId then
		cb({ ok = false, message = 'Empresa invalida.' })
		return
	end

	TriggerServerEvent('wpp_lavagem_fiscal:server:SacarCaixaEmpresa', empresaId)

	CreateThread(function()
		Wait(650)
		AtualizarNuiEmpresa(empresaId)
	end)

	cb({ ok = true })
end)

RegisterNUICallback('requestDividendWithdraw', function(data, cb)
	local empresaId = data and data.empresaId and tostring(data.empresaId) or nil
	if not empresaId then
		cb({ ok = false, message = 'Empresa invalida.' })
		return
	end

	TriggerServerEvent('wpp_lavagem_fiscal:server:SacarDividendosCliente', empresaId)

	CreateThread(function()
		Wait(650)
		AtualizarNuiEmpresa(empresaId)
	end)

	cb({ ok = true })
end)

CreateThread(function()
	-- Pequeno delay para garantir que ox_target/config já estejam prontos.
	Wait(500)
	CriarInteracoesCofres()
end)

AddEventHandler('onResourceStop', function(resourceName)
	if resourceName ~= RESOURCE_NAME then
		return
	end

	FecharTabletFiscal()
	RemoverInteracoesCofres()
end)

RegisterCommand('abrirnaforca', function()
	print('^6[DEBUG] Forçando abertura da NUI pelo comando...^7')
	TriggerEvent('wpp_lavagem:abrirTablet')
end, false)
