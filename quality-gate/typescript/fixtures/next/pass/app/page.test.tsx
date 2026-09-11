import { describe, expect, it } from "vitest";
import Page from "./page";
import config from "../next.config";

describe("Next.js fixture", () => {
  it("imports the App Router page and config", () => {
    expect(Page).toBeDefined();
    expect(typeof Page).toBe("function");
    expect(config.reactStrictMode).toBe(true);
  });
});
