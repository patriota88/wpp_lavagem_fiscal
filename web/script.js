const app = document.getElementById('app');
const empresaNomeEl = document.getElementById('empresaNome');
const saldoEmpresaEl = document.getElementById('saldoEmpresa');
const saldoClienteEl = document.getElementById('saldoCliente');
const totalLavadoEl = document.getElementById('totalLavado');
const tempoRestanteEl = document.getElementById('tempoRestante');
const tableBodyEl = document.getElementById('funcionariosTableBody');
const withdrawCompanyButtonEl = document.getElementById('withdrawCompanyButton');
const withdrawDividendButtonEl = document.getElementById('withdrawDividendButton');
const closeButtonEl = document.getElementById('closeButton');

const state = {
	empresaId: null,
	saldo: 0,
	saldoEmpresa: 0,
	saldoCliente: 0,
	totalLavado: 0,
	tempoRestante: 0,
	ultimoRelatorio: {}
};

let countdownInterval = null;
let isWithdrawInFlight = false;

function formatCurrency(value) {
	const safe = Number.isFinite(Number(value)) ? Number(value) : 0;
	return safe.toLocaleString('pt-BR', {
		style: 'currency',
		currency: 'BRL',
		minimumFractionDigits: 0,
		maximumFractionDigits: 0
	});
}

function buildRows(funcionarios) {
	if (!Array.isArray(funcionarios) || funcionarios.length === 0) {
		return '<tr><td colspan="2" class="empty-row">Sem dados no momento.</td></tr>';
	}

	return funcionarios
		.map((item) => {
			const nome = String(item?.nome ?? 'Sem Nome');
			const valor = formatCurrency(item?.valor ?? 0);
			return `<tr><td>${nome}</td><td class="money-cell">${valor}</td></tr>`;
		})
		.join('');
}

function formatDuration(seconds) {
	const safe = Math.max(0, Math.floor(Number(seconds) || 0));
	const hours = Math.floor(safe / 3600);
	const minutes = Math.floor((safe % 3600) / 60);
	const secs = safe % 60;

	if (hours > 0) {
		return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
	}

	return `${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
}

function stopCountdown() {
	if (countdownInterval) {
		clearInterval(countdownInterval);
		countdownInterval = null;
	}
}

function startCountdown() {
	stopCountdown();

	countdownInterval = setInterval(() => {
		if (state.tempoRestante > 0) {
			state.tempoRestante -= 1;
			tempoRestanteEl.textContent = formatDuration(state.tempoRestante);
			updateWithdrawAvailability();
			if (state.tempoRestante <= 0) {
				state.tempoRestante = 0;
				tempoRestanteEl.textContent = '00:00';
			}
		}
	}, 1000);
}

function updateWithdrawAvailability() {
	if (isWithdrawInFlight) {
		return;
	}

	const bloqueadoPorTempo = state.tempoRestante > 0;
	withdrawCompanyButtonEl.disabled = bloqueadoPorTempo || state.saldoEmpresa <= 0;
	withdrawDividendButtonEl.disabled = bloqueadoPorTempo || state.saldoCliente <= 0;
}

function renderDashboard() {
	empresaNomeEl.textContent = state.empresaId ?? 'Empresa';
	saldoEmpresaEl.textContent = formatCurrency(state.saldoEmpresa);
	saldoClienteEl.textContent = formatCurrency(state.saldoCliente);
	totalLavadoEl.textContent = formatCurrency(state.totalLavado);
	tempoRestanteEl.textContent = formatDuration(state.tempoRestante);

	const funcionarios = state.ultimoRelatorio?.funcionarios ?? [];
	tableBodyEl.innerHTML = buildRows(funcionarios);
	updateWithdrawAvailability();
}

function openDashboard(payload) {
	state.empresaId = payload?.empresaId ?? null;
	state.saldo = Number(payload?.saldo ?? 0);
	state.saldoEmpresa = Number(payload?.saldoEmpresa ?? payload?.saldo_empresa ?? 0);
	state.saldoCliente = Number(payload?.saldoCliente ?? payload?.saldo_cliente ?? 0);
	state.totalLavado = Number(payload?.totalLavado ?? payload?.total_lavado ?? state.totalLavado ?? 0);
	state.tempoRestante = Number(payload?.tempoRestante ?? payload?.tempo_restante ?? state.tempoRestante ?? 0);
	state.ultimoRelatorio = payload?.ultimoRelatorio ?? payload?.ultimo_relatorio ?? {};

	renderDashboard();
	startCountdown();
	app.classList.remove('hidden');
	app.setAttribute('aria-hidden', 'false');
}

function closeDashboard() {
	stopCountdown();
	app.classList.add('hidden');
	app.setAttribute('aria-hidden', 'true');
}

/*
  LOGICA DE COMUNICACAO COM LUA:
  - Este helper envia chamadas NUI -> client/main.lua via fetch.
  - "endpoint" precisa existir como RegisterNUICallback no client.
*/
async function postToLua(endpoint, payload = {}) {
	const resourceName = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'wpp_lavagem_fiscal';

	const response = await fetch(`https://${resourceName}/${endpoint}`, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json; charset=UTF-8'
		},
		body: JSON.stringify(payload)
	});

	return response.json().catch(() => ({}));
}

withdrawCompanyButtonEl.addEventListener('click', async () => {
	if (!state.empresaId || state.tempoRestante > 0 || state.saldoEmpresa <= 0) return;

	isWithdrawInFlight = true;
	withdrawCompanyButtonEl.disabled = true;
	withdrawDividendButtonEl.disabled = true;
	await postToLua('requestCompanyWithdraw', {
		empresaId: state.empresaId
	});
	isWithdrawInFlight = false;
	updateWithdrawAvailability();
});

withdrawDividendButtonEl.addEventListener('click', async () => {
	if (!state.empresaId || state.tempoRestante > 0 || state.saldoCliente <= 0) return;

	isWithdrawInFlight = true;
	withdrawCompanyButtonEl.disabled = true;
	withdrawDividendButtonEl.disabled = true;
	await postToLua('requestDividendWithdraw', {
		empresaId: state.empresaId
	});
	isWithdrawInFlight = false;
	updateWithdrawAvailability();
});

closeButtonEl.addEventListener('click', async () => {
	await postToLua('closeTablet', {});
});

window.addEventListener('keydown', async (event) => {
	if (event.key === 'Escape') {
		await postToLua('closeTablet', {});
	}
});

/*
  LOGICA DE COMUNICACAO COM LUA:
  - Este listener recebe eventos enviados por SendNUIMessage no client Lua.
  - action esperado: openTabletFiscal, updateTabletFiscal, closeTabletFiscal.
*/
window.addEventListener('message', (event) => {
	const data = event.data || {};

	if (data.action === 'openTabletFiscal' || data.action === 'updateTabletFiscal') {
		openDashboard(data);
		return;
	}

	if (data.action === 'closeTabletFiscal') {
		closeDashboard();
	}
});
