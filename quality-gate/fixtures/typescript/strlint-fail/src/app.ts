export function process(data: number[]): number {
  const total: number = data.reduce((acc: number, item: number) => acc + item, 0 as any);
  return total;
}
