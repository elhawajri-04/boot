// =============================================================
// ADDITIVE PATCH FOR CURRENT LIVE WORKER
// Adds a sanitized public read-only endpoint:
//   GET /bot-results
//
// IMPORTANT:
// - Add this to the CURRENT deployed Worker source.
// - Do NOT replace the whole Worker with an older file.
// - Returns NO account number, balance, equity, tokens, or cookies.
// - Reads only from existing D1 tables: trade_events + analysis_journal.
// =============================================================


// -------------------------------------------------------------
// 1) ADD THIS ROUTE INSIDE fetch(request, env)
// Put it near the other GET routes, BEFORE the final 404.
// -------------------------------------------------------------
/*
if (
  url.pathname === "/bot-results" &&
  request.method === "GET"
) {
  return handleBotResults(env, url);
}
*/


// -------------------------------------------------------------
// 2) ADD THIS FUNCTION OUTSIDE export default { ... }
// -------------------------------------------------------------
async function handleBotResults(env, url) {
  let limit = Number(url.searchParams.get("limit") || 100);

  if (!Number.isFinite(limit)) {
    limit = 100;
  }

  limit = Math.max(
    1,
    Math.min(250, Math.floor(limit))
  );

  const journal = await env.DB.prepare(`
    SELECT
      analysis_id,
      signal_id,
      rules_version,
      regime,
      strategy,
      decision,
      setup_score,
      entry,
      fill_price,
      sl,
      tp1,
      tp2,
      lot,
      execution_status,
      created_at,
      closed_at,
      exit_price,
      pnl,
      outcome,
      close_reason,
      duration_seconds,
      mfe_price,
      mae_price,
      mfe_usd,
      mae_usd,
      realized_r
    FROM analysis_journal
    WHERE
      execution_status = 'closed'
      OR closed_at IS NOT NULL
      OR outcome IS NOT NULL
    ORDER BY COALESCE(closed_at, created_at) DESC
    LIMIT ?1
  `)
    .bind(limit)
    .all();

  const closeEvents = await env.DB.prepare(`
    SELECT
      event_id,
      signal_id,
      analysis_id,
      symbol,
      event_type,
      position_id,
      deal_id,
      side,
      price,
      volume,
      profit,
      commission,
      swap,
      event_time,
      payload_json
    FROM trade_events
    WHERE event_type = 'CLOSE'
    ORDER BY event_time DESC
    LIMIT ?1
  `)
    .bind(limit)
    .all();

  const openEvents = await env.DB.prepare(`
    SELECT
      event_id,
      signal_id,
      analysis_id,
      symbol,
      event_type,
      position_id,
      deal_id,
      side,
      price,
      volume,
      event_time
    FROM trade_events
    WHERE event_type = 'OPEN'
    ORDER BY event_time DESC
    LIMIT ?1
  `)
    .bind(limit)
    .all();

  const journalRows =
    Array.isArray(journal?.results)
      ? journal.results
      : [];

  const closeRows =
    Array.isArray(closeEvents?.results)
      ? closeEvents.results
      : [];

  const openRows =
    Array.isArray(openEvents?.results)
      ? openEvents.results
      : [];

  let wins = 0;
  let losses = 0;
  let be = 0;
  let netPnl = 0;

  for (const row of journalRows) {
    const pnl = Number(row.pnl);

    if (Number.isFinite(pnl)) {
      netPnl += pnl;
    }

    const outcome =
      String(row.outcome || "").toUpperCase();

    if (outcome === "WIN") wins++;
    else if (outcome === "LOSS") losses++;
    else if (outcome === "BE") be++;
  }

  let summarySource = "analysis_journal";

  if (journalRows.length === 0 && closeRows.length > 0) {
    summarySource = "trade_events";

    wins = 0;
    losses = 0;
    be = 0;
    netPnl = 0;

    for (const row of closeRows) {
      let net = Number(row.profit || 0);

      const commission = Number(row.commission || 0);
      const swap = Number(row.swap || 0);

      if (Number.isFinite(commission)) net += commission;
      if (Number.isFinite(swap)) net += swap;

      try {
        const payload = JSON.parse(row.payload_json || "{}");
        const payloadNet = Number(payload.net_profit);

        if (Number.isFinite(payloadNet)) {
          net = payloadNet;
        }
      } catch {}

      netPnl += net;

      if (net > 0.01) wins++;
      else if (net < -0.01) losses++;
      else be++;
    }
  }

  const closed =
    summarySource === "analysis_journal"
      ? journalRows.length
      : closeRows.length;

  const decided = wins + losses;

  return json({
    ok: true,
    endpoint: "bot-results",
    generated_at: Date.now(),

    summary: {
      source: summarySource,
      closed,
      wins,
      losses,
      break_even: be,
      win_rate:
        decided > 0
          ? Math.round((wins / decided) * 10000) / 100
          : 0,
      net_pnl:
        Math.round(netPnl * 100) / 100
    },

    closed_trades: journalRows,
    close_events: closeRows,
    open_events: openRows
  });
}
