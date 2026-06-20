const copyButton = document.querySelector("[data-copy]");

copyButton?.addEventListener("click", async () => {
  const target = document.getElementById(copyButton.dataset.copy);
  if (!target) return;

  try {
    await navigator.clipboard.writeText(target.innerText);
    const originalText = copyButton.textContent;
    copyButton.textContent = "скопировано";
    window.setTimeout(() => {
      copyButton.textContent = originalText;
    }, 1600);
  } catch {
    copyButton.textContent = "не удалось";
  }
});

const tabs = document.querySelectorAll("[data-code-tab]");
const panels = document.querySelectorAll("[data-code-panel]");
const fileLabel = document.querySelector("[data-code-file]");

tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    const selected = tab.dataset.codeTab;

    tabs.forEach((item) => {
      const active = item === tab;
      item.classList.toggle("active", active);
      item.setAttribute("aria-selected", String(active));
    });

    panels.forEach((panel) => {
      const active = panel.dataset.codePanel === selected;
      panel.classList.toggle("active", active);
      panel.hidden = !active;
    });

    if (fileLabel) {
      fileLabel.textContent = selected === "konda" ? "счётчик.конда" : "счётчик.c";
    }
  });
});
