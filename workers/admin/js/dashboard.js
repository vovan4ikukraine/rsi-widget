/**
 * Dashboard functionality
 */

let cumulativeChart = null;
let dailyChart = null;
let allGrowthData = null; // Store all data
let currentMonthIndex1 = 0; // Current month index for cumulative chart (0 = most recent month)
let currentMonthIndex2 = 0; // Current month index for daily chart (0 = most recent month)

document.addEventListener('DOMContentLoaded', () => {
    const apiKeyInput = document.getElementById('apiKeyInput');
    const connectBtn = document.getElementById('connectBtn');
    const loading = document.getElementById('loading');
    const error = document.getElementById('error');
    const dashboardContent = document.getElementById('dashboardContent');

    // Navigation buttons
    const prevMonthBtn = document.getElementById('prevMonthBtn');
    const nextMonthBtn = document.getElementById('nextMonthBtn');
    const prevMonthBtn2 = document.getElementById('prevMonthBtn2');
    const nextMonthBtn2 = document.getElementById('nextMonthBtn2');
    const currentMonthLabel = document.getElementById('currentMonthLabel');
    const currentMonthLabel2 = document.getElementById('currentMonthLabel2');

    // Navigation event handlers for cumulative chart
    prevMonthBtn?.addEventListener('click', () => {
        const months = getAvailableMonths();
        if (currentMonthIndex1 < months.length - 1) {
            currentMonthIndex1++;
            updateCumulativeChart();
        }
    });

    nextMonthBtn?.addEventListener('click', () => {
        if (currentMonthIndex1 > 0) {
            currentMonthIndex1--;
            updateCumulativeChart();
        }
    });

    // Navigation event handlers for daily chart
    prevMonthBtn2?.addEventListener('click', () => {
        const months = getAvailableMonths();
        if (currentMonthIndex2 < months.length - 1) {
            currentMonthIndex2++;
            updateDailyChart();
        }
    });

    nextMonthBtn2?.addEventListener('click', () => {
        if (currentMonthIndex2 > 0) {
            currentMonthIndex2--;
            updateDailyChart();
        }
    });

    // Load saved API key
    if (adminAPI.getApiKey()) {
        apiKeyInput.value = adminAPI.getApiKey();
        adminAPI.updateStatusIndicator();
        loadDashboard();
    }

    connectBtn.addEventListener('click', () => {
        const apiKey = apiKeyInput.value.trim();
        if (!apiKey) {
            alert('Please enter an API key');
            return;
        }

        adminAPI.setApiKey(apiKey);
        loadDashboard();
    });

    async function loadDashboard() {
        loading.style.display = 'block';
        error.style.display = 'none';
        dashboardContent.style.display = 'none';

        try {
            const stats = await adminAPI.getStats();

            // Update user stats
            document.getElementById('totalUsers').textContent = stats.users?.total || 0;
            document.getElementById('active24h').textContent = stats.users?.active24h || 0;
            document.getElementById('active7d').textContent = stats.users?.active7d || 0;

            // Update device stats
            document.getElementById('totalDevices').textContent = stats.devices?.total || 0;
            document.getElementById('activeDevices').textContent = stats.devices?.active || 0;

            // Update alert stats
            document.getElementById('activeAlerts').textContent = stats.alerts?.active || 0;

            // Update platform chart
            document.getElementById('iosCount').textContent = stats.devices?.ios || 0;
            document.getElementById('androidCount').textContent = stats.devices?.android || 0;

            // Update indicator chart (separated by custom and watchlist)
            const byIndicatorCustom = stats.alerts?.byIndicatorCustom || {};
            const byIndicatorWatchlist = stats.alerts?.byIndicatorWatchlist || {};
            document.getElementById('rsiCustomCount').textContent = byIndicatorCustom.rsi || 0;
            document.getElementById('rsiWatchlistCount').textContent = byIndicatorWatchlist.rsi || 0;
            document.getElementById('stochCustomCount').textContent = byIndicatorCustom.stoch || 0;
            document.getElementById('stochWatchlistCount').textContent = byIndicatorWatchlist.stoch || 0;
            document.getElementById('williamsCustomCount').textContent = byIndicatorCustom.williams || 0;
            document.getElementById('williamsWatchlistCount').textContent = byIndicatorWatchlist.williams || 0;

            // Store growth data and initialize charts
            if (stats.userGrowth && stats.userGrowth.dates && stats.userGrowth.dates.length > 0) {
                allGrowthData = stats.userGrowth;
                currentMonthIndex1 = 0; // Start with most recent month
                currentMonthIndex2 = 0; // Start with most recent month
                updateCumulativeChart();
                updateDailyChart();
            } else {
                console.warn('No user growth data available');
                showNoDataMessage('cumulativeGrowthChart');
                showNoDataMessage('dailyGrowthChart');
            }

            loading.style.display = 'none';
            dashboardContent.style.display = 'block';
        } catch (err) {
            loading.style.display = 'none';
            error.style.display = 'block';
            error.textContent = `Error: ${err.message}`;
            console.error('Dashboard load error:', err);
        }
    }

    function getAvailableMonths() {
        if (!allGrowthData || !allGrowthData.dates || allGrowthData.dates.length === 0) {
            return [];
        }

        const months = new Set();
        allGrowthData.dates.forEach(dateStr => {
            const date = new Date(dateStr + 'T00:00:00');
            if (!isNaN(date.getTime())) {
                const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
                months.add(monthKey);
            }
        });

        // Sort months descending (most recent first)
        return Array.from(months).sort().reverse();
    }

    function getCurrentMonthData(monthIndex) {
        if (!allGrowthData || !allGrowthData.dates || allGrowthData.dates.length === 0) {
            return { dates: [], cumulativeCounts: [], dailyCounts: [] };
        }

        const months = getAvailableMonths();
        if (months.length === 0 || monthIndex >= months.length) {
            return { dates: [], cumulativeCounts: [], dailyCounts: [] };
        }

        const selectedMonth = months[monthIndex];
        const [year, month] = selectedMonth.split('-').map(Number);

        const filteredIndices = [];
        allGrowthData.dates.forEach((dateStr, index) => {
            const date = new Date(dateStr + 'T00:00:00');
            if (!isNaN(date.getTime()) && 
                date.getFullYear() === year && 
                date.getMonth() + 1 === month) {
                filteredIndices.push(index);
            }
        });

        return {
            dates: filteredIndices.map(i => allGrowthData.dates[i]),
            cumulativeCounts: filteredIndices.map(i => allGrowthData.cumulativeCounts[i]),
            dailyCounts: filteredIndices.map(i => allGrowthData.dailyCounts[i]),
            year,
            month,
        };
    }

    function getAllDaysInMonth(year, month) {
        // Get all days in the month
        const daysInMonth = new Date(year, month, 0).getDate();
        const days = [];
        for (let day = 1; day <= daysInMonth; day++) {
            const dateStr = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
            days.push(dateStr);
        }
        return days;
    }

    function fillMissingDays(data, year, month, isCumulative = false) {
        const allDays = getAllDaysInMonth(year, month);
        const dataMap = new Map();
        
        // Create a map of existing data for this month
        data.dates.forEach((date, index) => {
            dataMap.set(date, {
                cumulative: data.cumulativeCounts[index],
                daily: data.dailyCounts[index]
            });
        });

        // For cumulative chart: find the last cumulative value from previous months/days
        let initialCumulative = 0;
        if (isCumulative && allGrowthData && allGrowthData.dates && allGrowthData.cumulativeCounts && allGrowthData.dates.length > 0) {
            const firstDayOfMonth = `${year}-${String(month).padStart(2, '0')}-01`;
            // Find the last cumulative value before this month
            // allGrowthData.dates is sorted ascending, so we search from the end backwards
            for (let i = allGrowthData.dates.length - 1; i >= 0; i--) {
                if (allGrowthData.dates[i] < firstDayOfMonth) {
                    initialCumulative = allGrowthData.cumulativeCounts[i];
                    break;
                }
            }
        }

        // Fill in all days
        const filledDates = [];
        const filledCumulative = [];
        const filledDaily = [];
        let lastCumulativeInMonth = initialCumulative;

        allDays.forEach(dayDate => {
            filledDates.push(dayDate);
            if (dataMap.has(dayDate)) {
                const dayData = dataMap.get(dayDate);
                filledCumulative.push(dayData.cumulative);
                filledDaily.push(dayData.daily);
                lastCumulativeInMonth = dayData.cumulative; // Update for next missing days
            } else {
                // For missing days
                filledCumulative.push(lastCumulativeInMonth);
                filledDaily.push(0);
            }
        });

        return {
            dates: filledDates,
            cumulativeCounts: filledCumulative,
            dailyCounts: filledDaily,
        };
    }

    function updateCumulativeChart() {
        const canvas = document.getElementById('cumulativeGrowthChart');
        if (!canvas) {
            console.error('Cumulative chart canvas not found');
            return;
        }

        const months = getAvailableMonths();
        if (months.length === 0) {
            showNoDataMessage('cumulativeGrowthChart');
            return;
        }

        // Update label
        const selectedMonth = months[currentMonthIndex1];
        const [year, month] = selectedMonth.split('-').map(Number);
        const monthName = new Date(year, month - 1, 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
        if (currentMonthLabel) currentMonthLabel.textContent = monthName;
        if (prevMonthBtn) prevMonthBtn.disabled = currentMonthIndex1 >= months.length - 1;
        if (nextMonthBtn) nextMonthBtn.disabled = currentMonthIndex1 === 0;

        const monthData = getCurrentMonthData(currentMonthIndex1);
        if (monthData.dates.length === 0) {
            showNoDataMessage('cumulativeGrowthChart');
            return;
        }

        removeNoDataMessage(canvas);

        // Fill missing days (for cumulative chart, preserve values from previous months)
        const filledData = fillMissingDays(monthData, year, month, true);

        const ctx = canvas.getContext('2d');
        
        // Destroy existing chart if it exists
        if (cumulativeChart) {
            cumulativeChart.destroy();
        }

        // Format dates for display
        const formattedDates = filledData.dates.map(date => {
            const d = new Date(date + 'T00:00:00');
            if (isNaN(d.getTime())) return date;
            return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
        });

        cumulativeChart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: formattedDates,
                datasets: [{
                    label: 'Total Users',
                    data: filledData.cumulativeCounts,
                    borderColor: '#1976d2',
                    backgroundColor: 'rgba(25, 118, 210, 0.1)',
                    borderWidth: 2,
                    fill: true,
                    tension: 0.4,
                    pointRadius: 3,
                    pointHoverRadius: 5,
                    pointBackgroundColor: '#1976d2',
                    pointBorderColor: '#fff',
                    pointBorderWidth: 2,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                aspectRatio: 3,
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                    },
                    tooltip: {
                        mode: 'index',
                        intersect: false,
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true,
                        ticks: {
                            precision: 0,
                        },
                        title: {
                            display: true,
                            text: 'Total Users'
                        }
                    },
                    x: {
                        title: {
                            display: true,
                            text: 'Date'
                        }
                    }
                },
                interaction: {
                    mode: 'nearest',
                    axis: 'x',
                    intersect: false
                }
            }
        });
    }

    function updateDailyChart() {
        const canvas = document.getElementById('dailyGrowthChart');
        if (!canvas) {
            console.error('Daily chart canvas not found');
            return;
        }

        const months = getAvailableMonths();
        if (months.length === 0) {
            showNoDataMessage('dailyGrowthChart');
            return;
        }

        // Update label
        const selectedMonth = months[currentMonthIndex2];
        const [year, month] = selectedMonth.split('-').map(Number);
        const monthName = new Date(year, month - 1, 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
        if (currentMonthLabel2) currentMonthLabel2.textContent = monthName;
        if (prevMonthBtn2) prevMonthBtn2.disabled = currentMonthIndex2 >= months.length - 1;
        if (nextMonthBtn2) nextMonthBtn2.disabled = currentMonthIndex2 === 0;

        const monthData = getCurrentMonthData(currentMonthIndex2);
        if (monthData.dates.length === 0) {
            showNoDataMessage('dailyGrowthChart');
            return;
        }

        removeNoDataMessage(canvas);

        // Fill missing days with 0 (for daily chart)
        const filledData = fillMissingDays(monthData, year, month, false);

        const ctx = canvas.getContext('2d');
        
        // Destroy existing chart if it exists
        if (dailyChart) {
            dailyChart.destroy();
        }

        // Format dates for display
        const formattedDates = filledData.dates.map(date => {
            const d = new Date(date + 'T00:00:00');
            if (isNaN(d.getTime())) return date;
            return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
        });

        dailyChart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: formattedDates,
                datasets: [{
                    label: 'New Users',
                    data: filledData.dailyCounts,
                    borderColor: '#4caf50',
                    backgroundColor: 'rgba(76, 175, 80, 0.1)',
                    borderWidth: 2,
                    fill: true,
                    tension: 0.4,
                    pointRadius: 3,
                    pointHoverRadius: 5,
                    pointBackgroundColor: '#4caf50',
                    pointBorderColor: '#fff',
                    pointBorderWidth: 2,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                aspectRatio: 3,
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                    },
                    tooltip: {
                        mode: 'index',
                        intersect: false,
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true,
                        ticks: {
                            precision: 0,
                        },
                        title: {
                            display: true,
                            text: 'New Users Per Day'
                        }
                    },
                    x: {
                        title: {
                            display: true,
                            text: 'Date'
                        }
                    }
                },
                interaction: {
                    mode: 'nearest',
                    axis: 'x',
                    intersect: false
                }
            }
        });
    }

    function showNoDataMessage(canvasId) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) return;

        // Check if message already exists
        if (canvas.nextSibling && canvas.nextSibling.className === 'no-data-message') {
            return;
        }

        const noDataMsg = document.createElement('p');
        noDataMsg.className = 'no-data-message';
        noDataMsg.style.color = 'var(--text-secondary)';
        noDataMsg.style.padding = '20px';
        noDataMsg.style.textAlign = 'center';
        noDataMsg.textContent = 'No data available for selected period';
        canvas.parentElement.appendChild(noDataMsg);
    }

    function removeNoDataMessage(canvas) {
        const noDataMsg = canvas.nextSibling;
        if (noDataMsg && noDataMsg.className === 'no-data-message') {
            noDataMsg.remove();
        }
    }
});
