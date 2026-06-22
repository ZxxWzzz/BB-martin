let ws = null;
let reconnectTimer = null;
let reconnectDelay = 1000;

function connectWebSocket() {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${protocol}//${location.host}/ws/state`);

    ws.onopen = () => {
        document.getElementById('ws-status').className = 'ws-dot connected';
        reconnectDelay = 1000;
        addEvent('WebSocket 已连接');
    };

    ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'state') {
            updateDashboard(msg.data);
        }
    };

    ws.onclose = () => {
        document.getElementById('ws-status').className = 'ws-dot disconnected';
        scheduleReconnect();
    };

    ws.onerror = () => {
        ws.close();
    };
}

function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        reconnectDelay = Math.min(reconnectDelay * 1.5, 10000);
        connectWebSocket();
    }, reconnectDelay);
}

function updateDashboard(state) {
    if (!state) return;

    // Account
    if (state.account) {
        document.getElementById('balance').textContent = '$' + state.account.balance.toFixed(2);
        document.getElementById('equity').textContent = '$' + state.account.equity.toFixed(2);
        document.getElementById('margin').textContent = '$' + state.account.margin.toFixed(2);
    }

    // Cycle
    if (state.cycle) {
        const c = state.cycle;
        const badge = document.getElementById('cycle-badge');
        badge.textContent = c.direction_label;
        badge.className = 'badge ' + (c.direction === 1 ? 'buy' : c.direction === -1 ? 'sell' : 'idle');

        document.getElementById('direction').textContent = c.direction_label;
        document.getElementById('layers').textContent = `${c.layer_count}/${c.max_layers}`;
        document.getElementById('layer-fill').style.width = `${(c.layer_count / c.max_layers) * 100}%`;
        document.getElementById('total-lots').textContent = c.total_lots.toFixed(2);

        const pnlEl = document.getElementById('floating-pnl');
        pnlEl.textContent = '$' + c.floating_pnl.toFixed(2);
        pnlEl.className = 'value ' + (c.floating_pnl >= 0 ? 'profit' : 'loss');

        document.getElementById('tp-target').textContent = '$' + c.tp_target.toFixed(2);
        document.getElementById('grid-spacing').textContent = c.grid_spacing;
    }

    // Positions
    if (state.positions) {
        const body = document.getElementById('positions-body');
        const noPos = document.getElementById('no-positions');
        if (state.positions.length === 0) {
            body.innerHTML = '';
            noPos.style.display = 'block';
        } else {
            noPos.style.display = 'none';
            body.innerHTML = state.positions.map((p, i) => {
                const cls = p.profit >= 0 ? 'profit' : 'loss';
                return `<tr><td>${i + 1}</td><td>${p.lots}</td><td>${p.open_price}</td><td class="${cls}">${p.profit.toFixed(2)}</td></tr>`;
            }).join('');
        }
    }

    // Risk
    if (state.risk) {
        updateGauge('gauge-dd', 'dd-val', state.risk.drawdown_pct, 15);
        updateGauge('gauge-daily', 'daily-val', state.risk.daily_loss_pct, 5);
        updateGauge('gauge-float', 'float-val', state.risk.float_loss_pct, 10);
    }

    // Indicators
    if (state.indicators) {
        const ind = state.indicators;
        document.getElementById('bb-upper').textContent = ind.bb_upper;
        document.getElementById('bb-middle').textContent = ind.bb_middle;
        document.getElementById('bb-lower').textContent = ind.bb_lower;
        document.getElementById('rsi').textContent = ind.rsi.toFixed(1);
        document.getElementById('spread').textContent = ind.spread;
        document.getElementById('bid-ask').textContent = `${ind.bid} / ${ind.ask}`;
    }

    // Symbol from indicators
    if (state.timestamp) {
        document.getElementById('symbol').textContent = 'XAUUSD M1';
    }
}

function addEvent(text, type = '') {
    const log = document.getElementById('event-log');
    const div = document.createElement('div');
    div.className = 'event ' + type;
    div.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
    log.prepend(div);
    while (log.children.length > 50) log.removeChild(log.lastChild);
}

// Initial data load
async function loadInitialData() {
    try {
        const [statsRes, tradesRes, equityRes] = await Promise.all([
            fetch('/api/stats'),
            fetch('/api/trades?limit=200'),
            fetch('/api/equity?limit=1440')
        ]);
        const stats = await statsRes.json();
        const trades = await tradesRes.json();
        const equity = await equityRes.json();

        updateStats(stats);
        updateHistory(trades.trades || []);
        initEquityChart(equity.data || []);
    } catch (e) {
        addEvent('加载初始数据失败: ' + e.message, 'error');
    }
}

function updateStats(s) {
    document.getElementById('stat-total').textContent = s.total_cycles;
    document.getElementById('stat-winrate').textContent = s.win_rate.toFixed(1) + '%';
    document.getElementById('stat-pf').textContent = s.profit_factor;
    document.getElementById('stat-profit').textContent = '$' + s.total_profit.toFixed(2);
    document.getElementById('stat-maxdd').textContent = s.max_drawdown.toFixed(1) + '%';
    document.getElementById('stat-layers').textContent = s.avg_layers.toFixed(1);
    document.getElementById('stat-best').textContent = '$' + s.best_trade.toFixed(2);
    document.getElementById('stat-worst').textContent = '$' + s.worst_trade.toFixed(2);
}

// Boot
document.addEventListener('DOMContentLoaded', () => {
    loadInitialData();
    connectWebSocket();
});
