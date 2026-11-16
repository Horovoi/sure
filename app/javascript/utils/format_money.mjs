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

const COMPACT_SUFFIXES = ["", "K", "M", "B", "T"];

// The short form for chart axes and guides: at most 3 significant digits and a
// K/M/B/T suffix, in the server's format ("33.4K ₴" for UAH, "$1.25M" for USD).
export function formatMoneyCompact(amount, { unit, delimiter, separator, format } = {}) {
  const abs = Math.abs(amount);
  const last = COMPACT_SUFFIXES.length - 1;
  let tier = abs >= 1000 ? Math.min(last, Math.floor(Math.log10(abs) / 3)) : 0;
  let scaled = Number((abs / 10 ** (3 * tier)).toPrecision(3));
  // 999,950 rounds to 1000K: that is 1M
  if (scaled >= 1000 && tier < last) {
    tier += 1;
    scaled = Number((abs / 10 ** (3 * tier)).toPrecision(3));
  }

  const [whole, fraction] = String(scaled).split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, delimiter ?? ",");
  const number = `${fraction ? `${grouped}${separator ?? "."}${fraction}` : grouped}${COMPACT_SUFFIXES[tier]}`;
  const text = (format || "%u%n").replace("%n", number).replace("%u", unit ?? "");

  return amount < 0 && scaled !== 0 ? `-${text}` : text;
}
