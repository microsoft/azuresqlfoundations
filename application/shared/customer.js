(function () {
  "use strict";

  const form = document.getElementById("rateForm");
  const button = form.querySelector('button[type="submit"]');

  function numericValue(id) {
    return Number(document.getElementById(id).value.replace(/[^0-9.]/g, ""));
  }

  function creditScore() {
    const value = document.getElementById("creditScore").value;
    if (value.includes("750")) return 775;
    if (value.includes("700")) return 725;
    if (value.includes("650")) return 675;
    if (value.includes("600")) return 625;
    return 575;
  }

  function loanType() {
    const purpose = document.getElementById("loanPurpose").value;
    if (purpose.includes("Auto")) return "Auto";
    if (purpose.includes("Business")) return "SmallBusiness";
    if (purpose.includes("Home")) return "HomeImprovement";
    return "Personal";
  }

  form.addEventListener("submit", async function (event) {
    event.preventDefault();
    event.stopImmediatePropagation();
    button.disabled = true;
    button.textContent = "Checking...";

    try {
      const response = await fetch("/api/rates", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          amount: numericValue("loanAmount"),
          income: numericValue("annualIncome"),
          creditScore: creditScore(),
          loanType: loanType()
        })
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || "Unable to check the rate.");

      document.getElementById("rateDisplay").textContent = `${result.interestRate.toFixed(2)}%`;
      document.getElementById("monthlyDisplay").textContent =
        `Est. monthly payment: $${result.monthlyPayment.toLocaleString()}/mo for ${result.termMonths} months ` +
        `(${result.comparableLoans.toLocaleString()} comparable loans)`;
      document.getElementById("rateResult").classList.add("visible");
    } catch (error) {
      document.getElementById("rateDisplay").textContent = "Unavailable";
      document.getElementById("monthlyDisplay").textContent = error.message;
      document.getElementById("rateResult").classList.add("visible");
    } finally {
      button.disabled = false;
      button.textContent = "Check My Rate →";
    }
  }, true);
}());