import { describe, expect, it } from "vitest";
import { creatorIdOf, platformTag } from "../src/identity";

describe("identity", () => {
  it("matches IdentityAttestor.creatorIdOf (vector from cast)", () => {
    expect(platformTag("x")).toBe("0x7521d1cadbcfa91eec65aa16715b94ffc1c9654ba57ea2ef1a2127bca1127a83");
    expect(creatorIdOf("x", "12345")).toBe("0xe69f9e6bbc254b7c905fd0f1dc1234b27630378218c4e0f095b3671a32c1692b");
  });

  it("separates the same numeric id across platforms", () => {
    expect(creatorIdOf("x", "12345")).not.toBe(creatorIdOf("github", "12345"));
  });
});
