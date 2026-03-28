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

local function GetEmpresaJobPermitido(empresaId, empresaConfig)
	-- Prioriza a tabela nova de compatibilidade e mantém fallback legado.
	if Config and Config.OrganizacoesPermitidas and Config.OrganizacoesPermitidas[empresaId] then
		return Config.OrganizacoesPermitidas[empresaId]
	end

	return empresaConfig and empresaConfig.job or nil
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
			job = LocalPlayer.state.job,
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

local function GetPlayerJobData()
	-- Dados do job sempre passam pela bridge única GetPlayerData().
	local playerData = GetPlayerData()
	local job = playerData and playerData.job or nil

	if not job then
		return nil, nil
	end

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

local function PodeAbrirTablet(empresaId)
	-- Gate único de permissão no client para visibilidade no target.
	-- O servidor também valida novamente por segurança.
	local empresaConfig = Config.Empresas and Config.Empresas[empresaId]
	if not empresaConfig then
		return false
	end

	local jobPermitido = GetEmpresaJobPermitido(empresaId, empresaConfig)
	local ranksPermitidos = GetRanksPermitidos(empresaId, empresaConfig)

	local jobName, gradeValue = GetPlayerJobData()
	if not jobName or jobName ~= jobPermitido then
		return false
	end

	return IsGradePermitido(ranksPermitidos, gradeValue)
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

local function AbrirTabletFiscal(empresaId)
	-- Evita múltiplas aberturas simultâneas da interface.
	if nuiOpen then
		return
	end

	if not PodeAbrirTablet(empresaId) then
		Notify('Acesso negado. Necessario job e rank da diretoria.', 'error')
		return
	end

	-- VERIFICACAO DE INVENTARIO (ADS):
	-- Mesmo com filtro no ox_target, fazemos a validação manual aqui para impedir
	-- acesso indevido por evento/comando/bug de sincronização de UI.
	if not TemItemTabletFiscal() then
		Notify('Erro: Você precisa de um Tablet Fiscal para acessar este sistema.', 'error')
		return
	end

	StartTabletAnimation()

	-- Simula autenticação antes de carregar os dados empresariais.
	local loginOk = lib.progressBar({
		duration = 2000,
		label = 'Login no Sistema',
		useWhileDead = false,
		canCancel = true,
		disable = {
			move = true,
			car = true,
			combat = true,
			mouse = true
		}
	})

	if not loginOk then
		Notify('Login cancelado.', 'error')
		FecharTabletFiscal()
		return
	end

	local response = lib.callback.await('wpp_lavagem_fiscal:server:getEmpresaDados', false, empresaId)
	-- Dados críticos (saldo/último relatório) vêm do servidor já com validação.
	if not response or not response.ok then
		Notify((response and response.message) or 'Falha ao carregar dados da empresa.', 'error')
		FecharTabletFiscal()
		return
	end

	SendNUIMessage({
		action = 'openTabletFiscal',
		open = true,
		empresaId = response.empresaId,
		saldo = response.saldo,
		ultimoRelatorio = response.ultimo_relatorio
	})

	nuiOpen = true
	SetNuiFocus(true, true)
	SetNuiFocusKeepInput(false)
end

local function CriarInteracoesCofres()
	-- Cria 1 zona por empresa definida em Config.Empresas.
	if GetResourceState('ox_target') ~= 'started' then
		print(('[%s] ox_target nao encontrado. Interacoes de cofre desativadas.'):format(RESOURCE_NAME))
		return
	end

	for empresaId, empresaConfig in pairs(Config.Empresas or {}) do
		local zoneId = exports.ox_target:addSphereZone({
			coords = empresaConfig.cofre,
			radius = 1.8,
			debug = Config.Debug == true,
			options = {
				{
					-- O texto e ícone da interação podem ser customizados aqui.
					name = ('wpp_lavagem_fiscal_%s'):format(empresaId),
					label = 'Abrir Tablet Fiscal',
					icon = 'fa-solid fa-tablet-screen-button',
					items = (Config and Config.ItemTablet) or 'tablet_fiscal',
					distance = 2.0,
					canInteract = function()
						return PodeAbrirTablet(empresaId)
					end,
					onSelect = function()
						AbrirTabletFiscal(empresaId)
					end
				}
			}
		})

		targetZones[#targetZones + 1] = zoneId
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

RegisterNUICallback('requestDividendWithdraw', function(data, cb)
	local empresaId = data and data.empresaId and tostring(data.empresaId) or nil
	if not empresaId then
		cb({ ok = false, message = 'Empresa invalida.' })
		return
	end

	TriggerServerEvent('wpp_lavagem_fiscal:server:SacarDividendos', empresaId)

	-- Pequeno delay para permitir que o servidor finalize o saque e persistencia.
	CreateThread(function()
		Wait(650)
		local response = lib.callback.await('wpp_lavagem_fiscal:server:getEmpresaDados', false, empresaId)
		if response and response.ok then
			SendNUIMessage({
				action = 'updateTabletFiscal',
				empresaId = response.empresaId,
				saldo = response.saldo,
				ultimoRelatorio = response.ultimo_relatorio
			})
		end
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
