import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Next fixture",
};

export default function Page() {
  return <img src="/logo.png" alt="Logo" />;
}
