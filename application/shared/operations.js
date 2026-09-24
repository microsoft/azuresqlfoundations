(function () {
  "use strict";

  const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
  const number = new Intl.NumberFormat("en-US");
  const date = new Intl.DateTimeFormat("en-US", { year: "numeric", month: "short", day: "numeric" });

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, character => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  async function json(url, options) {
    const response = await fetch(url, options);
    const body = await response.json();
    if (!response.ok) throw new Error(body.error || "The request failed.");
    return body;
  }

  function showConnectionError(error) {
    let banner = document.getElementById("liveDataError");
    if (!banner) {
      banner = document.createElement("div");
      banner.id = "liveDataError";
      banner.style.cssText = "position:fixed;right:20px;bottom:20px;z-index:1000;background:#991b1b;color:white;padding:10px 14px;border-radius:6px;max-width:420px;font-size:13px;box-shadow:0 4px 16px #0003";
      document.body.appendChild(banner);
    }
    banner.textContent = `Live data unavailable: ${error.message}`;
  }

  function badgeClass(outcome) {
    if (["Approved", "PaidInFull", "Processed"].includes(outcome)) return "badge-green";
    if (["Active", "Pending"].includes(outcome)) return "badge-blue";
    if (["Denied", "Default", "Critical", "Failed"].includes(outcome)) return "badge-red";
    return "badge-amber";
  }

  function updateChart(id, labels, datasets) {
    const chart = window.Chart && Chart.getChart(id);
    if (!chart) return;
    chart.data.labels = labels;
    datasets.forEach((values, index) => { chart.data.datasets[index].data = values; });
    chart.update();
  }

  async function loadDashboard() {
    const data = await json("/api/operations/dashboard");
    const cards = document.querySelectorAll("#page-dashboard .kpi");
    const values = [
      ["Total Loans", number.format(data.summary.TotalLoans), "Live from LoanHistory"],
      ["Approved Loans", number.format(data.summary.ApprovedLoans), "Approved, active, or paid in full"],
      ["Total Approved", money.format(data.summary.TotalApproved), "Current historical portfolio"],
      ["Avg Default Rate", `${(Number(data.summary.AverageDefaultRate) * 100).toFixed(2)}%`, "Across loans with risk data"]
    ];
    cards.forEach((card, index) => {
      if (!values[index]) return;
      card.querySelector(".kpi-label").textContent = values[index][0];
      card.querySelector(".kpi-value").textContent = values[index][1];
      card.querySelector(".kpi-sub").textContent = values[index][2];
      const change = card.querySelector(".kpi-change");
      if (change) change.style.display = "none";
    });

    document.getElementById("dashRecentReviews").innerHTML = data.recentReviews.map(row => {
      const risk = Number(row.DebtToIncomeRatio) > 0.45 ? "High DTI" : "None";
      return `<tr><td class="text-mono text-bold">ZL-${String(row.LoanId).padStart(6, "0")}</td>` +
        `<td><strong>${escapeHtml(row.Applicant || "Unknown")}</strong></td><td>${escapeHtml(row.LoanType)}</td>` +
        `<td>${money.format(row.ApprovedAmount || 0)}</td><td>${escapeHtml(row.CreditScore)}</td>` +
        `<td>${risk === "None" ? '<span class="text-muted">—</span>' : `<span class="badge badge-amber">${risk}</span>`}</td>` +
        `<td><span class="badge ${badgeClass(row.LoanOutcome)}">${escapeHtml(row.LoanOutcome)}</span></td></tr>`;
    }).join("");

    const hours = Array.from({ length: 24 }, (_, index) => String(index).padStart(2, "0"));
    const byHour = new Map(data.hourlyTransactions.map(row => [Number(row.HourOfDay), Number(row.TransactionCount)]));
    updateChart("txnVolumeChart", hours, [hours.map((_hour, index) => byHour.get(index) || 0)]);
    updateChart("riskRegionChart", data.loansByRegion.map(row => row.Region), [data.loansByRegion.map(row => Number(row.LoanCount))]);
  }

  function setAccountDetail(account, transactions) {
    const card = document.getElementById("acctDetailCard");
    card.querySelector("h3").innerHTML = `Account Detail — <span class="text-mono">ZL-${String(account.LoanId).padStart(6, "0")}</span>`;
    const values = {
      Applicant: account.Applicant,
      "Loan Type": account.LoanType,
      "Approved Amount": money.format(account.ApprovedAmount || 0),
      "Current Balance": money.format(transactions[0]?.RunningBalance ?? account.ApprovedAmount ?? 0),
      "Interest Rate": `${Number(account.InterestRate || 0).toFixed(2)}% APR`,
      "Credit Score": account.CreditScore,
      "Days Past Due": Math.max(0, ...transactions.map(item => Number(item.DaysPastDue || 0))),
      Region: account.Region,
      Opened: date.format(new Date(account.ApplicationDate))
    };
    card.querySelectorAll(".detail-group").forEach(group => {
      const label = group.querySelector("label").textContent.trim();
      if (Object.hasOwn(values, label)) group.querySelector(".detail-val").textContent = values[label] ?? "—";
    });
    document.getElementById("acctTransactions").innerHTML = transactions.map(item =>
      `<tr><td>${date.format(new Date(item.TransactionDate))}</td><td>${escapeHtml(item.TransactionType)}</td>` +
      `<td>${money.format(item.Amount)}</td><td>${money.format(item.PrincipalComponent || 0)}</td>` +
      `<td>${money.format(item.InterestComponent || 0)}</td><td class="text-bold">${money.format(item.RunningBalance)}</td></tr>`
    ).join("") || '<tr><td colspan="6" class="text-muted">No transactions found.</td></tr>';
  }

  function enableAccountSearch() {
    const original = document.getElementById("acctSearchBtn");
    const button = original.cloneNode(true);
    original.replaceWith(button);
    button.addEventListener("click", async () => {
      button.disabled = true;
      try {
        const result = await json(`/api/operations/account?q=${encodeURIComponent(document.getElementById("acctSearch").value)}`);
        setAccountDetail(result.account, result.transactions);
        document.getElementById("acctDetailCard").scrollIntoView({ behavior: "smooth" });
      } catch (error) {
        showConnectionError(error);
      } finally {
        button.disabled = false;
      }
    });
  }

  async function loadRisk() {
    const data = await json("/api/operations/risk");
    document.getElementById("highRiskTable").innerHTML = data.loans.map(row =>
      `<tr><td class="text-mono text-bold">ZL-${String(row.LoanId).padStart(6, "0")}</td>` +
      `<td><strong>${escapeHtml(row.Applicant || "Unknown")}</strong></td><td>${escapeHtml(row.LoanType)}</td>` +
      `<td>${money.format(row.Balance || 0)}</td><td>${escapeHtml(row.DaysPastDue)}</td>` +
      `<td>${Number(row.DebtToIncomeRatio || 0).toFixed(2)}</td><td>${escapeHtml(row.Region || "Unknown")}</td>` +
      `<td><span class="badge ${badgeClass(row.RiskCategory)}">${escapeHtml(row.RiskCategory)}</span></td></tr>`
    ).join("") || '<tr><td colspan="8" class="text-muted">No elevated-risk loans found.</td></tr>';
  }

  async function loadBranches() {
    const data = await json("/api/operations/branches");
    document.getElementById("branchTable").innerHTML = data.branches.map(row =>
      `<tr><td><strong>${escapeHtml(row.Region)}</strong></td><td>${escapeHtml(row.Channel)}</td>` +
      `<td>${number.format(row.Applications)}</td><td>${number.format(row.Decisions)}</td>` +
      `<td><span class="badge badge-blue">${Number(row.DecisionRate || 0).toFixed(1)}%</span></td>` +
      `<td class="text-bold">${money.format(row.FundedAmount || 0)}</td><td>${money.format(row.AverageFunded || 0)}</td></tr>`
    ).join("") || '<tr><td colspan="7" class="text-muted">No application activity found.</td></tr>';

    const channels = [...new Set(data.branches.map(row => row.Channel))];
    const regions = [...new Set(data.branches.map(row => row.Region))];
    updateChart("channelChart", channels, [
      channels.map(channel => data.branches.filter(row => row.Channel === channel).reduce((sum, row) => sum + Number(row.Applications), 0)),
      channels.map(channel => data.branches.filter(row => row.Channel === channel).reduce((sum, row) => sum + Number(row.Decisions), 0))
    ]);
    updateChart("regionSummaryChart", regions, [
      regions.map(region => data.branches.filter(row => row.Region === region).reduce((sum, row) => sum + Number(row.Applications), 0))
    ]);
  }

  async function loadPayments() {
    const data = await json("/api/operations/payments");
    document.getElementById("paymentTable").innerHTML = data.payments.map(row => {
      const status = Number(row.DaysPastDue) > 0 ? "Late" : "Processed";
      return `<tr><td class="text-mono">PAY-${row.TransactionId}</td><td class="text-mono text-bold">ZL-${String(row.LoanId).padStart(6, "0")}</td>` +
        `<td><strong>${escapeHtml(row.Applicant || "Unknown")}</strong></td><td>${money.format(row.Amount)}</td>` +
        `<td>${money.format(row.PrincipalComponent || 0)}</td><td>${money.format(row.InterestComponent || 0)}</td>` +
        `<td>${escapeHtml(row.ProcessedBy)}</td><td><span class="badge ${badgeClass(status)}">${status}</span></td></tr>`;
    }).join("") || '<tr><td colspan="8" class="text-muted">No recent payments found.</td></tr>';
  }

  async function loadConfiguration() {
    const data = await json("/api/config");
    document.querySelectorAll("#page-settings .detail-group").forEach(group => {
      const label = group.querySelector("label")?.textContent.trim();
      const value = group.querySelector(".detail-val");
      if (!value) return;
      if (label === "Server") value.textContent = data.server;
      if (label === "Database") value.textContent = data.database;
      if (label === "Authentication") value.textContent = data.authentication;
    });
    const connectionLabel = document.querySelector(".header-live");
    if (connectionLabel) connectionLabel.innerHTML = `<span class="live-dot"></span> Connected to ${escapeHtml(data.database)}`;
  }

  enableAccountSearch();
  Promise.allSettled([loadDashboard(), loadRisk(), loadBranches(), loadPayments(), loadConfiguration()]).then(results => {
    const failed = results.find(result => result.status === "rejected");
    if (failed) showConnectionError(failed.reason);
  });
}());