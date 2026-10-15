// Isolated regression checks for staged MT5->Cloudflare Worker news syncing.
// Run: node XAU_NEWS_SYNC_STAGE_TESTS.mjs
// Never connects to Cloudflare, MetaTrader or a trading account.
import assert from "node:assert/strict";
import worker from "./XAU_Worker_R2_v2_4_NEWS_POLICY_SYNC_STAGING.js";

const now = Math.floor(Date.now() / 1000);
const bars = (seconds) => Array.from({ length: 155 }, (_, i) => {
  const o = 4120 + i * 0.17;
  return { t: now - (156 - i) * seconds, o, h: o + 1.9, l: o - 1.6, c: o + 0.3, v: 120 };
});
function snapshot(risk, permitted) {
  return {
    symbol: "XAUUSD.s", generated_at: now,
    broker_server_day_of_week: 4, broker_server_seconds_of_day: 45000,
    bid: 4148.96, ask: 4149.14, spread_points: 18, point: 0.01, digits: 2,
    M1: bars(60), M5: bars(300), M15: bars(900), M30: bars(1800), H1: bars(3600),
    news_policy: {
      schema: 1, source: "MT5_USD_CALENDAR", enabled: true,
      risk, decision: permitted ? "ALLOW" : "BLOCK",
      entry_allowed: permitted, calendar_healthy: true,
      status: permitted ? "NEWS LOW: EIA Crude Oil Stocks Change" : "NEWS BLOCK CRITICAL: CPI",
      checked_at_server: now, calendar_checked_at_server: now - 10,
      next_blocking_event_server: 0
    }
  };
}
let row = null;
const db = {
  prepare() {
    return {
      async first() { return row; },
      bind(...values) { this.values = values; return this; },
      async run() {
        row = { payload: this.values[0], updated_at: this.values[1] };
        return { success: true };
      }
    };
  }
};
const env = { DB: db, WRITE_TOKEN: "ISOLATED_TEST_TOKEN" };
const request = (endpoint, options = {}) => new Request(
  "https://isolated-worker.example" + endpoint, options
);
async function get(endpoint, options = {}) {
  const response = await worker.fetch(request(endpoint, options), env);
  const data = await response.json();
  assert.equal(response.status, 200, endpoint + ": " + JSON.stringify(data));
  return data;
}
async function postMarket(data) {
  return get("/update", {
    method: "POST",
    headers: { "X-Bridge-Key": env.WRITE_TOKEN, "Content-Type": "application/json" },
    body: JSON.stringify(data)
  });
}
const results = [];
function record(title, predicate) {
  assert.ok(predicate, title);
  results.push("PASS: " + title);
}
for (const [name, risk, permitted] of [
  ["LOW EIA", "LOW", true],
  ["CRITICAL CPI", "CRITICAL", false]
]) {
  const ack = await postMarket(snapshot(risk, permitted));
  record(name + " POST accepted", ack.ok && ack.news_gate.entry_allowed === permitted);
  const news = await get("/news/status");
  const latest = await get("/latest");
  record(name + " synchronized news decisions",
    news.news_gate.entry_allowed === permitted &&
    latest.news_gate.entry_allowed === permitted);
  for (const endpoint of ["/regime", "/r2", "/r2/setup", "/zones/latest"]) {
    const page = await get(endpoint, endpoint === "/zones/latest"
      ? { headers: { "X-Bridge-Key": env.WRITE_TOKEN } } : {});
    record(name + " " + endpoint + " gate",
      page.news_gate.entry_allowed === permitted);
    if (endpoint === "/r2" || endpoint === "/r2/setup") {
      record(name + " " + endpoint + " execution gate",
        !page.execution_allowed || permitted);
    }
    if (endpoint === "/zones/latest" && !permitted)
      record(name + " zones disallow trading", page.r2_allowed === 0);
  }
}
row = { payload: JSON.stringify(snapshot("LOW", true)), updated_at: Date.now() - 60000 };
record("stale news => UNKNOWN", (await get("/news/status")).news_gate.state === "UNKNOWN");
const old = snapshot("LOW", true);
delete old.news_policy;
row = { payload: JSON.stringify(old), updated_at: Date.now() };
record("old EA missing news => UNKNOWN", (await get("/news/status")).news_gate.state === "UNKNOWN");
const mismatch = snapshot("LOW", true);
mismatch.news_policy.decision = "BLOCK";
row = { payload: JSON.stringify(mismatch), updated_at: Date.now() };
record("conflicting news decision => UNKNOWN", (await get("/news/status")).news_gate.state === "UNKNOWN");
console.log(results.join("\n"));
console.log("ALL " + results.length + " ISOLATED NEWS SYNC TESTS PASSED");
