const CIRCUMFERENCE = 2 * Math.PI * 40; // r=40

function updateGauge(circleId, labelId, value, maxValue) {
    const circle = document.getElementById(circleId);
    const label = document.getElementById(labelId);
    if (!circle || !label) return;

    const pct = Math.min(value / maxValue, 1);
    const offset = CIRCUMFERENCE * (1 - pct);
    circle.style.strokeDashoffset = offset;

    // Color based on severity
    let color;
    if (pct < 0.5) color = '#00d26a';      // green
    else if (pct < 0.75) color = '#ffa502'; // yellow
    else color = '#ff4757';                  // red

    circle.style.stroke = color;
    label.textContent = value.toFixed(1) + '%';
    label.style.color = color;
}
