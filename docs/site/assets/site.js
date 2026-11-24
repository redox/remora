const demo = document.querySelector(".demo-controls");
if (demo) {
  demo.hidden = false;
  demo.addEventListener("click", event => {
    const button = event.target.closest("[data-demo]");
    if (!button) return;
    for (const option of demo.querySelectorAll("[data-demo]")) {
      option.setAttribute("aria-pressed", String(option === button));
    }
    for (const panel of document.querySelectorAll("[data-demo-panel]")) {
      panel.hidden = panel.dataset.demoPanel !== button.dataset.demo;
    }
  });
}
