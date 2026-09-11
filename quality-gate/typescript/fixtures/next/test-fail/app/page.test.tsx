import { describe, expect, it } from "vitest";
import Page from "./page";

describe("Next.js fixture", () => {
  it("fails intentionally after importing the page", () => {
    expect(typeof Page).toBe("not-a-function");
  });
});
