import assert from "node:assert/strict";
import { test } from "node:test";
import { formatMoney, formatMoneyCompact, formatPercent } from "../../../app/javascript/utils/format_money.mjs";

const UAH = { unit: "₴", delimiter: ",", separator: ".", format: "%n %u" };
const USD = { unit: "$", delimiter: ",", separator: ".", format: "%u%n" };
const EUR_DE = { unit: "€", delimiter: ".", separator: ",", format: "%n %u" };

test("hryvnias read as the rest of the app shows them", () => {
  assert.equal(formatMoney(2633, 2, UAH), "2,633.00 ₴");
});

test("dollars put the symbol first", () => {
  assert.equal(formatMoney(30, 2, USD), "$30.00");
  assert.equal(formatMoney(-1234567.5, 2, USD), "-$1,234,567.50");
});

test("a currency's own separators and a larger precision", () => {
  assert.equal(formatMoney(1234.5, 2, EUR_DE), "1.234,50 €");
  assert.equal(formatMoney(135.7009, 4, USD), "$135.7009");
  assert.equal(formatMoney(5, 0, USD), "$5");
});

test("compact amounts keep at most 3 significant digits in the server's format", () => {
  assert.equal(formatMoneyCompact(12345, UAH), "12.3K ₴");
  assert.equal(formatMoneyCompact(1500000, USD), "$1.5M");
  assert.equal(formatMoneyCompact(532.45, UAH), "532 ₴");
  assert.equal(formatMoneyCompact(12.5, USD), "$12.5");
  assert.equal(formatMoneyCompact(0, UAH), "0 ₴");
  assert.equal(formatMoneyCompact(2_000_000_000, USD), "$2B");
});

test("a compact amount that rounds up moves to the next step", () => {
  assert.equal(formatMoneyCompact(999_950, USD), "$1M");
  assert.equal(formatMoneyCompact(999.6, UAH), "1K ₴");
  assert.equal(formatMoneyCompact(100_000, UAH), "100K ₴");
});

test("compact negatives and a currency's own decimal mark", () => {
  assert.equal(formatMoneyCompact(-12345, USD), "-$12.3K");
  assert.equal(formatMoneyCompact(1234.5, EUR_DE), "1,23K €");
  assert.equal(formatMoneyCompact(-0.001, USD), "$0");
});

test("percentages have one decimal", () => {
  assert.equal(formatPercent(12.345), "12.3%");
  assert.equal(formatPercent(5), "5.0%");
  assert.equal(formatPercent(-0.04), "0.0%");
  assert.equal(formatPercent(-3.26), "-3.3%");
  assert.equal(formatPercent(4.2, { signed: true }), "+4.2%");
  assert.equal(formatPercent(0, { signed: true }), "0.0%");
  assert.equal(formatPercent(12.34, { separator: "," }), "12,3%");
});

test("the compact form keeps 3 significant digits in the server format", () => {
  assert.equal(formatMoneyCompact(33430, UAH), "33.4K ₴");
  assert.equal(formatMoneyCompact(1250000, USD), "$1.25M");
  assert.equal(formatMoneyCompact(950, UAH), "950 ₴");
  assert.equal(formatMoneyCompact(0, UAH), "0 ₴");
  assert.equal(formatMoneyCompact(-45678, USD), "-$45.7K");
  assert.equal(formatMoneyCompact(1234.5, EUR_DE), "1,23K €");
});

test("the compact form moves up a unit when rounding reaches 1000", () => {
  assert.equal(formatMoneyCompact(999950, UAH), "1M ₴");
  assert.equal(formatMoneyCompact(999.6, USD), "$1K");
});
