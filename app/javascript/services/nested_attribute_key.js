let lastKey = 0;

// Key for a nested-attributes template added on the page. Date.now() alone repeats when
// two items are added within the same millisecond, and Rails then merges them into one.
export function nextNestedAttributeKey() {
  lastKey = Math.max(Date.now(), lastKey + 1);
  return lastKey;
}
