// Formats an amount the way the server's Money#format does, from the options the
// server hands over (Money#format_options: unit, delimiter, separator, format such as
// "%n %u"). Intl formats UAH as "UAH 2,633.00" in English; the rest of the app shows
// "2,633.00 ₴".
export function formatMoney(amount, precision, { unit, delimiter, separator, format }) {
  const [whole, fraction] = Math.abs(amount).toFixed(precision).split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, delimiter ?? ",");
  const number = fraction ? `${grouped}${separator ?? "."}${fraction}` : grouped;
  const text = (format || "%u%n").replace("%n", number).replace("%u", unit ?? "");

  return amount < 0 ? `-${text}` : text;
}

const COMPACT_STEPS = [
  { value: 1e12, suffix: "T" },
  { value: 1e9, suffix: "B" },
  { value: 1e6, suffix: "M" },
  { value: 1e3, suffix: "K" },
];

// At most 3 significant digits and 2 decimals, trailing zeros dropped:
// 12.3, 1.5, 532, 0.46
function round3(value) {
  return Number(Number(value.toPrecision(3)).toFixed(2));
}

function significant(value, separator) {
  const text = String(round3(value));
  return separator && separator !== "." ? text.replace(".", separator) : text;
}

// The short form for chart axes and tight labels, in the server's unit and
// format: "12.3K ₴", "$1.5M", "532 ₴". At most 3 significant digits; a value
// that rounds up to the next step moves to it (999,950 is "1M", not "1000K").
export function formatMoneyCompact(amount, { unit, separator, format } = {}) {
  const abs = Math.abs(amount);
  let number = significant(abs, separator);

  for (let i = 0; i < COMPACT_STEPS.length; i++) {
    const { value, suffix } = COMPACT_STEPS[i];
    if (round3(abs) < value) continue;

    const scaled = Number((abs / value).toPrecision(3));
    // 999,950 scales to 1000K: that is the next step's 1M
    if (scaled >= 1000 && i > 0) {
      number = `${significant(scaled / 1000, separator)}${COMPACT_STEPS[i - 1].suffix}`;
    } else {
      number = `${significant(scaled, separator)}${suffix}`;
    }
    break;
  }

  const text = (format || "%u%n").replace("%n", number).replace("%u", unit ?? "");
  return amount < 0 && round3(abs) !== 0 ? `-${text}` : text;
}

// A percentage with 1 decimal, "12.3%". `signed: true` puts a + before a
// positive value, for changes; `separator` is the currency's decimal mark.
export function formatPercent(value, { signed = false, separator = "." } = {}) {
  const rounded = Number(value.toFixed(1));
  const safe = Object.is(rounded, -0) ? 0 : rounded;
  let text = Math.abs(safe).toFixed(1);
  if (separator !== ".") text = text.replace(".", separator);

  const sign = safe < 0 ? "-" : signed && safe > 0 ? "+" : "";
  return `${sign}${text}%`;
}
