import { describe, expect, it } from "vitest";

import { eanAuthorizationHeader, eanSignature } from "../src/expedia/signature.js";

describe("Expedia Rapid signature", () => {
  it("is the SHA-512 of apiKey + secret + timestamp (independent test vector)", () => {
    expect(eanSignature("testkey", "testsecret", 1_700_000_000)).toBe(
      "b1770b0648ebd6fb3f19ff5c4534da1bd52c4060413f0918459b569cedf64fffd915a9702cd9957adcd3d820ba399e51fb048dd7d99e614a050974387e7d15c5",
    );
  });

  it("formats the Authorization header with a whole-second timestamp", () => {
    const header = eanAuthorizationHeader("testkey", "testsecret", 1_700_000_000_999);
    expect(header).toMatch(/^EAN APIKey=testkey,Signature=[0-9a-f]{128},timestamp=1700000000$/);
  });
});
