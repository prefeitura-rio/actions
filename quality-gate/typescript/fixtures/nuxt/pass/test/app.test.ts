import { describe, expect, it } from "vitest";
import App from "../app.vue";
import config from "../nuxt.config";

describe("Nuxt fixture", () => {
  it("imports and defines the App component and nuxt config", () => {
    expect(App).toBeDefined();
    expect(typeof App).toBe("object");
    expect(config).toBeDefined();
  });
});
