---@diagnostic disable: undefined-global

local RESOURCE_NAME = GetCurrentResourceName()
print('^2--- [DEBUG] Script wpp_lavagem_fiscal iniciado com sucesso! ---^7')
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
local QBCore = nil

local function GetCoreObject()
	if GetResourceState('qb-core') == 'started' then
		local ok, core = pcall(function()
			return exports['qb-core']:GetCoreObject()
		end)
		if ok and core then
			return core
		end
	end

	if GetResourceState('qbx_core') == 'started' then
		local ok, core = pcall(function()
			return exports.qbx_core:GetCoreObject()
		end)
		if ok and core then
			return core
		end
	end

	return nil
end

QBCore = GetCoreObject()

MySQL.Async.execute('ALTER TABLE wpp_lavagem_status ADD COLUMN IF NOT EXISTS total_lavado INT DEFAULT 0', {}, function() end)
MySQL.Async.execute('ALTER TABLE wpp_lavagem_status ADD COLUMN IF NOT EXISTS saldo_empresa INT DEFAULT 0', {}, function() end)
MySQL.Async.execute('ALTER TABLE wpp_lavagem_status ADD COLUMN IF NOT EXISTS saldo_cliente INT DEFAULT 0', {}, function() end)

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

local function GetEmpresagangPermitido(empresaId, empresaConfig)
	-- Guia de customizacao:
	-- Prioriza Config.OrganizacoesPermitidas para facilitar manutenção entre bases.
	if Config and Config.OrganizacoesPermitidas and Config.OrganizacoesPermitidas[empresaId] then
		return Config.OrganizacoesPermitidas[empresaId]
	end

	return empresaConfig and empresaConfig.gang or nil
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

local function GetPlayerCitizenId(src)
	local playerData = GetPlayerData(src)
	if not playerData then
		return nil
	end

	if type(playerData.citizenid) == 'string' and playerData.citizenid ~= '' then
		return playerData.citizenid
	end

	if type(playerData.citizenId) == 'string' and playerData.citizenId ~= '' then
		return playerData.citizenId
	end

	return nil
end

local function GetPlayerNomeExato(src)
	-- Nome exato usado na auditoria do relatório fiscal.
	local playerData = GetPlayerData(src)
	if playerData then
		local charinfo = playerData.charinfo or {}
		local firstname = tostring(charinfo.firstname or '')
		local lastname = tostring(charinfo.lastname or '')
		local fullName = (firstname .. ' ' .. lastname):gsub('^%s+', ''):gsub('%s+$', '')

		if fullName ~= '' then
			return fullName
		end

		if type(playerData.name) == 'string' and playerData.name ~= '' then
			return playerData.name
		end
	end

	return GetPlayerName(src) or 'Desconhecido'
end

local function GetEmpresaIdPorgang(gangName)
	local gangProcurado = tostring(gangName or '')
	if gangProcurado == '' then
		return nil
	end

	for empresaId, empresaConfig in pairs(Config.Empresas or {}) do
		if GetEmpresagangPermitido(empresaId, empresaConfig) == gangProcurado then
			return empresaId
		end
	end

	return nil
end

local function GetSourceFromInventory(inventory)
	if type(inventory) == 'number' then
		return inventory
	end

	if type(inventory) == 'table' then
		if tonumber(inventory.id) then
			return tonumber(inventory.id)
		end

		if tonumber(inventory.source) then
			return tonumber(inventory.source)
		end

		if tonumber(inventory.owner) then
			return tonumber(inventory.owner)
		end
	end

	return nil
end

local function GetEmpresaIdPorDono(citizenId)
	local dono = tostring(citizenId or '')
	if dono == '' then
		return nil
	end

	local row = MySQL.single.await(
		'SELECT empresa_id FROM wpp_lavagem_status WHERE dono_identifier = ? LIMIT 1',
		{ dono }
	)

	local empresaId = row and row.empresa_id or nil
	print(('--- [DEBUG] Resultado banco (empresa por dono_identifier): %s ---'):format(tostring(empresaId)))
	return empresaId
end

-- Valida dono direto no banco para o cofre acessado.
-- Regra: empresa_id deve existir e dono_identifier deve bater com o citizenid atual.
function IsJogadorDonoDaEmpresa(src, empresaId)
	local empresaKey = tostring(empresaId or '')
	if empresaKey == '' then
		return false
	end

	local citizenId = GetPlayerCitizenId(src)
	if not citizenId then
		return false
	end

	local row = MySQL.single.await(
		'SELECT dono_identifier FROM wpp_lavagem_status WHERE empresa_id = ? LIMIT 1',
		{ empresaKey }
	)

	if not row or type(row.dono_identifier) ~= 'string' or row.dono_identifier == '' then
		return false
	end

	return row.dono_identifier == citizenId
end

local function GetPlayergangData(src)
	local playerData = GetPlayerData(src)
	if not playerData or not playerData.gang then
		return nil, nil
	end

	local gang = playerData.gang
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

local function GetgangName(src)
	local playerData = GetPlayerData(src)
	if not playerData or not playerData.gang then
		return nil
	end

	return playerData.gang.name
end

local function IsPolicegang(gangName)
	if not gangName then
		return false
	end

	-- Ajuste aqui caso sua cidade use nomes diferentes para polícia
	-- (ex.: sheriff, bope, prf, etc.).
	local policegangs = {
		police = true,
		law = true,
		policia = true
	}

	return policegangs[gangName] == true
end

local function IsCargoGerenciaOuSuperior(gradeValue)
	-- Nível mínimo configurável para liberar acesso administrativo ao tablet.
	-- Altere em Config.NivelMinimoGerencia no config.lua.
	local nivelMinimo = tonumber(Config.NivelMinimoGerencia) or 3
	local nivelJogador = tonumber(gradeValue)

	if not nivelJogador then
		return false
	end

	return nivelJogador >= nivelMinimo
end

function PodeAcessarTabletFiscal(src, empresaId)
	-- Regra administrativa do tablet:
	-- A) dono_identifier == citizenid do jogador.
	-- B) membro da organização + grade.level >= Config.NivelMinimoGerencia.
	local empresaKey = tostring(empresaId or '')
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]
	if not empresaConfig then
		return false, 'Empresa invalida.'
	end
	if IsJogadorDonoDaEmpresa(src, empresaKey) then
		return true, 'dono'
	end
	local gangPermitido = GetEmpresagangPermitido(empresaKey, empresaConfig)
	local gangName, gradeValue = GetPlayergangData(src)

	if not gangName or gangName ~= gangPermitido then
		return false, 'Acesso negado: sua organizacao nao possui permissao para este tablet.'
	end

	if not IsCargoGerenciaOuSuperior(gradeValue) then
		return false, 'Acesso negado: nivel hierarquico insuficiente para gerencia.'
	end
	return true, 'gerencia'
end

local function AbrirTabletParaSource(sourceId)
	TriggerClientEvent('wpp_lavagem:abrirTablet', sourceId)
	TriggerClientEvent('wpp_lavagem_fiscal:client:AbrirTabletFiscal', sourceId)
end

local function RegistrarTabletFiscalUsavel()
	local core = QBCore or GetCoreObject()
	QBCore = core

	if not core or not core.Functions or not core.Functions.CreateUseableItem then
		print('^1[DEBUG] Nao foi possivel registrar tablet_fiscal via core nativo neste momento.^7')
		return false
	end

	core.Functions.CreateUseableItem('tablet_fiscal', function(source)
		-- Registro simples e direto para compatibilidade com Qbox/ox_inventory.
		TriggerClientEvent('wpp_lavagem:abrirTablet', source)
	end)

	print(('[%s][DEBUG] Registro nativo do item tablet_fiscal finalizado com sucesso.'):format(RESOURCE_NAME))
	return true
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

local function ParseTimestampRelatorio(timestampText)
	if type(timestampText) ~= 'string' or timestampText == '' then
		return nil
	end

	local ano, mes, dia, hora, minuto, segundo = timestampText:match('^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)$')
	if not ano then
		return nil
	end

	local year = tonumber(ano)
	local month = tonumber(mes)
	local day = tonumber(dia)
	local hour = tonumber(hora)
	local min = tonumber(minuto)
	local sec = tonumber(segundo)
	if not year or not month or not day or not hour or not min or not sec then
		return nil
	end

	return os.time({
		year = year,
		month = month,
		day = day,
		hour = hour,
		min = min,
		sec = sec
	})
end

local function CalcularTempoRestanteLavagem(tempoFim)
	local restante = (tonumber(tempoFim) or 0) - os.time()
	if restante < 0 then
		restante = 0
	end
	return restante
end

local function GerarFuncionariosFantasmasParaSaldo(saldoTotal)
	local nomes = Config.FuncionariosFantasmas or {}
	if #nomes == 0 or saldoTotal <= 0 then
		return {}
	end

	local copia = {}
	for i = 1, #nomes do
		copia[i] = nomes[i]
	end

	for i = #copia, 2, -1 do
		local j = math.random(i)
		copia[i], copia[j] = copia[j], copia[i]
	end

	local quantidade = math.min(#copia, 6)
	if quantidade < 1 then
		quantidade = 1
	end

	local base = math.floor(saldoTotal / quantidade)
	local restante = saldoTotal - (base * quantidade)
	local lista = {}

	for i = 1, quantidade do
		local valor = base
		if restante > 0 then
			valor = valor + 1
			restante = restante - 1
		end

		lista[#lista + 1] = {
			nome = tostring(copia[i] or ('Funcionario ' .. tostring(i))),
			valor = valor
		}
	end

	return lista
end

function MontarStatusTabletEmpresa(empresaKey, dados)
	local saldoEmpresa = math.floor(tonumber(dados and dados.saldo_empresa) or 0)
	local saldoCliente = math.floor(tonumber(dados and dados.saldo_cliente) or 0)
	local saldo = saldoEmpresa + saldoCliente
	local tempoFim = tonumber(dados and dados.tempo_fim) or 0
	local totalLavado = math.floor(tonumber(dados and dados.total_lavado) or 0)
	local tempoRestante = CalcularTempoRestanteLavagem(tempoFim)
	local ultimoRelatorio = type(dados and dados.ultimo_relatorio) == 'table' and dados.ultimo_relatorio or {}

	if tempoRestante > 0 then
		local relatorioAtivo = {}
		for chave, valor in pairs(ultimoRelatorio) do
			relatorioAtivo[chave] = valor
		end
		relatorioAtivo.funcionarios = {}

		return {
			saldo = saldo,
			saldo_empresa = saldoEmpresa,
			saldo_cliente = saldoCliente,
			total_lavado = totalLavado,
			tempo_restante = tempoRestante,
			ultimo_relatorio = relatorioAtivo
		}
	end

	if saldo > 0 then
		local funcionariosProntos = type(ultimoRelatorio.funcionarios) == 'table' and #ultimoRelatorio.funcionarios > 0
		local saldoBase = tonumber(ultimoRelatorio.saldo_base_fantasmas) or -1
		if not funcionariosProntos or saldoBase ~= saldo then
			ultimoRelatorio.funcionarios = GerarFuncionariosFantasmasParaSaldo(saldo)
			ultimoRelatorio.saldo_base_fantasmas = saldo
			ultimoRelatorio.tempo_fim_epoch = tempoFim
			SalvarSaldoEmpresa(empresaKey, saldo, ultimoRelatorio, nil, tempoFim, totalLavado, saldoEmpresa, saldoCliente)
		end
	else
		ultimoRelatorio.funcionarios = {}
	end

	return {
		saldo = saldo,
		saldo_empresa = saldoEmpresa,
		saldo_cliente = saldoCliente,
		total_lavado = totalLavado,
		tempo_restante = 0,
		ultimo_relatorio = ultimoRelatorio
	}
end

RegisterNetEvent('wpp_lavagem_fiscal:server:SolicitarStatusTablet', function(empresaId)
	local src = source
	local empresaKey = tostring(empresaId or '')
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]

	if FRAMEWORK == 'none' then
		TriggerClientEvent('wpp_lavagem_fiscal:client:StatusTabletFiscal', src, {
			ok = false,
			message = 'Framework incompativel. Necessario Qbox/MRI-Qbox ou QB-Core.'
		})
		return
	end

	if not empresaConfig then
		TriggerClientEvent('wpp_lavagem_fiscal:client:StatusTabletFiscal', src, {
			ok = false,
			message = 'Empresa invalida.'
		})
		return
	end

	local autorizado, motivo = PodeAcessarTabletFiscal(src, empresaKey)
	if not autorizado then
		TriggerClientEvent('wpp_lavagem_fiscal:client:StatusTabletFiscal', src, {
			ok = false,
			message = 'Acesso negado ao tablet fiscal.'
		})
		print(('[%s][AVISO] Bloqueio ao sincronizar status do tablet | src=%s empresa=%s motivo=%s'):format(
			RESOURCE_NAME,
			tostring(src),
			tostring(empresaKey),
			tostring(motivo)
		))
		return
	end

	local status = MontarStatusTabletEmpresa(empresaKey, GetDadosEmpresa(empresaKey))
	TriggerClientEvent('wpp_lavagem_fiscal:client:StatusTabletFiscal', src, {
		ok = true,
		empresaId = empresaKey,
		saldo = status.saldo,
		saldo_empresa = status.saldo_empresa,
		saldo_cliente = status.saldo_cliente,
		total_lavado = status.total_lavado,
		tempo_restante = status.tempo_restante,
		ultimo_relatorio = status.ultimo_relatorio
	})
end)

local function SacarParteCofre(src, empresaKey, tipoSaque, descricao)
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]
	if not empresaConfig then
		Notify(src, 'Empresa invalida para saque.', 'error')
		return
	end

	if GetResourceState('ox_inventory') ~= 'started' then
		Notify(src, 'ox_inventory nao esta iniciado.', 'error')
		return
	end

	local player = GetPlayerObject(src)
	if not player or not player.PlayerData or not player.PlayerData.gang then
		Notify(src, 'Jogador nao encontrado no servidor.', 'error')
		return
	end

	local gangPermitido = GetEmpresagangPermitido(empresaKey, empresaConfig)
	local gangName = player.PlayerData.gang.name
	if gangName ~= gangPermitido then
		Notify(src, 'Seu emprego nao pertence a esta empresa.', 'error')
		return
	end

	local playerGrade = nil
	if type(player.PlayerData.gang.grade) == 'table' then
		playerGrade = tonumber(player.PlayerData.gang.grade.level)
	else
		playerGrade = tonumber(player.PlayerData.gang.grade)
	end

	if not playerGrade or playerGrade < (tonumber(Config.NivelMinimoGerencia) or 3) then
		Notify(src, 'Cargo insuficiente na facção para realizar saques.', 'error')
		return
	end

	local dados = GetDadosEmpresa(empresaKey)
	local saldoEmpresaAtual = math.floor(tonumber(dados.saldo_empresa) or 0)
	local saldoClienteAtual = math.floor(tonumber(dados.saldo_cliente) or 0)
	local saldoAtual = saldoEmpresaAtual + saldoClienteAtual
	local totalLavadoAtual = math.floor(tonumber(dados.total_lavado) or 0)
	if saldoAtual <= 0 then
		Notify(src, 'Nao ha saldo disponivel para saque.', 'error')
		return
	end

	local valorSaque = 0
	if tipoSaque == 'empresa' then
		valorSaque = saldoEmpresaAtual
	elseif tipoSaque == 'cliente' then
		valorSaque = saldoClienteAtual
	end

	if valorSaque <= 0 then
		Notify(src, 'Nao ha saldo suficiente nesta conta para saque.', 'error')
		return
	end

	local dinheiroLimpoItem = (Config and Config.CleanMoneyItem) or 'money'
	if not exports.ox_inventory:AddItem(src, dinheiroLimpoItem, valorSaque) then
		Notify(src, 'Falha ao adicionar dinheiro limpo ao inventario.', 'error')
		return
	end

	local novoSaldoEmpresa = saldoEmpresaAtual
	local novoSaldoCliente = saldoClienteAtual
	if tipoSaque == 'empresa' then
		novoSaldoEmpresa = 0
	elseif tipoSaque == 'cliente' then
		novoSaldoCliente = 0
	end

	local novoSaldo = novoSaldoEmpresa + novoSaldoCliente
	local novoTotalLavado = totalLavadoAtual + valorSaque

	local relatorioAtual = type(dados.ultimo_relatorio) == 'table' and dados.ultimo_relatorio or {}
	if novoSaldo <= 0 then
		relatorioAtual.funcionarios = {}
		relatorioAtual.tempo_fim_epoch = 0
	end

	local salvou = SalvarSaldoEmpresa(
		empresaKey,
		novoSaldo,
		relatorioAtual,
		nil,
		dados.tempo_fim,
		novoTotalLavado,
		novoSaldoEmpresa,
		novoSaldoCliente
	)
	if not salvou then
		exports.ox_inventory:RemoveItem(src, dinheiroLimpoItem, valorSaque)
		Notify(src, 'Falha ao atualizar saldo da empresa no banco.', 'error')
		return
	end

	Notify(src, ('%s realizado com sucesso: R$ %d.'):format(descricao, valorSaque), 'success')
end

RegisterNetEvent('wpp_lavagem_fiscal:server:SacarCaixaEmpresa', function(empresaId)
	SacarParteCofre(source, tostring(empresaId or ''), 'empresa', 'Saque do Caixa da Empresa')
end)

RegisterNetEvent('wpp_lavagem_fiscal:server:SacarDividendosCliente', function(empresaId)
	SacarParteCofre(source, tostring(empresaId or ''), 'cliente', 'Saque de Dividendos')
end)

RegisterNetEvent('wpp_lavagem_fiscal:server:DepositarCofre', function(empresaId, valorInformado)
	local src = source
	local empresaKey = tostring(empresaId or '')
	local empresaConfig = Config.Empresas and Config.Empresas[empresaKey]

	if not empresaConfig then
		Notify(src, 'Empresa invalida para deposito.', 'error')
		return
	end

	if GetResourceState('ox_inventory') ~= 'started' then
		Notify(src, 'ox_inventory nao esta iniciado.', 'error')
		return
	end

	if not EstaPertoDoCofre(src, empresaConfig.cofre) then
		Notify(src, 'Voce precisa estar no cofre da empresa para depositar.', 'error')
		return
	end

	local gangPermitido = GetEmpresagangPermitido(empresaKey, empresaConfig)
	local gangName = GetPlayergangData(src)
	if gangName ~= gangPermitido then
		Notify(src, 'Seu emprego nao tem permissao para usar este cofre.', 'error')
		return
	end

	local valor = math.floor(tonumber(valorInformado) or 0)
	local minimo, maximo = GetLimitesDeposito(empresaKey)
	if valor < minimo or valor > maximo then
		print(('[%s][AVISO] Deposito bloqueado por limite invalido | src=%s empresa=%s valor=%s min=%s max=%s'):format(
			RESOURCE_NAME,
			tostring(src),
			tostring(empresaKey),
			tostring(valorInformado),
			tostring(minimo),
			tostring(maximo)
		))
		Notify(src, ('Valor invalido. Permitido entre R$ %d e R$ %d.'):format(minimo, maximo), 'error')
		return
	end

	-- CONFIGURACAO PARA DEVS:
	-- Ajuste aqui o item de dinheiro sujo usado no seu servidor.
	-- Exemplo padrao: 'black_money'.
	local dirtyMoneyItem = (Config and Config.DirtyMoneyItem) or 'black_money'

	local quantidadeDisponivel = exports.ox_inventory:Search(src, 'count', dirtyMoneyItem) or 0
	if quantidadeDisponivel < valor then
		Notify(src, 'Voce nao possui dinheiro sujo suficiente.', 'error')
		return
	end

	-- ACAO OBRIGATORIA:
	-- A REMOCAO do item sujo acontece PRIMEIRO; somente depois o saldo do cofre e atualizado.
	local removeu = exports.ox_inventory:RemoveItem(src, dirtyMoneyItem, valor)
	if not removeu then
		Notify(src, 'Falha ao remover o dinheiro sujo do inventario.', 'error')
		return
	end

	local dadosAtuais = GetDadosEmpresa(empresaKey)
	local saldoEmpresaAtual = math.floor(tonumber(dadosAtuais.saldo_empresa) or 0)
	local saldoClienteAtual = math.floor(tonumber(dadosAtuais.saldo_cliente) or 0)
	local saldoAtual = saldoEmpresaAtual + saldoClienteAtual
	local tempoFimAtual = tonumber(dadosAtuais.tempo_fim) or 0

	local taxaEmpresa = tonumber(Config.TaxaEmpresa) or 0.25
	if taxaEmpresa < 0 then
		taxaEmpresa = 0
	elseif taxaEmpresa > 1 then
		taxaEmpresa = 1
	end

	local valorEmpresa = math.floor(valor * taxaEmpresa)
	local valorCliente = valor - valorEmpresa
	local novoSaldoEmpresa = saldoEmpresaAtual + valorEmpresa
	local novoSaldoCliente = saldoClienteAtual + valorCliente
	local novoSaldo = novoSaldoEmpresa + novoSaldoCliente

	-- Regra de negócio: 900s (15min) para cada R$ 5.000.
	local tempoAdicional = math.floor(valor / 5000) * 900
	if tempoAdicional < 900 then
		tempoAdicional = 900
	end

	local agora = os.time()
	local novoTempoFim = 0
	if saldoAtual <= 0 or tempoFimAtual <= agora then
		novoTempoFim = agora + tempoAdicional
	else
		novoTempoFim = tempoFimAtual + tempoAdicional
	end

	local relatorioAtual = type(dadosAtuais.ultimo_relatorio) == 'table' and dadosAtuais.ultimo_relatorio or {}
	relatorioAtual.funcionarios = {}
	relatorioAtual.tempo_fim_epoch = novoTempoFim

	local salvou = SalvarSaldoEmpresa(
		empresaKey,
		novoSaldo,
		relatorioAtual,
		nil,
		novoTempoFim,
		tonumber(dadosAtuais.total_lavado) or 0,
		novoSaldoEmpresa,
		novoSaldoCliente
	)
	if not salvou then
		-- Reembolso preventivo em caso de falha no banco.
		exports.ox_inventory:AddItem(src, dirtyMoneyItem, valor)
		Notify(src, 'Falha ao atualizar o saldo no banco de dados.', 'error')
		return
	end

	Notify(src, ('R$ %d depositado no cofre da empresa.'):format(valor), 'success')
end)

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

-- [CONFIGURAÇÃO DE DISPATCH] - Dono do servidor: Se você utiliza ps-dispatch, cd_dispatch ou outro sistema de chamados policiais, substitua o código dentro desta função pelo export do seu script.
local function SendPoliceAlert(nomeEmpresa, coordenadas)
	-- Implementação padrão sem dependência externa de dispatch.
	-- Notifica apenas gangs de segurança pública com mensagem genérica.
	for _, playerId in ipairs(GetPlayers()) do
		local target = tonumber(playerId)
		local gangName = GetgangName(target)

		if IsPolicegang(gangName) then
			Notify(target, ('⚠️ Inconsistência Fiscal Detectada na empresa: %s'):format(nomeEmpresa), 'error')
			TriggerClientEvent('wpp_lavagem_fiscal:client:AlertaFiscal', target, {
				empresaId = nomeEmpresa,
				coords = {
					x = coordenadas.x,
					y = coordenadas.y,
					z = coordenadas.z
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

	if not IsJogadorDonoDaEmpresa(src, empresaKey) then
		Notify(src, 'Apenas o dono deste local pode operar o cofre fiscal.', 'error')
		return
	end

	-- Regra operacional do cofre físico:
	-- qualquer membro da gangue dona da empresa pode depositar, sem trava por grade.
	local gangPermitido = GetEmpresagangPermitido(empresaKey, empresaConfig)
	local gangName = GetPlayergangData(src)
	if gangName ~= gangPermitido then
		Notify(src, 'Seu emprego nao tem permissao para usar este cofre.', 'error')
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
	local citizenIdExecutor = GetPlayerCitizenId(src) or 'desconhecido'
	local nomeExecutor = GetPlayerNomeExato(src)
	local timestampOperacao = os.date('%Y-%m-%d %H:%M:%S')

	local dadosAtuais = GetDadosEmpresa(empresaKey)
	-- Persistência:
	-- soma o novo valor da empresa ao saldo existente e salva um relatório completo
	-- da operação (json) para auditoria/admin.
	local novoSaldo = (tonumber(dadosAtuais.saldo) or 0) + valorEmpresa
	local relatorioCompleto = {
		citizenid = citizenIdExecutor,
		nome_jogador = nomeExecutor,
		valor_lavado = valor,
		timestamp = timestampOperacao,
		funcionarios_fantasmas = relatorioFuncionarios,
		data = timestampOperacao,
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
		SendPoliceAlert(empresaKey, empresaConfig.cofre)
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
	RegistrarTabletFiscalUsavel()

	CreateThread(function()
		Wait(500)
		local oxState = GetResourceState('ox_inventory')
		print(('[%s][DEBUG] Registro do item tablet_fiscal finalizado. ox_inventory=%s | framework=%s'):format(
			RESOURCE_NAME,
			tostring(oxState),
			tostring(frameworkText)
		))
	end)
end)

lib.addCommand('testartablet', { help = 'Forçar abertura do tablet' }, function(source)
	TriggerClientEvent('wpp_lavagem:abrirTablet', source)
end)
