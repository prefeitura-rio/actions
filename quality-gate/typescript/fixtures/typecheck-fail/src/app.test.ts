import { describe, it, expect } from "vitest";
import { process } from "./app.js";

describe("process", () => {
  it("returns 0 for empty array", () => {
    expect(process([])).toBe(0);
  });
});
