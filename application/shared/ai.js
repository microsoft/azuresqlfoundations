(function () {
  "use strict";

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, character => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function errorMessage(error) {
    const banner = document.getElementById("liveDataError");
    if (banner) banner.textContent = `Live data unavailable: ${error.message}`;
    else window.alert(error.message);
  }

  async function post(url, body) {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "The request failed.");
    return data;
  }

  function wireSearch() {
    const original = document.getElementById("btnAiSearch");
    const button = original.cloneNode(true);
    original.replaceWith(button);
    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "Searching...";
      try {
        const activeFilter = document.querySelector(".filter-pill.active")?.dataset.filter;
        const data = await post("/api/ai/search", {
          prompt: document.getElementById("aiSearchPrompt").value,
          loanType: activeFilter === "all" ? null : activeFilter,
          topN: 10
        });
        showAiResults(data.results.map(row => ({
          id: row.LoanId,
          type: row.LoanType,
          amt: new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 }).format(row.RequestedAmount),
          cr: row.CreditScore,
          out: row.LoanOutcome,
          dist: Number(row.SemanticDistance),
          rel: row.SemanticRelevance,
          narr: row.NarrativePreview
        })));
        document.getElementById("aiSearchTime").textContent = `${data.processingTimeMs}ms`;
      } catch (error) {
        errorMessage(error);
      } finally {
        button.disabled = false;
        button.textContent = "Search →";
      }
    });
  }

  function setInfo(container, label, value) {
    const row = [...container.querySelectorAll(".info-row")]
      .find(item => item.querySelector(".info-label")?.textContent.trim() === label);
    if (row) row.querySelector(".info-value").textContent = value ?? "—";
  }

  function wireScoring() {
    const section = document.getElementById("page-scoring");
    const controls = document.createElement("div");
    controls.className = "card mb-16";
    controls.innerHTML = '<div class="card-header"><h3>Score an Application</h3><div style="display:flex;gap:8px;align-items:center">' +
      '<input id="scoreApplicationId" type="number" min="1" value="1" aria-label="Application ID" style="padding:6px 12px;border:1px solid var(--border);border-radius:var(--radius-sm);width:140px">' +
      '<button class="btn btn-fill" id="btnScoreApplication">Score Application</button></div></div>';
    section.prepend(controls);

    document.getElementById("btnScoreApplication").addEventListener("click", async event => {
      const button = event.currentTarget;
      button.disabled = true;
      button.textContent = "Scoring...";
      try {
        const applicationId = Number(document.getElementById("scoreApplicationId").value);
        const result = await post("/api/ai/score", { applicationId });
        const applicationCard = section.querySelector(".row-2 .card");
        applicationCard.querySelector("h3").textContent = `Application #${applicationId}`;
        setInfo(applicationCard, "Applicant", result.Applicant);
        setInfo(applicationCard, "Loan Type", result.LoanType);
        setInfo(applicationCard, "Requested Amount", Number(result.RequestedAmount).toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 }));

        const decisionCard = section.querySelector(".decision-card");
        decisionCard.querySelector(".decision-stamp").textContent = result.Decision;
        decisionCard.querySelector(".risk-gauge-val").textContent = Math.round(result.RiskScore);
        setInfo(decisionCard, "Risk Score", `${Number(result.RiskScore).toFixed(0)} / 100`);
        setInfo(decisionCard, "Approved Amount", result.ApprovedAmount ? Number(result.ApprovedAmount).toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 }) : "—");
        setInfo(decisionCard, "Interest Rate", result.InterestRate ? `${Number(result.InterestRate).toFixed(2)}%` : "—");
        setInfo(decisionCard, "Similar Loans Analyzed", result.SimilarLoansAnalyzed);
        setInfo(decisionCard, "Historical Approval Rate", `${Number(result.SimilarLoanApprovalRate || 0).toFixed(1)}%`);
        setInfo(decisionCard, "Processing Time", `${result.ProcessingTimeMs}ms`);
        section.querySelector(".narrative").innerHTML = escapeHtml(result.AIRiskNarrative);
      } catch (error) {
        errorMessage(error);
      } finally {
        button.disabled = false;
        button.textContent = "Score Application";
      }
    });
  }

  wireSearch();
  wireScoring();
}());