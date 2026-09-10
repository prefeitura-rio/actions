import { describe, expect, it } from "vitest";
import App from "./App.vue";

describe("Vue fixture", () => {
  it("imports and defines the App component", () => {
    expect(App).toBeDefined();
    expect(typeof App).toBe("object");
  });
});
