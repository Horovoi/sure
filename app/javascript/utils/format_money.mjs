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
