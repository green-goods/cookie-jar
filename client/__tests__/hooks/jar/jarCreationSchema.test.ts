import { zodResolver } from "@hookform/resolvers/zod";
import {
	AccessType,
	type JarCreationFormData,
	jarCreationSchema,
} from "@jar-core/hooks/jar/schemas/jarCreationSchema";
import { DEFAULT_CREATION_VALUES } from "@jar-core/lib/jar/creation-values";
import { describe, expect, it } from "vitest";

// The create form validates through this resolver, so these cases exercise
// zod and @hookform/resolvers together, the way useJarCreation wires them.
const resolve = (values: JarCreationFormData) =>
	zodResolver(jarCreationSchema)(values, undefined, {
		fields: {},
		shouldUseNativeValidation: false,
	});

const validForm: JarCreationFormData = {
	...DEFAULT_CREATION_VALUES,
	jarName: "Contributor stipend",
	jarOwnerAddress: "0x1111111111111111111111111111111111111111",
};

describe("jar creation form validation", () => {
	it("accepts a complete form and returns its values", async () => {
		const result = await resolve(validForm);

		expect(result.errors).toEqual({});
		expect(result.values).toEqual(validForm);
	});

	it("explains a missing jar name", async () => {
		const result = await resolve({ ...validForm, jarName: "" });

		expect(result.errors.jarName?.message).toBe("Jar name is required");
	});

	it("rejects a malformed owner address", async () => {
		const result = await resolve({ ...validForm, jarOwnerAddress: "0x123" });

		expect(result.errors.jarOwnerAddress?.message).toBe(
			"Must be a valid Ethereum address"
		);
	});

	it.each([
		["blank", ""],
		["zero", "0x0000000000000000000000000000000000000000"],
	])("allows a %s owner address", async (_, jarOwnerAddress) => {
		const result = await resolve({ ...validForm, jarOwnerAddress });

		expect(result.errors).toEqual({});
	});

	it("rejects an access type outside the contract enum", async () => {
		const result = await resolve({
			...validForm,
			accessType: 9 as AccessType,
		});

		expect(result.errors.accessType).toBeDefined();
	});

	it("keeps protocol config fields the schema does not list", async () => {
		const protocolConfig = {
			accessType: "Hats" as const,
			hatsId: "1",
			teamLabel: "Team hat",
		};

		const result = await resolve({
			...validForm,
			accessType: AccessType.Hats,
			protocolConfig,
		});

		expect(result.errors).toEqual({});
		expect(result.values).toMatchObject({ protocolConfig });
	});
});
