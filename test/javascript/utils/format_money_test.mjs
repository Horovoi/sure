import assert from "node:assert/strict";
import { test } from "node:test";
import { formatMoney, formatMoneyCompact } from "../../../app/javascript/utils/format_money.mjs";

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
