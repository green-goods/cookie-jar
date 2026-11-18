"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createRequire } = require("node:module");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const rootRequire = createRequire(path.resolve("package.json"));
const queryStringRequire = createRequire(rootRequire.resolve("query-string"));
const decodeUriComponent = queryStringRequire("decode-uri-component");

// Upstream v0.5.1 test.js cases, covering the fast path and the fallback decoder.
const cases = {
	test: "test",
	"a+b": "a+b",
	"%": "%",
	"%25": "%",
	"%%25%%": "%%%%",
	"st%C3%A5le": "ståle",
	"st%C3%A5le%": "ståle%",
	"%%7Bst%C3%A5le%7D%": "%{ståle}%",
	"%7B%ab%7C%de%7D": "{%ab|%de}",
	"%7 B%ab%%7C%de%%7 D": "%7 B%ab%|%de%%7 D",
	"%61+%4d%4D": "a+MM",
	"%EF%BB%BFtest": "﻿test",
	"%FE%FF": "��",
	"%C2": "�",
	"%C2%B5%": "µ%",
	"%C3%5A%A5%AB": "%C3Z%A5%AB",
	"%F0%9F%98": "%F0%9F%98",
	"%ED%A0%80": "%ED%A0%80",
};

test("decodes ordinary and malformed input like upstream 0.5.1", () => {
	for (const [input, expected] of Object.entries(cases)) {
		assert.equal(decodeUriComponent(input), expected, input);
	}
	assert.throws(() => decodeUriComponent(undefined), TypeError);
});

test("decodes many distinct malformed percent-encoded runs in linear time (GHSA-qr28-fpjm-wq7f)", () => {
	let payload = "";
	for (let i = 0; i < 32000; i++) {
		const high = Math.floor(i / 256).toString(16).padStart(2, "0");
		const low = (i % 256).toString(16).padStart(2, "0");
		payload += `%${high}%${low}x`;
	}
	payload += "%zz";
	const started = process.hrtime.bigint();
	const decoded = decodeUriComponent(payload);
	const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
	assert.ok(decoded.endsWith("%zz"));
	// The vulnerable replacement loop takes about 20 s on this payload.
	assert.ok(elapsedMs < 2000, `decoding took ${elapsedMs.toFixed(0)} ms`);
});

test("query-string uses the local security remediation through require()", () => {
	const installed = path.dirname(queryStringRequire.resolve("decode-uri-component"));
	assert.equal(
		readFileSync(path.join(installed, "index.js"), "utf8"),
		readFileSync(path.resolve("vendor/decode-uri-component/index.js"), "utf8"),
	);
	assert.equal(typeof decodeUriComponent, "function");
	const queryString = rootRequire("query-string");
	assert.deepEqual(
		{ ...queryString.parse("?symKey=a%2Fb&relay-protocol=irn&bad=%C2%zz") },
		{ symKey: "a/b", "relay-protocol": "irn", bad: "�%zz" },
	);
});
