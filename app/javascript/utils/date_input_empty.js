// Keeps `data-empty` on every <input type="date"> that has no value, so the
// date parts WebKit draws as text (mm/dd/yyyy) take the placeholder colour
// (sure-design-system.css). CSS alone cannot tell an empty date input from a
// filled one. Runs on typing and picking, on a form reset, and on any date
// input that Turbo or a controller adds to the page.
const SELECTOR = 'input[type="date"]';

function sync(input) {
  input.toggleAttribute("data-empty", input.value === "");
}

function syncWithin(root) {
  if (root.matches?.(SELECTOR)) sync(root);
  root.querySelectorAll?.(SELECTOR).forEach(sync);
}

function onValueEvent(event) {
  if (event.target instanceof HTMLInputElement && event.target.matches(SELECTOR)) sync(event.target);
}

document.addEventListener("input", onValueEvent, true);
document.addEventListener("change", onValueEvent, true);
// A reset puts the values back after the event, so look once it has run
document.addEventListener("reset", (event) => {
  setTimeout(() => syncWithin(event.target), 0);
}, true);

new MutationObserver((records) => {
  for (const record of records) {
    if (record.type === "attributes") {
      if (record.target.matches(SELECTOR)) sync(record.target);
      continue;
    }
    record.addedNodes.forEach((node) => {
      if (node.nodeType === Node.ELEMENT_NODE) syncWithin(node);
    });
  }
}).observe(document.documentElement, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ["value"],
});

syncWithin(document);
