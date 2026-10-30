// A label pill in its GitHub colour (#2686, #2956), its text black or white by the colour's
// luminance: on the Issues page, the Pull requests page and a pull request's page. color is
// #rrggbb, or nothing for a plain pill; with onClick it is a button, else a span.
const labelPill = (ui, text, color, onClick, props) => {
  const colored = /^#[0-9a-f]{6}$/i.test(color || "");
  const all = Object.assign({}, props, { className: ["pill", colored ? "colored" : "", (props && props.className) || ""].filter(Boolean).join(" ") });
  const pill = onClick ? ui.button(text, onClick, all) : ui.el("span", Object.assign({ textContent: text }, all));
  if (colored) {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(color.slice(i, i + 2), 16) / 255)
      .map((c) => c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    pill.style.background = color;
    pill.style.color = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.179 ? "#000" : "#fff";
  }
  return pill;
};

// A pull request's labels as pills, from its labels and the colours its result gave.
const prLabels = (ui, pr, colors) => (Array.isArray(pr.labels) ? pr.labels : [])
  .map((name) => labelPill(ui, name, (colors || {})[name], null, { title: "Label" }));
