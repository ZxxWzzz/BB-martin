function updateHistory(trades) {
    const body = document.getElementById('history-body');
    const noHistory = document.getElementById('no-history');

    if (!trades || trades.length === 0) {
        body.innerHTML = '';
        noHistory.style.display = 'block';
        return;
    }

    noHistory.style.display = 'none';

    // Show newest first
    const sorted = [...trades].reverse();

    body.innerHTML = sorted.map(t => {
        const cls = t.profit > 0 ? 'win' : 'loss';
        const dir = t.direction === 'BUY' ? '多' : '空';
        const duration = formatDuration(t.duration_sec);
        const reason = formatReason(t.close_reason);
        const time = t.close_time || '';

        return `<tr class="${cls}">
            <td>${t.cycle_id}</td>
            <td>${dir}</td>
            <td>${t.layers_used}</td>
            <td>${t.profit >= 0 ? '+' : ''}${t.profit.toFixed(2)}</td>
            <td>${reason}</td>
            <td>${duration}</td>
            <td>${time}</td>
        </tr>`;
    }).join('');
}

function formatDuration(sec) {
    if (!sec) return '--';
    if (sec < 60) return sec + 's';
    if (sec < 3600) return Math.floor(sec / 60) + 'm';
    return Math.floor(sec / 3600) + 'h' + Math.floor((sec % 3600) / 60) + 'm';
}

function formatReason(reason) {
    if (!reason) return '--';
    const map = {
        'TP_MONEY': '达标',
        'TP_MIDDLE': '回中轨',
    };
    return map[reason] || reason;
}
