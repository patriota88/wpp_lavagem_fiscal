const app = document.getElementById('app');
const empresaNomeEl = document.getElementById('empresaNome');
const saldoValorEl = document.getElementById('saldoValor');
const tableBodyEl = document.getElementById('funcionariosTableBody');
const withdrawButtonEl = document.getElementById('withdrawButton');
const closeButtonEl = document.getElementById('closeButton');

const state = {
	empresaId: null,
	saldo: 0,
	ultimoRelatorio: {}
};

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

function renderDashboard() {
	empresaNomeEl.textContent = state.empresaId ?? 'Empresa';
	saldoValorEl.textContent = formatCurrency(state.saldo);

	const funcionarios = state.ultimoRelatorio?.funcionarios ?? [];
	tableBodyEl.innerHTML = buildRows(funcionarios);
}

function openDashboard(payload) {
	state.empresaId = payload?.empresaId ?? null;
	state.saldo = Number(payload?.saldo ?? 0);
	state.ultimoRelatorio = payload?.ultimoRelatorio ?? {};

	renderDashboard();
	app.classList.remove('hidden');
	app.setAttribute('aria-hidden', 'false');
}

function closeDashboard() {
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

withdrawButtonEl.addEventListener('click', async () => {
	if (!state.empresaId) return;

	withdrawButtonEl.disabled = true;
	await postToLua('requestDividendWithdraw', {
		empresaId: state.empresaId
	});
	withdrawButtonEl.disabled = false;
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
