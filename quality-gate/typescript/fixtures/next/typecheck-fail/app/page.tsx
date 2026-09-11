import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Next fixture",
};

const count: number = "not a number";

export default function Page() {
  return <main>{count}</main>;
}
