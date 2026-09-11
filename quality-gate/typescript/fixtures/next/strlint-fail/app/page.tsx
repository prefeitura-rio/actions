import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Next fixture",
};

export default function Page() {
  console.log("unexpected production log");
  return <main>Next fixture</main>;
}
