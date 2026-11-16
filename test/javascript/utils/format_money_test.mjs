import assert from "node:assert/strict";
import { test } from "node:test";
import { formatMoney } from "../../../app/javascript/utils/format_money.mjs";

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
