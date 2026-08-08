#!/usr/bin/env node
//
// send-span.mjs - send one OpenInference span to a Phoenix collector for smoke
// tests, using the same library (and header behavior) as the pi-phoenix
// extension: @arizeai/phoenix-otel sends `Authorization: Bearer <apiKey>`.
//
// Usage:
//   node send-span.mjs <phoenix-otel-entry> <endpoint> [apiKey]
//
// <phoenix-otel-entry> is an absolute path to @arizeai/phoenix-otel's ESM
// entry (or a package specifier when the module is resolvable from this
// directory).
//
// The exit code does not prove ingestion (OTLP exporters retry in the
// background); callers must verify the span landed by querying Phoenix.
//
const [entry, endpoint, apiKey] = process.argv.slice(2);

if (!entry || !endpoint) {
  console.error("usage: send-span.mjs <phoenix-otel-entry> <endpoint> [apiKey]");
  process.exit(2);
}

const { register } = await import(entry);

const provider = register({
  projectName: "phoenix-smoke",
  url: endpoint,
  ...(apiKey ? { apiKey } : {}),
  batch: false,
  global: false,
});

const tracer = provider.getTracer("phoenix-smoke-test");
const span = tracer.startSpan("smoke.test.span", {
  attributes: { "smoke.test": "true" },
});
span.end();

await provider.forceFlush();
await provider.shutdown();
console.log("span sent");
