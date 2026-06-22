let chart = null;
let equitySeries = null;
let balanceSeries = null;

function initEquityChart(data) {
    const container = document.getElementById('equity-chart');
    if (!container) return;

    chart = LightweightCharts.createChart(container, {
        width: container.clientWidth,
        height: 220,
        layout: {
            background: { type: 'solid', color: 'transparent' },
            textColor: '#8899aa',
            fontSize: 11,
        },
        grid: {
            vertLines: { color: 'rgba(42,58,94,0.5)' },
            horzLines: { color: 'rgba(42,58,94,0.5)' },
        },
        rightPriceScale: {
            borderColor: '#2a3a5e',
        },
        timeScale: {
            borderColor: '#2a3a5e',
            timeVisible: true,
        },
        crosshair: {
            mode: LightweightCharts.CrosshairMode.Magnet,
        },
    });

    equitySeries = chart.addAreaSeries({
        lineColor: '#4ecdc4',
        topColor: 'rgba(78,205,196,0.3)',
        bottomColor: 'rgba(78,205,196,0.01)',
        lineWidth: 2,
        title: '净值',
    });

    balanceSeries = chart.addLineSeries({
        color: '#ffa502',
        lineWidth: 1,
        lineStyle: LightweightCharts.LineStyle.Dashed,
        title: '余额',
    });

    if (data.length > 0) {
        const eqData = data.map(p => ({
            time: parseTime(p.t),
            value: p.eq,
        }));
        const balData = data.map(p => ({
            time: parseTime(p.t),
            value: p.bal,
        }));
        equitySeries.setData(eqData);
        balanceSeries.setData(balData);
    }

    // Resize
    const ro = new ResizeObserver(() => {
        chart.applyOptions({ width: container.clientWidth });
    });
    ro.observe(container);
}

function appendEquityPoint(eq, bal) {
    if (!equitySeries) return;
    const now = Math.floor(Date.now() / 1000);
    equitySeries.update({ time: now, value: eq });
    balanceSeries.update({ time: now, value: bal });
}

function parseTime(timeStr) {
    // "2026.06.22 14:30:05" → unix timestamp
    const s = timeStr.replace(/\./g, '-');
    const d = new Date(s);
    return Math.floor(d.getTime() / 1000);
}
