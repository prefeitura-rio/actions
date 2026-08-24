export function process(data: number[]): number {
  var total = 0;
  for (const item of data) {
    total += item;
  }
  return total;
}
