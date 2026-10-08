const RULES_VERSION = "R1";
const R2_RULES_VERSION = "R2_SWING_V1";
const BUILD_VERSION = "R1_FINAL_WATCH_ZONES_R2_SWING_V1";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // =========================================================
    // HEALTH
    // =========================================================
    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "XAU Live Bridge",
        build: BUILD_VERSION,
        rules_version: RULES_VERSION,
        regime_engine: true,
        setup_engine: true,
        journal: true,
        trade_events: true,
        performance_engine: true,
        zones_feed: true,
        zones_mode: "AUTO_R1_WATCH",
        watch_zones: true,
        r2_swing_engine: true,
        r2_rules_version: R2_RULES_VERSION
      });
    }

    // =========================================================
    // REGIME ENGINE
    // =========================================================
    if (url.pathname === "/regime" && request.method === "GET") {
      try {
        const result = await calculateRegimeR1(env);

        return json({
          ok: true,
          build: BUILD_VERSION,
          rules_version: RULES_VERSION,
          ...result
        });
      } catch (error) {
        return json(
          {
            ok: false,
            error: String(error?.message || error)
          },
          500
        );
      }
    }

    // =========================================================
    // SETUP ENGINE DEBUG
    // =========================================================
    if (url.pathname === "/setup" && request.method === "GET") {
      try {
        const side = String(
          url.searchParams.get("side") || ""
        ).toUpperCase();

        const entry = Number(url.searchParams.get("entry"));
        const sl = Number(url.searchParams.get("sl"));
        const tp = Number(url.searchParams.get("tp"));

        const validation = validateSignal(
          "XAUUSD.s",
          side,
          entry,
          sl,
          tp
        );

        if (!validation.ok) {
          return json(validation, 400);
        }

        const regimeData = await calculateRegimeR1(env);

        const setupData = calculateSetupR1(
          regimeData,
          side,
          entry,
          sl,
          tp
        );

        return json({
          ok: true,
          build: BUILD_VERSION,
          rules_version: RULES_VERSION,
          regime: regimeData.regime,
          strategy: regimeData.strategy,
          regime_score: regimeData.regime_score,
          setup: setupData
        });
      } catch (error) {
        return json(
          {
            ok: false,
            error: String(error?.message || error)
          },
          500
        );
      }
    }

    // =========================================================
    // R2 SWING ENGINE
    // =========================================================
    if (url.pathname === "/r2" && request.method === "GET") {
      try {
        const result = await calculateR2Swing(env);
        return json({
          ok: true,
          build: BUILD_VERSION,
          rules_version: R2_RULES_VERSION,
          r1_untouched: true,
          ...result
        });
      } catch (error) {
        return json({ ok: false, error: String(error?.message || error) }, 500);
      }
    }

    if (url.pathname === "/r2/setup" && request.method === "GET") {
      try {
        const result = await calculateR2Swing(env);
        return json({
          ok: true,
          build: BUILD_VERSION,
          rules_version: R2_RULES_VERSION,
          setup: result.setup,
          market_state: result.market_state,
          selector: result.selector,
          market: result.market
        });
      } catch (error) {
        return json({ ok: false, error: String(error?.message || error) }, 500);
      }
    }

    // =========================================================
    // PERFORMANCE ENGINE
    // =========================================================
    if (
      url.pathname === "/performance" &&
      request.method === "GET"
    ) {
      return handlePerformanceView(request, env);
    }

    // =========================================================
    // AUTO ANALYSIS / TRADE LINK
    // =========================================================
    if (url.pathname === "/go" && request.method === "GET") {
      return handleAutoTradePage(request, env, url);
    }

    // =========================================================
    // MANUAL TRADE PAGE
    // =========================================================
    if (url.pathname === "/trade" && request.method === "GET") {
      return handleTradePage(request, env, url);
    }

    if (
      url.pathname === "/trade/submit" &&
      request.method === "POST"
    ) {
      return handleTradeSubmit(request, env);
    }

    // =========================================================
    // MT5 TRADE EVENTS
    // =========================================================
    if (
      url.pathname === "/trade/event" &&
      request.method === "POST"
    ) {
      return handleTradeEvent(request, env);
    }

    // =========================================================
    // NO TRADE JOURNAL
    // =========================================================
    if (
      url.pathname === "/journal/no-trade" &&
      request.method === "GET"
    ) {
      return handleNoTradePage(request, env, url);
    }

    if (
      url.pathname === "/journal/no-trade/submit" &&
      request.method === "POST"
    ) {
      return handleNoTradeSubmit(request, env);
    }

    // =========================================================
    // JOURNAL
    // =========================================================
    if (url.pathname === "/journal" && request.method === "GET") {
      return handleJournalView(request, env);
    }

    // =========================================================
    // LATEST DECISION ZONES FOR MT5
    // =========================================================
    if (
      url.pathname === "/zones/latest" &&
      request.method === "GET"
    ) {
      return handleLatestZones(request, env, url);
    }

    // =========================================================
    // LOGOUT
    // =========================================================
    if (url.pathname === "/trade/logout") {
      return new Response(null, {
        status: 302,
        headers: {
          Location: "/trade",
          "Set-Cookie":
            "trade_auth=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
        }
      });
    }

    // =========================================================
    // MARKET UPDATE FROM MT5
    // =========================================================
    if (url.pathname === "/update" && request.method === "POST") {
      const key = request.headers.get("X-Bridge-Key");

      if (!env.WRITE_TOKEN || key !== env.WRITE_TOKEN) {
        return json(
          {
            ok: false,
            error: "Unauthorized"
          },
          401
        );
      }

      const body = await request.text();

      if (!body) {
        return json(
          {
            ok: false,
            error: "Empty payload"
          },
          400
        );
      }

      try {
        JSON.parse(body);
      } catch {
        return json(
          {
            ok: false,
            error: "Invalid JSON"
          },
          400
        );
      }

      const now = Date.now();

      await env.DB.prepare(`
        INSERT INTO latest_market (
          id,
          payload,
          updated_at
        )
        VALUES (
          1,
          ?1,
          ?2
        )
        ON CONFLICT(id)
        DO UPDATE SET
          payload = excluded.payload,
          updated_at = excluded.updated_at
      `)
        .bind(body, now)
        .run();

      return json({
        ok: true,
        updated_at: now
      });
    }

    // =========================================================
    // LATEST MARKET
    // =========================================================
    if (url.pathname === "/latest" && request.method === "GET") {
      const row = await env.DB.prepare(`
        SELECT payload, updated_at
        FROM latest_market
        WHERE id = 1
      `).first();

      if (!row) {
        return json(
          {
            ok: false,
            error: "No MT5 data received yet"
          },
          404
        );
      }

      let market;

      try {
        market = JSON.parse(row.payload);
      } catch {
        market = row.payload;
      }

      const now = Date.now();
      const cloudUpdatedAt = Number(row.updated_at);
      const marketGeneratedAt = Number(market?.generated_at);

      const marketAgeSeconds =
        Number.isFinite(cloudUpdatedAt)
          ? Math.max(
              0,
              (now - cloudUpdatedAt) / 1000
            )
          : null;

      const generatedAgeSeconds =
        Number.isFinite(marketGeneratedAt)
          ? Math.max(
              0,
              (now - marketGeneratedAt * 1000) / 1000
            )
          : null;

      return json({
        ok: true,
        server_time: now,
        cloud_updated_at: cloudUpdatedAt,
        market_age_seconds:
          marketAgeSeconds === null
            ? null
            : roundNumber(
                marketAgeSeconds,
                1
              ),
        generated_age_seconds:
          generatedAgeSeconds === null
            ? null
            : roundNumber(
                generatedAgeSeconds,
                1
              ),
        fresh:
          marketAgeSeconds !== null &&
          marketAgeSeconds <= 30,
        freshness_limit_seconds: 30,
        market
      });
    }

    // =========================================================
    // DIRECT SIGNAL API
    // =========================================================
    if (url.pathname === "/signal" && request.method === "POST") {
      const key = request.headers.get("X-Signal-Key");

      if (!env.SIGNAL_TOKEN || key !== env.SIGNAL_TOKEN) {
        return json(
          {
            ok: false,
            error: "Unauthorized"
          },
          401
        );
      }

      let data;

      try {
        data = await request.json();
      } catch {
        return json(
          {
            ok: false,
            error: "Invalid JSON"
          },
          400
        );
      }

      const symbol = String(data.symbol || "").trim();
      const side = String(data.side || "").toUpperCase();

      const allowedSignalSides = [
        "BUY",
        "SELL",
        "BUY_LIMIT",
        "SELL_LIMIT",
        "BUY_STOP",
        "SELL_STOP"
      ];

      if (!allowedSignalSides.includes(side)) {
        return json({ ok: false, error: "Invalid side/order type" }, 400);
      }

      const baseSide = side.startsWith("BUY") ? "BUY" : "SELL";
      const isPendingOrder = side.includes("LIMIT") || side.includes("STOP");

      const entryPrice =
        data.entry_price === null ||
        data.entry_price === undefined
          ? null
          : Number(data.entry_price);

      const sl = Number(data.sl);
      const tp = Number(data.tp);

      let ttlSeconds = Number(data.ttl_seconds);

      if (!Number.isFinite(ttlSeconds)) {
        ttlSeconds = 60;
      }

      ttlSeconds = Math.max(
        5,
        Math.min(isPendingOrder ? 43200 : 120, ttlSeconds)
      );

      if (isPendingOrder && !Number.isFinite(entryPrice)) {
        return json({ ok: false, error: "Pending order requires entry_price" }, 400);
      }

      const validation = validateSignal(
        symbol,
        baseSide,
        entryPrice,
        sl,
        tp
      );

      if (!validation.ok) {
        return json(validation, 400);
      }

      const now = Date.now();
      const expiresAt = now + ttlSeconds * 1000;

      const signalId = crypto.randomUUID();

      await expireOldSignals(env, symbol);

      await env.DB.prepare(`
        INSERT INTO trade_signals (
          signal_id,
          symbol,
          side,
          entry_price,
          sl,
          tp,
          lot,
          status,
          created_at,
          expires_at
        )
        VALUES (
          ?1,
          ?2,
          ?3,
          ?4,
          ?5,
          ?6,
          0.01,
          'pending',
          ?7,
          ?8
        )
      `)
        .bind(
          signalId,
          symbol,
          side,
          entryPrice,
          sl,
          tp,
          now,
          expiresAt
        )
        .run();

      return json({
        ok: true,
        signal_id: signalId,
        expires_at: expiresAt
      });
    }

    // =========================================================
    // MT5 SIGNAL POLLING
    // =========================================================
    if (
      url.pathname === "/signal/latest" &&
      request.method === "GET"
    ) {
      const key = request.headers.get("X-Bridge-Key");

      if (!env.WRITE_TOKEN || key !== env.WRITE_TOKEN) {
        return json(
          {
            ok: false,
            error: "Unauthorized"
          },
          401
        );
      }

      const symbol =
        url.searchParams.get("symbol") || "";

      const now = Date.now();

      await env.DB.prepare(`
        UPDATE trade_signals
        SET status = 'expired'
        WHERE
          status = 'pending'
          AND expires_at <= ?1
      `)
        .bind(now)
        .run();

      const row = await env.DB.prepare(`
        SELECT
          signal_id,
          symbol,
          side,
          entry_price,
          sl,
          tp,
          lot,
          status,
          created_at,
          expires_at
        FROM trade_signals
        WHERE
          status = 'pending'
          AND expires_at > ?1
          AND symbol = ?2
        ORDER BY created_at DESC
        LIMIT 1
      `)
        .bind(now, symbol)
        .first();

      return json({
        ok: true,
        signal: row || null
      });
    }

    // =========================================================
    // SIGNAL ACK
    // =========================================================
    if (
      url.pathname === "/signal/ack" &&
      request.method === "POST"
    ) {
      const key = request.headers.get("X-Bridge-Key");

      if (!env.WRITE_TOKEN || key !== env.WRITE_TOKEN) {
        return json(
          {
            ok: false,
            error: "Unauthorized"
          },
          401
        );
      }

      let data;

      try {
        data = await request.json();
      } catch {
        return json(
          {
            ok: false,
            error: "Invalid JSON"
          },
          400
        );
      }

      const signalId = String(data.signal_id || "");
      const status = String(data.status || "");

      const allowedStatuses = [
        "executed",
        "placed",
        "rejected",
        "expired",
        "failed"
      ];

      if (!signalId) {
        return json(
          {
            ok: false,
            error: "Missing signal_id"
          },
          400
        );
      }

      if (!allowedStatuses.includes(status)) {
        return json(
          {
            ok: false,
            error: "Invalid status"
          },
          400
        );
      }

      await env.DB.prepare(`
        UPDATE trade_signals
        SET status = ?1
        WHERE signal_id = ?2
      `)
        .bind(status, signalId)
        .run();

      await env.DB.prepare(`
        UPDATE analysis_journal
        SET execution_status = ?1
        WHERE signal_id = ?2
      `)
        .bind(status, signalId)
        .run();

      return json({ ok: true });
    }

    return json(
      {
        ok: false,
        error: "Not found"
      },
      404
    );
  }
};


// =============================================================
// AUTO TRADE PAGE
// =============================================================

async function handleAutoTradePage(request, env, url) {
  const authorized =
    await isTradeAuthorized(request, env);

  if (!authorized) {
    return html(
      "<h2>Unauthorized</h2>",
      401
    );
  }

  const side = String(
    url.searchParams.get("side") || ""
  ).toUpperCase();

  const entry = Number(
    url.searchParams.get("entry")
  );

  const sl = Number(
    url.searchParams.get("sl")
  );

  const tp = Number(
    url.searchParams.get("tp")
  );

  const tp2Raw =
    url.searchParams.get("tp2");

  const tp2 =
    tp2Raw === null
      ? null
      : Number(tp2Raw);

  const reason = String(
    url.searchParams.get("reason") || ""
  ).slice(0, 1500);

  let ttl = Number(
    url.searchParams.get("ttl")
  );

  if (!Number.isFinite(ttl)) {
    ttl = 60;
  }

  ttl = Math.max(
    5,
    Math.min(120, ttl)
  );

  const validation = validateSignal(
    "XAUUSD.s",
    side,
    entry,
    sl,
    tp
  );

  if (!validation.ok) {
    return html(`
      <h2>Invalid signal</h2>
      <p>${escapeHtml(validation.error)}</p>
    `, 400);
  }

  let regimeData;

  try {
    regimeData =
      await calculateRegimeR1(env);
  } catch (error) {
    return html(`
      <h2>Regime Engine Error</h2>
      <p>${escapeHtml(
        String(error?.message || error)
      )}</p>
    `, 500);
  }

  const setupData =
    calculateSetupR1(
      regimeData,
      side,
      entry,
      sl,
      tp
    );

  let analysisId =
    url.searchParams.get("analysis_id");

  if (!analysisId) {
    const newUrl =
      new URL(url.toString());

    analysisId =
      crypto.randomUUID();

    newUrl.searchParams.set(
      "analysis_id",
      analysisId
    );

    return new Response(null, {
      status: 302,
      headers: {
        Location: newUrl.toString(),
        "Cache-Control": "no-store"
      }
    });
  }

  const metricsJson =
    JSON.stringify({
      source:
        "Regime + Setup Engine R1",

      regime_score:
        regimeData.regime_score,

      setup_score:
        setupData.setup_score,

      setup_passed:
        setupData.allowed,

      trigger:
        setupData.trigger,

      initial_risk_usd:
        setupData.initial_risk_usd,

      reward_usd:
        setupData.reward_usd,

      planned_rr:
        setupData.planned_rr,

      clean_room_usd:
        setupData.clean_room_usd,

      entry_drift_usd:
        setupData.entry_drift_usd,

      market_age_seconds:
        setupData.market_age_seconds,

      key_support:
        setupData.key_support,

      key_resistance:
        setupData.key_resistance,

      structure_pass:
        setupData.structure_pass,

      trigger_pass:
        setupData.trigger_pass,

      volatility_pass:
        setupData.volatility_pass,

      room_pass:
        setupData.room_pass,

      rr_pass:
        setupData.rr_pass,

      freshness_pass:
        setupData.freshness_pass,

      drift_pass:
        setupData.drift_pass,

      market:
        regimeData.market,

      h1:
        regimeData.metrics.h1,

      m30:
        regimeData.metrics.m30,

      m15:
        regimeData.metrics.m15,

      m5:
        regimeData.metrics.m5,

      m1:
        regimeData.metrics.m1
    });

  // =========================================================
  // BLOCKED
  // =========================================================
  if (!setupData.allowed) {
    await env.DB.prepare(`
      INSERT OR IGNORE INTO analysis_journal (
        analysis_id,
        symbol,
        created_at,
        market_generated_at,
        bid,
        ask,
        rules_version,
        regime,
        strategy,
        decision,
        setup_score,
        entry,
        sl,
        tp1,
        tp2,
        reasons_json,
        metrics_json,
        execution_status
      )
      VALUES (
        ?1,
        'XAUUSD.s',
        ?2,
        ?3,
        ?4,
        ?5,
        ?6,
        ?7,
        ?8,
        'NO_TRADE',
        ?9,
        ?10,
        ?11,
        ?12,
        ?13,
        ?14,
        ?15,
        'not_sent'
      )
    `)
      .bind(
        analysisId,
        Date.now(),
        regimeData.market.generated_at,
        regimeData.market.bid,
        regimeData.market.ask,
        RULES_VERSION,
        regimeData.regime,
        regimeData.strategy,
        setupData.setup_score,
        entry,
        sl,
        tp,
        tp2,
        JSON.stringify([
          reason,
          ...setupData.reasons
        ]),
        metricsJson
      )
      .run();

    return blockedSetupPage(
      regimeData,
      setupData
    );
  }

  // =========================================================
  // ALLOWED
  // =========================================================
  await env.DB.prepare(`
    INSERT OR IGNORE INTO analysis_journal (
      analysis_id,
      symbol,
      created_at,
      market_generated_at,
      bid,
      ask,
      rules_version,
      regime,
      strategy,
      decision,
      setup_score,
      entry,
      sl,
      tp1,
      tp2,
      reasons_json,
      metrics_json,
      execution_status
    )
    VALUES (
      ?1,
      'XAUUSD.s',
      ?2,
      ?3,
      ?4,
      ?5,
      ?6,
      ?7,
      ?8,
      ?9,
      ?10,
      ?11,
      ?12,
      ?13,
      ?14,
      ?15,
      ?16,
      'not_sent'
    )
  `)
    .bind(
      analysisId,
      Date.now(),
      regimeData.market.generated_at,
      regimeData.market.bid,
      regimeData.market.ask,
      RULES_VERSION,
      regimeData.regime,
      regimeData.strategy,
      side,
      setupData.setup_score,
      entry,
      sl,
      tp,
      tp2,
      JSON.stringify([
        reason,
        "REGIME_ALLOWED",
        "SETUP_R1_PASSED"
      ]),
      metricsJson
    )
    .run();

  return html(`
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta
  name="viewport"
  content="width=device-width,initial-scale=1"
>
<title>XAU Signal</title>

<style>
body {
  font-family: Arial;
  background: #111827;
  color: white;
  text-align: center;
  padding: 40px;
}

.box {
  max-width: 560px;
  margin: auto;
  background: #1f2937;
  padding: 30px;
  border-radius: 16px;
}

.good {
  color: #22c55e;
}

.side {
  font-size: 30px;
  font-weight: bold;
}
</style>
</head>

<body>

<div class="box">

<h1>XAUUSD Signal</h1>

<div class="side good">
  ${escapeHtml(side)}
</div>

<p>
Regime:
<strong>${escapeHtml(regimeData.regime)}</strong>
</p>

<p>
Strategy:
<strong>${escapeHtml(regimeData.strategy)}</strong>
</p>

<p>
Regime Score:
${escapeHtml(regimeData.regime_score)}
</p>

<p>
Setup Score:
<strong>${escapeHtml(setupData.setup_score)}</strong>
</p>

<p>Entry: ${escapeHtml(entry)}</p>
<p>SL: ${escapeHtml(sl)}</p>
<p>TP: ${escapeHtml(tp)}</p>

<p>
Planned RR:
${escapeHtml(setupData.planned_rr)}
</p>

<p>
Clean Room:
$${escapeHtml(setupData.clean_room_usd)}
</p>

<p>Sending to MT5...</p>

<form
  id="autoTrade"
  method="POST"
  action="/trade/submit"
>

<input
  type="hidden"
  name="analysis_id"
  value="${escapeHtml(analysisId)}"
>

<input
  type="hidden"
  name="signal_id"
  value="${escapeHtml(
    crypto.randomUUID()
  )}"
>

<input
  type="hidden"
  name="symbol"
  value="XAUUSD.s"
>

<input
  type="hidden"
  name="side"
  value="${escapeHtml(side)}"
>

<input
  type="hidden"
  name="entry_price"
  value="${escapeHtml(entry)}"
>

<input
  type="hidden"
  name="sl"
  value="${escapeHtml(sl)}"
>

<input
  type="hidden"
  name="tp"
  value="${escapeHtml(tp)}"
>

<input
  type="hidden"
  name="ttl_seconds"
  value="${escapeHtml(ttl)}"
>

</form>

</div>

<script>
setTimeout(() => {
  document
    .getElementById("autoTrade")
    .submit();
}, 300);
</script>

</body>
</html>
  `);
}


// =============================================================
// BLOCKED SETUP PAGE
// =============================================================

function blockedSetupPage(
  regimeData,
  setupData
) {
  const reasons =
    setupData.reasons
      .map(
        reason =>
          `<li>${escapeHtml(reason)}</li>`
      )
      .join("");

  return html(`
<!doctype html>

<html>
<head>
<meta charset="utf-8">

<meta
  name="viewport"
  content="width=device-width,initial-scale=1"
>

<title>NO TRADE</title>

<style>
body {
  background: #111827;
  color: white;
  font-family: Arial;
  padding: 50px;
  text-align: center;
}

.box {
  max-width: 650px;
  margin: auto;
  background: #1f2937;
  padding: 30px;
  border-radius: 16px;
}

.bad {
  color: #ef4444;
}

ul {
  text-align: left;
  display: inline-block;
}
</style>
</head>

<body>

<div class="box">

<h1 class="bad">
NO TRADE ⛔
</h1>

<p>
Regime:
<strong>
${escapeHtml(regimeData.regime)}
</strong>
</p>

<p>
Strategy:
<strong>
${escapeHtml(regimeData.strategy)}
</strong>
</p>

<p>
Regime Score:
${escapeHtml(regimeData.regime_score)}
</p>

<p>
Setup Score:
<strong>
${escapeHtml(setupData.setup_score)}
</strong>
</p>

<ul>
${reasons}
</ul>

<p>
Analysis saved to Journal.
</p>

</div>

</body>
</html>
  `);
}


// =============================================================
// TRADE SUBMIT
// =============================================================

async function handleTradeSubmit(
  request,
  env
) {
  const authorized =
    await isTradeAuthorized(
      request,
      env
    );

  if (!authorized) {
    return html(
      "<h2>Unauthorized</h2>",
      401
    );
  }

  const form =
    await request.formData();

  const analysisId =
    String(
      form.get("analysis_id") || ""
    );

  const signalId =
    String(
      form.get("signal_id") ||
      crypto.randomUUID()
    );

  const symbol =
    String(
      form.get("symbol") ||
      "XAUUSD.s"
    );

  const side =
    String(
      form.get("side") || ""
    ).toUpperCase();

  const entryPrice =
    Number(
      form.get("entry_price")
    );

  const sl =
    Number(
      form.get("sl")
    );

  const tp =
    Number(
      form.get("tp")
    );

  let ttlSeconds =
    Number(
      form.get("ttl_seconds")
    );

  if (!Number.isFinite(ttlSeconds)) {
    ttlSeconds = 60;
  }

  ttlSeconds =
    Math.max(
      5,
      Math.min(
        120,
        ttlSeconds
      )
    );

  const validation =
    validateSignal(
      symbol,
      side,
      entryPrice,
      sl,
      tp
    );

  if (!validation.ok) {
    return html(
      `<h2>${escapeHtml(
        validation.error
      )}</h2>`,
      400
    );
  }

  const existing =
    await env.DB.prepare(`
      SELECT signal_id
      FROM trade_signals
      WHERE signal_id = ?1
    `)
      .bind(signalId)
      .first();

  if (existing) {
    return signalSentPage(
      side,
      symbol,
      entryPrice,
      sl,
      tp,
      true
    );
  }

  const now = Date.now();

  const expiresAt =
    now +
    ttlSeconds * 1000;

  await expireOldSignals(
    env,
    symbol
  );

  await env.DB.prepare(`
    INSERT INTO trade_signals (
      signal_id,
      symbol,
      side,
      entry_price,
      sl,
      tp,
      lot,
      status,
      created_at,
      expires_at
    )
    VALUES (
      ?1,
      ?2,
      ?3,
      ?4,
      ?5,
      ?6,
      0.01,
      'pending',
      ?7,
      ?8
    )
  `)
    .bind(
      signalId,
      symbol,
      side,
      entryPrice,
      sl,
      tp,
      now,
      expiresAt
    )
    .run();

  if (analysisId) {
    await env.DB.prepare(`
      UPDATE analysis_journal
      SET
        signal_id = ?1,
        execution_status = 'sent'
      WHERE analysis_id = ?2
    `)
      .bind(
        signalId,
        analysisId
      )
      .run();
  }

  return signalSentPage(
    side,
    symbol,
    entryPrice,
    sl,
    tp,
    false
  );
}


// =============================================================
// TRADE EVENT
// =============================================================

async function handleTradeEvent(
  request,
  env
) {
  const key =
    request.headers.get(
      "X-Bridge-Key"
    );

  if (
    !env.WRITE_TOKEN ||
    key !== env.WRITE_TOKEN
  ) {
    return json(
      {
        ok: false,
        error: "Unauthorized"
      },
      401
    );
  }

  let data;

  try {
    data =
      await request.json();
  } catch {
    return json(
      {
        ok: false,
        error: "Invalid JSON"
      },
      400
    );
  }

  const eventId =
    String(
      data.event_id ||
      crypto.randomUUID()
    );

  const signalId =
    String(
      data.signal_id || ""
    );

  const eventType =
    String(
      data.event_type || ""
    ).toUpperCase();

  const symbol =
    String(
      data.symbol ||
      "XAUUSD.s"
    );

  const positionId =
    String(
      data.position_id || ""
    );

  const dealId =
    String(
      data.deal_id || ""
    );

  const side =
    String(
      data.side || ""
    ).toUpperCase();

  const price =
    nullableNumber(
      data.price
    );

  const volume =
    nullableNumber(
      data.volume
    );

  const profit =
    nullableNumber(
      data.profit
    ) ?? 0;

  const commission =
    nullableNumber(
      data.commission
    ) ?? 0;

  const swap =
    nullableNumber(
      data.swap
    ) ?? 0;

  let netProfit =
    nullableNumber(
      data.net_profit
    );

  if (netProfit === null) {
    netProfit =
      profit +
      commission +
      swap;
  }

  let eventTime =
    Number(
      data.event_time
    );

  if (
    !Number.isFinite(eventTime) ||
    eventTime <= 0
  ) {
    eventTime =
      Date.now();
  }

  if (
    eventTime <
    1000000000000
  ) {
    eventTime *=
      1000;
  }

  const closeReason =
    String(
      data.close_reason || ""
    );

  const mfePrice =
    nullableNumber(
      data.mfe_price
    );

  const maePrice =
    nullableNumber(
      data.mae_price
    );

  const mfeUsd =
    nullableNumber(
      data.mfe_usd
    );

  const maeUsd =
    nullableNumber(
      data.mae_usd
    );

  if (!signalId) {
    return json(
      {
        ok: false,
        error: "Missing signal_id"
      },
      400
    );
  }

  if (
    ![
      "OPEN",
      "CLOSE",
      "MODIFY"
    ].includes(eventType)
  ) {
    return json(
      {
        ok: false,
        error: "Invalid event_type"
      },
      400
    );
  }

  const existingEvent =
    await env.DB.prepare(`
      SELECT event_id
      FROM trade_events
      WHERE event_id = ?1
    `)
      .bind(eventId)
      .first();

  if (existingEvent) {
    return json({
      ok: true,
      duplicate: true
    });
  }

  const analysis =
    await env.DB.prepare(`
      SELECT
        analysis_id,
        entry,
        fill_price,
        sl,
        decision
      FROM analysis_journal
      WHERE signal_id = ?1
      LIMIT 1
    `)
      .bind(signalId)
      .first();

  const analysisId =
    analysis
      ? analysis.analysis_id
      : null;

  await env.DB.prepare(`
    INSERT INTO trade_events (
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
    )
    VALUES (
      ?1,
      ?2,
      ?3,
      ?4,
      ?5,
      ?6,
      ?7,
      ?8,
      ?9,
      ?10,
      ?11,
      ?12,
      ?13,
      ?14,
      ?15
    )
  `)
    .bind(
      eventId,
      signalId,
      analysisId,
      symbol,
      eventType,
      positionId,
      dealId,
      side,
      price,
      volume,
      profit,
      commission,
      swap,
      eventTime,
      JSON.stringify(data)
    )
    .run();

  // =========================================================
  // OPEN
  // =========================================================
  if (
    eventType === "OPEN" &&
    analysisId
  ) {
    await env.DB.prepare(`
      UPDATE analysis_journal
      SET
        execution_status = 'executed',
        fill_price = ?1,
        lot = ?2,
        broker_position_id = ?3,
        broker_deal_id = ?4
      WHERE analysis_id = ?5
    `)
      .bind(
        price,
        volume,
        positionId,
        dealId,
        analysisId
      )
      .run();
  }

  // =========================================================
  // CLOSE
  // =========================================================
  if (
    eventType === "CLOSE" &&
    analysisId
  ) {
    let outcome = "BE";

    if (netProfit > 0.01) {
      outcome = "WIN";
    }

    if (netProfit < -0.01) {
      outcome = "LOSS";
    }

    const openEvent =
      await env.DB.prepare(`
        SELECT event_time
        FROM trade_events
        WHERE
          signal_id = ?1
          AND event_type = 'OPEN'
        ORDER BY event_time ASC
        LIMIT 1
      `)
        .bind(signalId)
        .first();

    let durationSeconds =
      null;

    if (
      openEvent &&
      openEvent.event_time &&
      eventTime
    ) {
      durationSeconds =
        Math.max(
          0,
          Math.floor(
            (
              eventTime -
              Number(
                openEvent.event_time
              )
            ) /
            1000
          )
        );
    }

    let realizedR = null;

    const actualEntry =
      analysis.fill_price !== null &&
      analysis.fill_price !== undefined
        ? Number(
            analysis.fill_price
          )
        : Number(
            analysis.entry
          );

    const actualSL =
      analysis.sl !== null &&
      analysis.sl !== undefined
        ? Number(
            analysis.sl
          )
        : null;

    if (
      Number.isFinite(actualEntry) &&
      Number.isFinite(actualSL) &&
      price !== null &&
      Number.isFinite(
        Number(price)
      )
    ) {
      const risk =
        Math.abs(
          actualEntry -
          actualSL
        );

      if (risk > 0) {
        let reward = null;

        if (
          analysis.decision ===
          "BUY"
        ) {
          reward =
            Number(price) -
            actualEntry;
        }

        if (
          analysis.decision ===
          "SELL"
        ) {
          reward =
            actualEntry -
            Number(price);
        }

        if (
          reward !== null &&
          Number.isFinite(reward)
        ) {
          realizedR =
            reward /
            risk;
        }
      }
    }

    await env.DB.prepare(`
      UPDATE analysis_journal
      SET
        execution_status = 'closed',
        closed_at = ?1,
        exit_price = ?2,
        pnl = ?3,
        outcome = ?4,
        close_reason = ?5,
        duration_seconds = ?6,
        mfe_price = ?7,
        mae_price = ?8,
        mfe_usd = ?9,
        mae_usd = ?10,
        realized_r = ?11,
        broker_position_id = ?12,
        broker_deal_id = ?13
      WHERE analysis_id = ?14
    `)
      .bind(
        eventTime,
        price,
        netProfit,
        outcome,
        closeReason,
        durationSeconds,
        mfePrice,
        maePrice,
        mfeUsd,
        maeUsd,
        realizedR,
        positionId,
        dealId,
        analysisId
      )
      .run();
  }

  return json({
    ok: true,
    event_id: eventId,
    analysis_id: analysisId,
    event_type: eventType
  });
}


// =============================================================
// NO TRADE PAGE
// =============================================================

async function handleNoTradePage(
  request,
  env,
  url
) {
  const authorized =
    await isTradeAuthorized(
      request,
      env
    );

  if (!authorized) {
    return html(
      "<h2>Unauthorized</h2>",
      401
    );
  }

  let analysisId =
    url.searchParams.get(
      "analysis_id"
    );

  if (!analysisId) {
    const newUrl =
      new URL(
        url.toString()
      );

    analysisId =
      crypto.randomUUID();

    newUrl.searchParams.set(
      "analysis_id",
      analysisId
    );

    return new Response(null, {
      status: 302,
      headers: {
        Location:
          newUrl.toString(),
        "Cache-Control":
          "no-store"
      }
    });
  }

  const reason =
    String(
      url.searchParams.get(
        "reason"
      ) || ""
    ).slice(0, 1500);

  const buyLow =
    toNullableNumber(
      url.searchParams.get(
        "buy_low"
      )
    );

  const buyHigh =
    toNullableNumber(
      url.searchParams.get(
        "buy_high"
      )
    );

  const sellLow =
    toNullableNumber(
      url.searchParams.get(
        "sell_low"
      )
    );

  const sellHigh =
    toNullableNumber(
      url.searchParams.get(
        "sell_high"
      )
    );

  return html(`
<!doctype html>
<html>

<head>
<meta charset="utf-8">
<meta
  name="viewport"
  content="width=device-width,initial-scale=1"
>
<title>NO TRADE</title>
</head>

<body style="
  font-family:Arial;
  background:#111827;
  color:white;
  text-align:center;
  padding:60px;
">

<h1>NO TRADE</h1>

<p>
Logging R1 market snapshot...
</p>

<form
  id="noTrade"
  method="POST"
  action="/journal/no-trade/submit"
>

<input
  type="hidden"
  name="analysis_id"
  value="${escapeHtml(analysisId)}"
>

<input
  type="hidden"
  name="reason"
  value="${escapeHtml(reason)}"
>

<input
  type="hidden"
  name="buy_low"
  value="${escapeHtml(
    buyLow ?? ""
  )}"
>

<input
  type="hidden"
  name="buy_high"
  value="${escapeHtml(
    buyHigh ?? ""
  )}"
>

<input
  type="hidden"
  name="sell_low"
  value="${escapeHtml(
    sellLow ?? ""
  )}"
>

<input
  type="hidden"
  name="sell_high"
  value="${escapeHtml(
    sellHigh ?? ""
  )}"
>

</form>

<script>
setTimeout(() => {
  document
    .getElementById("noTrade")
    .submit();
}, 300);
</script>

</body>
</html>
  `);
}


// =============================================================
// NO TRADE SUBMIT
// =============================================================

async function handleNoTradeSubmit(
  request,
  env
) {
  const authorized =
    await isTradeAuthorized(
      request,
      env
    );

  if (!authorized) {
    return html(
      "<h2>Unauthorized</h2>",
      401
    );
  }

  const form =
    await request.formData();

  const analysisId =
    String(
      form.get("analysis_id") ||
      crypto.randomUUID()
    );

  const reason =
    String(
      form.get("reason") || ""
    );

  const buyLow =
    toNullableNumber(
      form.get("buy_low")
    );

  const buyHigh =
    toNullableNumber(
      form.get("buy_high")
    );

  const sellLow =
    toNullableNumber(
      form.get("sell_low")
    );

  const sellHigh =
    toNullableNumber(
      form.get("sell_high")
    );

  const regimeData =
    await calculateRegimeR1(env);

  const metricsJson =
    JSON.stringify({
      source:
        "Regime Engine R1 NO_TRADE",

      regime_score:
        regimeData.regime_score,

      market:
        regimeData.market,

      h1:
        regimeData.metrics.h1,

      m30:
        regimeData.metrics.m30,

      m15:
        regimeData.metrics.m15,

      m5:
        regimeData.metrics.m5,

      m1:
        regimeData.metrics.m1
    });

  await env.DB.prepare(`
    INSERT OR IGNORE INTO analysis_journal (
      analysis_id,
      symbol,
      created_at,
      market_generated_at,
      bid,
      ask,
      rules_version,
      regime,
      strategy,
      decision,
      buy_zone_low,
      buy_zone_high,
      sell_zone_low,
      sell_zone_high,
      reasons_json,
      metrics_json,
      execution_status
    )
    VALUES (
      ?1,
      'XAUUSD.s',
      ?2,
      ?3,
      ?4,
      ?5,
      ?6,
      ?7,
      ?8,
      'NO_TRADE',
      ?9,
      ?10,
      ?11,
      ?12,
      ?13,
      ?14,
      'not_sent'
    )
  `)
    .bind(
      analysisId,
      Date.now(),
      regimeData.market.generated_at,
      regimeData.market.bid,
      regimeData.market.ask,
      RULES_VERSION,
      regimeData.regime,
      regimeData.strategy,
      buyLow,
      buyHigh,
      sellLow,
      sellHigh,
      JSON.stringify([reason]),
      metricsJson
    )
    .run();

  return html(`
<body style="
  background:#111827;
  color:white;
  font-family:Arial;
  text-align:center;
  padding:60px;
">

<h1>Analysis logged ✅</h1>

<p>
Regime:
${escapeHtml(
  regimeData.regime
)}
</p>

<p>
Strategy:
${escapeHtml(
  regimeData.strategy
)}
</p>

<p>NO TRADE</p>

</body>
  `);
}


// =============================================================
// JOURNAL VIEW
// =============================================================

async function handleJournalView(
  request,
  env
) {
  const authorized =
    await isTradeAuthorized(
      request,
      env
    );

  if (!authorized) {
    return html(
      "<h2>Unauthorized</h2>",
      401
    );
  }

  const result =
    await env.DB.prepare(`
      SELECT
        analysis_id,
        created_at,
        rules_version,
        regime,
        strategy,
        decision,
        setup_score,
        entry,
        sl,
        tp1,
        tp2,
        signal_id,
        execution_status,
        fill_price,
        lot,
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
        realized_r,
        reasons_json,
        metrics_json
      FROM analysis_journal
      ORDER BY created_at DESC
      LIMIT 100
    `).all();

  return json({
    ok: true,
    build: BUILD_VERSION,
    analyses:
      result.results || []
  });
}


// =============================================================
// LATEST DECISION ZONES FOR MT5
// =============================================================

async function handleLatestZones(
  request,
  env,
  url
) {
  const key = request.headers.get("X-Bridge-Key");

  if (!env.WRITE_TOKEN || key !== env.WRITE_TOKEN) {
    return json({ ok: false, error: "Unauthorized" }, 401);
  }

  const symbol = String(url.searchParams.get("symbol") || "XAUUSD.s");

  if (symbol !== "XAUUSD.s") {
    return json({ ok: false, error: "Unsupported symbol" }, 400);
  }

  try {
    const regimeData = await calculateRegimeR1(env);
    const marketAgeSeconds = Math.max(0, (Date.now() - regimeData.market.cloud_updated_at) / 1000);

    if (marketAgeSeconds > 30) {
      return json({
        ok: true,
        build: BUILD_VERSION,
        rules_version: RULES_VERSION,
        symbol,
        source: "AUTO_R1_WATCH",
        zones: null,
        reason: "STALE_MARKET"
      });
    }

    const zones = calculateAutoDecisionZonesR1(regimeData);

    return json({
      ok: true,
      build: BUILD_VERSION,
      rules_version: RULES_VERSION,
      symbol,
      zones
    });
  } catch (error) {
    return json({ ok: false, error: String(error?.message || error) }, 500);
  }
}

function calculateAutoDecisionZonesR1(regimeData) {
  const { regime, strategy, metrics } = regimeData;
  const { m30, m5, m1 } = metrics;

  let buyLow = null;
  let buyHigh = null;
  let sellLow = null;
  let sellHigh = null;
  let watchOnly = false;
  let zoneType = "AUTO_R1";
  let watchReason = null;

  const setBuy = (a, b) => {
    buyLow = roundNumber(Math.min(a, b), 2);
    buyHigh = roundNumber(Math.max(a, b), 2);
  };
  const setSell = (a, b) => {
    sellLow = roundNumber(Math.min(a, b), 2);
    sellHigh = roundNumber(Math.max(a, b), 2);
  };

  if (regime === "HIGH_VOLATILITY" || strategy === "NO_TRADE") {
    watchOnly = true;
    zoneType = "WATCH_HIGH_VOLATILITY";
    watchReason = "Observation only. Wait for R1 normalization and a valid /setup.";

    const bearishImpulse = m1.close < m1.ema9 && m5.close < m5.ema20;
    const bullishImpulse = m1.close > m1.ema9 && m5.close > m5.ema20;

    if (bearishImpulse) {
      setSell(m1.ema9 - 0.35 * m1.atr14, m1.ema9 + 0.35 * m1.atr14);
      setBuy(m1.low20, m1.low20 + 0.60 * m1.atr14);
    } else if (bullishImpulse) {
      setBuy(m1.ema9 - 0.35 * m1.atr14, m1.ema9 + 0.35 * m1.atr14);
      setSell(m1.high20 - 0.60 * m1.atr14, m1.high20);
    } else {
      setBuy(m1.low20, m1.low20 + 0.50 * m1.atr14);
      setSell(m1.high20 - 0.50 * m1.atr14, m1.high20);
    }
  }
  else if (regime === "TRANSITION" || strategy === "NONE") {
    watchOnly = true;
    zoneType = "WATCH_TRANSITION";
    watchReason = "Observation only. R1 has no tradable strategy yet.";
    setBuy(m5.low20, m5.low20 + 0.35 * m5.atr14);
    setSell(m5.high20 - 0.35 * m5.atr14, m5.high20);
  }
  else if (strategy === "TREND_PULLBACK_BUY") {
    const ref = Math.abs(regimeData.market.ask - m5.ema20) <= Math.abs(regimeData.market.ask - m5.ema50) ? m5.ema20 : m5.ema50;
    setBuy(ref - 0.45 * m5.atr14, ref + 0.45 * m5.atr14);
  }
  else if (strategy === "TREND_PULLBACK_SELL") {
    const ref = Math.abs(regimeData.market.bid - m5.ema20) <= Math.abs(regimeData.market.bid - m5.ema50) ? m5.ema20 : m5.ema50;
    setSell(ref - 0.45 * m5.atr14, ref + 0.45 * m5.atr14);
  }
  else if (strategy === "BREAKOUT_RETEST_BUY") {
    const level = m5.previous_high20;
    setBuy(level - 0.15 * m5.atr14, level + 0.45 * m5.atr14);
  }
  else if (strategy === "BREAKOUT_RETEST_SELL") {
    const level = m5.previous_low20;
    setSell(level - 0.45 * m5.atr14, level + 0.15 * m5.atr14);
  }
  else if (strategy === "RANGE_REVERSION") {
    const width = m30.high20 - m30.low20;
    setBuy(m30.low20, m30.low20 + 0.20 * width);
    setSell(m30.high20 - 0.20 * width, m30.high20);
  }

  return {
    analysis_id: watchOnly ? `WATCH_${regime}_${strategy}` : `AUTO_R1_${regime}_${strategy}`,
    updated_at: Date.now(),
    source: "AUTO_R1_WATCH",
    zone_type: zoneType,
    watch_only: watchOnly,
    watch_reason: watchReason,
    buy_low: buyLow,
    buy_high: buyHigh,
    sell_low: sellLow,
    sell_high: sellHigh
  };
}


// =============================================================
// PERFORMANCE ENGINE
// =============================================================

async function handlePerformanceView(
  request,
  env
) {
  const authorized =
    await isTradeAuthorized(
      request,
      env
    );

  if (!authorized) {
    return html(
      "<h2>Unauthorized</h2>",
      401
    );
  }

  const result =
    await env.DB.prepare(`
      SELECT
        analysis_id,
        created_at,
        rules_version,
        regime,
        strategy,
        decision,
        setup_score,
        pnl,
        outcome,
        duration_seconds,
        mfe_usd,
        mae_usd,
        realized_r
      FROM analysis_journal
      WHERE
        execution_status = 'closed'
        AND decision IN ('BUY','SELL')
      ORDER BY created_at ASC
    `).all();

  const allClosed =
    result.results || [];

  const excludedSystemTests =
    allClosed.filter(
      row =>
        isSystemTestStrategy(
          row.strategy
        )
    );

  const excludedInvalidStrategy =
    allClosed.filter(
      row =>
        !isSystemTestStrategy(
          row.strategy
        ) &&
        (
          !row.strategy ||
          row.strategy === "NONE" ||
          row.strategy === "NO_TRADE"
        )
    );

  const validTrades =
    allClosed.filter(
      row =>
        !isSystemTestStrategy(
          row.strategy
        ) &&
        row.strategy &&
        row.strategy !== "NONE" &&
        row.strategy !== "NO_TRADE"
    );

  const overall =
    calculatePerformanceStats(
      validTrades
    );

  const groupsMap =
    new Map();

  for (
    const row
    of validTrades
  ) {
    const regime =
      String(
        row.regime ||
        "UNKNOWN"
      );

    const strategy =
      String(
        row.strategy ||
        "UNKNOWN"
      );

    const key =
      `${regime}::${strategy}`;

    if (
      !groupsMap.has(key)
    ) {
      groupsMap.set(
        key,
        []
      );
    }

    groupsMap
      .get(key)
      .push(row);
  }

  const groups = [];

  for (
    const [key, rows]
    of groupsMap.entries()
  ) {
    const [
      regime,
      strategy
    ] =
      key.split("::");

    groups.push({
      regime,
      strategy,
      ...calculatePerformanceStats(
        rows
      )
    });
  }

  groups.sort(
    (a, b) =>
      b.trades -
      a.trades
  );

  return json({
    ok: true,

    build:
      BUILD_VERSION,

    rules_version:
      RULES_VERSION,

    generated_at:
      Date.now(),

    filters: {
      closed_only: true,
      buy_sell_only: true,
      excluded_system_test_prefix:
        "SYSTEM_TEST",
      excluded_none_strategy: true
    },

    excluded: {
      system_test_trades:
        excludedSystemTests.length,

      invalid_or_none_strategy:
        excludedInvalidStrategy.length
    },

    overall,

    strategies:
      groups
  });
}


// =============================================================
// PERFORMANCE STATISTICS
// =============================================================

function calculatePerformanceStats(
  rows
) {
  const ordered =
    [...rows]
      .sort(
        (
          a,
          b
        ) =>
          Number(
            a.created_at
          ) -
          Number(
            b.created_at
          )
      );

  const trades =
    ordered.length;

  let wins = 0;
  let losses = 0;
  let breakeven = 0;

  let netPnl = 0;
  let grossProfit = 0;
  let grossLossAbs = 0;

  const rValues = [];
  const winningR = [];
  const losingR = [];

  const mfeValues = [];
  const maeValues = [];
  const durationValues = [];

  let maxLosingStreak = 0;
  let currentLosingStreak = 0;

  for (
    const row
    of ordered
  ) {
    const pnl =
      nullableNumber(
        row.pnl
      ) ?? 0;

    netPnl += pnl;

    if (pnl > 0.01) {
      wins++;
      grossProfit += pnl;
      currentLosingStreak = 0;
    }
    else if (pnl < -0.01) {
      losses++;
      grossLossAbs +=
        Math.abs(pnl);

      currentLosingStreak++;

      if (
        currentLosingStreak >
        maxLosingStreak
      ) {
        maxLosingStreak =
          currentLosingStreak;
      }
    }
    else {
      breakeven++;
      currentLosingStreak = 0;
    }

    const r =
      nullableNumber(
        row.realized_r
      );

    if (r !== null) {
      rValues.push(r);

      if (r > 0) {
        winningR.push(r);
      }
      else if (r < 0) {
        losingR.push(r);
      }
    }

    const mfe =
      nullableNumber(
        row.mfe_usd
      );

    if (mfe !== null) {
      mfeValues.push(
        Math.abs(mfe)
      );
    }

    const mae =
      nullableNumber(
        row.mae_usd
      );

    if (mae !== null) {
      maeValues.push(
        Math.abs(mae)
      );
    }

    const duration =
      nullableNumber(
        row.duration_seconds
      );

    if (
      duration !== null &&
      duration >= 0
    ) {
      durationValues.push(
        duration
      );
    }
  }

  const winRate =
    trades > 0
      ? (
          wins /
          trades
        ) *
        100
      : 0;

  const avgR =
    average(
      rValues
    );

  const avgWinR =
    average(
      winningR
    );

  const avgLossR =
    average(
      losingR
    );

  let expectancyR = null;

  if (
    rValues.length >
    0
  ) {
    const probabilityWin =
      winningR.length /
      rValues.length;

    const probabilityLoss =
      losingR.length /
      rValues.length;

    expectancyR =
      (
        probabilityWin *
        (
          avgWinR ?? 0
        )
      ) +
      (
        probabilityLoss *
        (
          avgLossR ?? 0
        )
      );
  }

  let profitFactor = null;
  let profitFactorState = "NORMAL";

  if (
    grossLossAbs >
    0
  ) {
    profitFactor =
      grossProfit /
      grossLossAbs;
  }
  else if (
    grossProfit >
    0
  ) {
    profitFactorState =
      "NO_LOSSES";
  }
  else {
    profitFactor =
      0;
  }

  const ratingInfo =
    rateStrategyPerformance({
      trades,
      expectancyR,
      profitFactor,
      profitFactorState
    });

  return {
    trades,

    wins,

    losses,

    breakeven,

    win_rate_pct:
      roundNumber(
        winRate,
        2
      ),

    net_pnl:
      roundNumber(
        netPnl,
        2
      ),

    gross_profit:
      roundNumber(
        grossProfit,
        2
      ),

    gross_loss_abs:
      roundNumber(
        grossLossAbs,
        2
      ),

    profit_factor:
      profitFactor === null
        ? null
        : roundNumber(
            profitFactor,
            3
          ),

    profit_factor_state:
      profitFactorState,

    r_samples:
      rValues.length,

    avg_r:
      avgR === null
        ? null
        : roundNumber(
            avgR,
            3
          ),

    avg_win_r:
      avgWinR === null
        ? null
        : roundNumber(
            avgWinR,
            3
          ),

    avg_loss_r:
      avgLossR === null
        ? null
        : roundNumber(
            avgLossR,
            3
          ),

    expectancy_r:
      expectancyR === null
        ? null
        : roundNumber(
            expectancyR,
            3
          ),

    avg_mfe_usd:
      averageRounded(
        mfeValues,
        3
      ),

    avg_mae_usd:
      averageRounded(
        maeValues,
        3
      ),

    avg_duration_seconds:
      averageRounded(
        durationValues,
        1
      ),

    max_losing_streak:
      maxLosingStreak,

    rating:
      ratingInfo.rating,

    rating_reason:
      ratingInfo.reason
  };
}


// =============================================================
// STRATEGY RATING
// =============================================================

function rateStrategyPerformance({
  trades,
  expectancyR,
  profitFactor,
  profitFactorState
}) {
  if (
    trades <
    20
  ) {
    return {
      rating:
        "INSUFFICIENT_DATA",

      reason:
        "Fewer than 20 closed trades."
    };
  }

  const effectivePF =
    profitFactorState ===
    "NO_LOSSES"
      ? Infinity
      : (
          Number.isFinite(
            profitFactor
          )
            ? profitFactor
            : 0
        );

  if (
    expectancyR === null
  ) {
    return {
      rating:
        "INSUFFICIENT_DATA",

      reason:
        "Realized R data is incomplete."
    };
  }

  if (
    expectancyR <= 0 ||
    effectivePF <
    1.0
  ) {
    return {
      rating:
        "NEGATIVE",

      reason:
        "Non-positive expectancy or Profit Factor below 1.0."
    };
  }

  if (
    trades <
    30
  ) {
    if (
      expectancyR >=
      0.10 &&
      effectivePF >=
      1.15
    ) {
      return {
        rating:
          "PROMISING",

        reason:
          "Positive early sample, but fewer than 30 trades."
      };
    }

    return {
      rating:
        "WEAK",

      reason:
        "Positive but not strong enough for promotion."
    };
  }

  if (
    expectancyR >=
    0.15 &&
    effectivePF >=
    1.25
  ) {
    return {
      rating:
        "VALIDATED",

      reason:
        "30+ trades with positive expectancy and Profit Factor >= 1.25."
    };
  }

  if (
    expectancyR >=
    0.05 &&
    effectivePF >=
    1.10
  ) {
    return {
      rating:
        "PROMISING",

      reason:
        "Positive performance, but below R1 validated thresholds."
    };
  }

  return {
    rating:
      "WEAK",

    reason:
      "Positive edge is too small or inconsistent."
  };
}


// =============================================================
// SYSTEM TEST FILTER
// =============================================================

function isSystemTestStrategy(
  strategy
) {
  if (!strategy) {
    return false;
  }

  return String(strategy)
    .toUpperCase()
    .startsWith(
      "SYSTEM_TEST"
    );
}


// =============================================================
// MANUAL TRADE PAGE
// =============================================================

async function handleTradePage(
  request,
  env,
  url
) {
  if (!env.TRADE_PAGE_TOKEN) {
    return html(
      "<h2>TRADE_PAGE_TOKEN is not configured.</h2>",
      500
    );
  }

  const suppliedToken =
    url.searchParams.get("token");

  if (suppliedToken) {
    if (
      suppliedToken !==
      env.TRADE_PAGE_TOKEN
    ) {
      return html(
        "<h2>Invalid token.</h2>",
        401
      );
    }

    const cookieValue =
      await sha256(
        env.TRADE_PAGE_TOKEN
      );

    const cleanUrl =
      new URL(
        url.toString()
      );

    cleanUrl
      .searchParams
      .delete("token");

    return new Response(null, {
      status: 302,
      headers: {
        Location:
          cleanUrl.toString(),

        "Set-Cookie":
          `trade_auth=${cookieValue}; ` +
          "Path=/; " +
          "Max-Age=2592000; " +
          "HttpOnly; " +
          "Secure; " +
          "SameSite=Strict"
      }
    });
  }

  const authorized =
    await isTradeAuthorized(
      request,
      env
    );

  if (!authorized) {
    return html(`
      <h2>Trade page is locked</h2>
      <p>Open once with your token.</p>
    `, 401);
  }

  const marketInfo =
    await getCurrentMarketInfo(
      env
    );

  const side =
    String(
      url.searchParams.get(
        "side"
      ) || "BUY"
    ).toUpperCase();

  const entry =
    url.searchParams.get(
      "entry"
    ) ||
    (
      side === "BUY"
        ? marketInfo.ask
        : marketInfo.bid
    );

  const sl =
    url.searchParams.get(
      "sl"
    ) || "";

  const tp =
    url.searchParams.get(
      "tp"
    ) || "";

  return html(`
<!doctype html>

<html>
<head>
<meta charset="utf-8">

<meta
  name="viewport"
  content="width=device-width,initial-scale=1"
>

<title>XAU Trade Bridge</title>
</head>

<body style="
  font-family:Arial;
  background:#111827;
  color:white;
  padding:40px;
">

<h1>XAUUSD Signal</h1>

<form
  method="POST"
  action="/trade/submit"
>

<input
  type="hidden"
  name="signal_id"
  value="${crypto.randomUUID()}"
>

<input
  type="hidden"
  name="symbol"
  value="XAUUSD.s"
>

<p>
Side:
<input
  name="side"
  value="${escapeHtml(side)}"
>
</p>

<p>
Entry:
<input
  name="entry_price"
  value="${escapeHtml(entry)}"
>
</p>

<p>
SL:
<input
  name="sl"
  value="${escapeHtml(sl)}"
>
</p>

<p>
TP:
<input
  name="tp"
  value="${escapeHtml(tp)}"
>
</p>

<input
  type="hidden"
  name="ttl_seconds"
  value="60"
>

<button type="submit">
Send to MT5
</button>

</form>

</body>
</html>
  `);
}


// =============================================================
// SIGNAL SENT PAGE
// =============================================================

function signalSentPage(
  side,
  symbol,
  entry,
  sl,
  tp,
  duplicate
) {
  return html(`
<body style="
  font-family:Arial;
  background:#111827;
  color:white;
  text-align:center;
  padding:60px;
">

<h1>
${
  duplicate
    ? "Signal already sent ✅"
    : "Signal sent to MT5 ✅"
}
</h1>

<p>
${escapeHtml(side)}
${escapeHtml(symbol)}
</p>

<p>
Entry:
${escapeHtml(entry)}
</p>

<p>
SL:
${escapeHtml(sl)}
</p>

<p>
TP:
${escapeHtml(tp)}
</p>

</body>
  `);
}


// =============================================================
// CURRENT MARKET INFO
// =============================================================

async function getCurrentMarketInfo(
  env
) {
  const row =
    await env.DB.prepare(`
      SELECT payload
      FROM latest_market
      WHERE id = 1
    `).first();

  if (!row) {
    return {
      generatedAt: null,
      bid: null,
      ask: null
    };
  }

  try {
    const market =
      JSON.parse(
        row.payload
      );

    return {
      generatedAt:
        market.generated_at ??
        null,

      bid:
        market.bid ??
        null,

      ask:
        market.ask ??
        null
    };
  } catch {
    return {
      generatedAt: null,
      bid: null,
      ask: null
    };
  }
}


// =============================================================
// EXPIRE OLD SIGNALS
// =============================================================

async function expireOldSignals(
  env,
  symbol
) {
  await env.DB.prepare(`
    UPDATE trade_signals
    SET status = 'expired'
    WHERE
      symbol = ?1
      AND status = 'pending'
  `)
    .bind(symbol)
    .run();
}


// =============================================================
// AUTH
// =============================================================

async function isTradeAuthorized(
  request,
  env
) {
  if (!env.TRADE_PAGE_TOKEN) {
    return false;
  }

  const cookie =
    getCookie(
      request,
      "trade_auth"
    );

  if (!cookie) {
    return false;
  }

  const expected =
    await sha256(
      env.TRADE_PAGE_TOKEN
    );

  return (
    cookie ===
    expected
  );
}


function getCookie(
  request,
  name
) {
  const header =
    request.headers.get(
      "Cookie"
    ) || "";

  const cookies =
    header.split(";");

  for (
    const cookie
    of cookies
  ) {
    const parts =
      cookie
        .trim()
        .split("=");

    if (
      parts[0] ===
      name
    ) {
      return parts
        .slice(1)
        .join("=");
    }
  }

  return "";
}


async function sha256(
  text
) {
  const encoded =
    new TextEncoder()
      .encode(text);

  const digest =
    await crypto.subtle.digest(
      "SHA-256",
      encoded
    );

  return [
    ...new Uint8Array(digest)
  ]
    .map(
      b =>
        b
          .toString(16)
          .padStart(2, "0")
    )
    .join("");
}


// =============================================================
// SIGNAL VALIDATION
// =============================================================

function validateSignal(
  symbol,
  side,
  entry,
  sl,
  tp
) {
  if (
    symbol !==
    "XAUUSD.s"
  ) {
    return {
      ok: false,
      error:
        "Only XAUUSD.s is allowed"
    };
  }

  if (
    side !== "BUY" &&
    side !== "SELL"
  ) {
    return {
      ok: false,
      error:
        "Invalid side"
    };
  }

  if (
    !Number.isFinite(entry) ||
    !Number.isFinite(sl) ||
    !Number.isFinite(tp)
  ) {
    return {
      ok: false,
      error:
        "Invalid Entry, SL or TP"
    };
  }

  if (
    side === "BUY" &&
    !(
      sl <
      entry &&
      entry <
      tp
    )
  ) {
    return {
      ok: false,
      error:
        "BUY requires SL < Entry < TP"
    };
  }

  if (
    side === "SELL" &&
    !(
      tp <
      entry &&
      entry <
      sl
    )
  ) {
    return {
      ok: false,
      error:
        "SELL requires TP < Entry < SL"
    };
  }

  return {
    ok: true
  };
}


// =============================================================
// REGIME ENGINE R1
// =============================================================

async function calculateRegimeR1(
  env
) {
  const row =
    await env.DB.prepare(`
      SELECT
        payload,
        updated_at
      FROM latest_market
      WHERE id = 1
    `).first();

  if (!row) {
    throw new Error(
      "No market data"
    );
  }

  const market =
    JSON.parse(
      row.payload
    );

  const generatedAt =
    Number(
      market.generated_at
    );

  if (
    !Number.isFinite(
      generatedAt
    )
  ) {
    throw new Error(
      "Invalid generated_at"
    );
  }

  const h1 =
    buildTimeframeMetrics(
      market.H1,
      generatedAt,
      3600
    );

  const m30 =
    buildTimeframeMetrics(
      market.M30,
      generatedAt,
      1800
    );

  const m15 =
    buildTimeframeMetrics(
      market.M15,
      generatedAt,
      900
    );

  const m5 =
    buildTimeframeMetrics(
      market.M5,
      generatedAt,
      300
    );

  const m1 =
    buildTimeframeMetrics(
      market.M1,
      generatedAt,
      60
    );

  if (
    !h1 ||
    !m30 ||
    !m15 ||
    !m5 ||
    !m1
  ) {
    throw new Error(
      "Not enough closed candles"
    );
  }

  // ===========================================================
  // HIGH VOLATILITY
  // ===========================================================
  const highVolatility =
    (
      m5.atr_ratio >=
      1.80
    ) ||
    (
      m5.last_range >=
      (
        m5.atr14 *
        2.20
      )
    );

  // ===========================================================
  // BREAKOUT UP
  // ===========================================================
  const breakoutUp =
    (
      m5.close >
      (
        m5.previous_high20 +
        (
          m5.atr14 *
          0.10
        )
      )
    ) &&
    (
      m5.body >=
      (
        m5.atr14 *
        0.55
      )
    ) &&
    (
      m5.close_position >=
      0.75
    ) &&
    (
      m15.close >
      m15.ema20
    );

  // ===========================================================
  // BREAKOUT DOWN
  // ===========================================================
  const breakoutDown =
    (
      m5.close <
      (
        m5.previous_low20 -
        (
          m5.atr14 *
          0.10
        )
      )
    ) &&
    (
      m5.body >=
      (
        m5.atr14 *
        0.55
      )
    ) &&
    (
      m5.close_position <=
      0.25
    ) &&
    (
      m15.close <
      m15.ema20
    );

  // ===========================================================
  // TREND UP
  // ===========================================================
  const trendUp =
    (
      h1.close >
      h1.ema20
    ) &&
    (
      h1.ema20 >
      h1.ema50
    ) &&
    (
      h1.ema20_slope_atr >
      0.05
    ) &&

    (
      m30.close >
      m30.ema20
    ) &&
    (
      m30.ema20 >
      m30.ema50
    ) &&
    (
      m30.ema20_slope_atr >
      0.05
    ) &&

    (
      m15.close >
      m15.ema20
    ) &&
    (
      m15.rsi14 >=
      52
    );

  // ===========================================================
  // TREND DOWN
  // ===========================================================
  const trendDown =
    (
      h1.close <
      h1.ema20
    ) &&
    (
      h1.ema20 <
      h1.ema50
    ) &&
    (
      h1.ema20_slope_atr <
      -0.05
    ) &&

    (
      m30.close <
      m30.ema20
    ) &&
    (
      m30.ema20 <
      m30.ema50
    ) &&
    (
      m30.ema20_slope_atr <
      -0.05
    ) &&

    (
      m15.close <
      m15.ema20
    ) &&
    (
      m15.rsi14 <=
      48
    );

  // ===========================================================
  // RANGE
  // ===========================================================
  const range =
    (
      m30.ema_sep_atr <
      0.25
    ) &&
    (
      Math.abs(
        m30.ema20_slope_atr
      ) <
      0.10
    ) &&
    (
      m30.rsi14 >=
      43
    ) &&
    (
      m30.rsi14 <=
      57
    ) &&
    (
      m30.range_width_atr >=
      2.0
    ) &&
    (
      m30.range_width_atr <=
      6.0
    ) &&
    (
      m30.upper_touches >=
      2
    ) &&
    (
      m30.lower_touches >=
      2
    );

  // ===========================================================
  // PRIORITY
  // ===========================================================
  let regime =
    "TRANSITION";

  let strategy =
    "NONE";

  if (highVolatility) {
    regime =
      "HIGH_VOLATILITY";

    strategy =
      "NO_TRADE";
  }
  else if (breakoutUp) {
    regime =
      "BREAKOUT_UP";

    strategy =
      "BREAKOUT_RETEST_BUY";
  }
  else if (breakoutDown) {
    regime =
      "BREAKOUT_DOWN";

    strategy =
      "BREAKOUT_RETEST_SELL";
  }
  else if (trendUp) {
    regime =
      "TREND_UP";

    strategy =
      "TREND_PULLBACK_BUY";
  }
  else if (trendDown) {
    regime =
      "TREND_DOWN";

    strategy =
      "TREND_PULLBACK_SELL";
  }
  else if (range) {
    regime =
      "RANGE";

    strategy =
      "RANGE_REVERSION";
  }

  const regimeScore =
    calculateRegimeScore(
      regime,
      h1,
      m30,
      m15,
      m5
    );

  return {
    market: {
      bid:
        Number(
          market.bid
        ),

      ask:
        Number(
          market.ask
        ),

      spread_points:
        Number(
          market.spread_points
        ),

      generated_at:
        generatedAt,

      cloud_updated_at:
        Number(
          row.updated_at
        )
    },

    regime,

    strategy,

    regime_score:
      regimeScore,

    metrics: {
      h1,
      m30,
      m15,
      m5,
      m1
    }
  };
}


// =============================================================
// REGIME SIDE PERMISSION
// =============================================================

function regimeAllowsSide(
  regime,
  strategy,
  side
) {
  if (
    regime ===
    "HIGH_VOLATILITY"
  ) {
    return {
      allowed: false,
      reason:
        "R1 blocks HIGH_VOLATILITY."
    };
  }

  if (
    regime ===
    "TRANSITION"
  ) {
    return {
      allowed: false,
      reason:
        "R1 blocks TRANSITION."
    };
  }

  if (
    regime ===
    "TREND_UP"
  ) {
    return {
      allowed:
        side === "BUY",

      reason:
        side === "BUY"
          ? "TREND_UP aligned."
          : "SELL conflicts with TREND_UP."
    };
  }

  if (
    regime ===
    "TREND_DOWN"
  ) {
    return {
      allowed:
        side === "SELL",

      reason:
        side === "SELL"
          ? "TREND_DOWN aligned."
          : "BUY conflicts with TREND_DOWN."
    };
  }

  if (
    regime ===
    "BREAKOUT_UP"
  ) {
    return {
      allowed:
        side === "BUY",

      reason:
        side === "BUY"
          ? "BREAKOUT_UP aligned."
          : "SELL conflicts with BREAKOUT_UP."
    };
  }

  if (
    regime ===
    "BREAKOUT_DOWN"
  ) {
    return {
      allowed:
        side === "SELL",

      reason:
        side === "SELL"
          ? "BREAKOUT_DOWN aligned."
          : "BUY conflicts with BREAKOUT_DOWN."
    };
  }

  if (
    regime ===
    "RANGE"
  ) {
    return {
      allowed: true,
      reason:
        "RANGE direction requires edge validation."
    };
  }

  return {
    allowed: false,
    reason:
      "Unknown regime."
  };
}


// =============================================================
// SETUP ENGINE R1
// =============================================================

function calculateSetupR1(
  regimeData,
  side,
  entry,
  sl,
  tp
) {
  const regime =
    regimeData.regime;

  const strategy =
    regimeData.strategy;

  const market =
    regimeData.market;

  const m30 =
    regimeData.metrics.m30;

  const m15 =
    regimeData.metrics.m15;

  const m5 =
    regimeData.metrics.m5;

  const m1 =
    regimeData.metrics.m1;

  const reasons = [];

  const initialRiskUsd =
    Math.abs(
      entry -
      sl
    );

  const rewardUsd =
    Math.abs(
      tp -
      entry
    );

  const plannedRR =
    initialRiskUsd > 0
      ? rewardUsd /
        initialRiskUsd
      : 0;

  const currentPrice =
    side === "BUY"
      ? market.ask
      : market.bid;

  const entryDriftUsd =
    Math.abs(
      currentPrice -
      entry
    );

  const marketAgeSeconds =
    Math.max(
      0,
      (
        Date.now() -
        market.cloud_updated_at
      ) /
      1000
    );

  const supportCandidates = [
    m5.low20,
    m15.low20,
    m30.low20
  ];

  const resistanceCandidates = [
    m5.high20,
    m15.high20,
    m30.high20
  ];

  const keySupport =
    nearestBelow(
      entry,
      supportCandidates
    );

  const keyResistance =
    nearestAbove(
      entry,
      resistanceCandidates
    );

  let cleanRoomUsd =
    rewardUsd;

  if (
    side === "BUY" &&
    keyResistance !== null
  ) {
    cleanRoomUsd =
      Math.min(
        rewardUsd,
        Math.max(
          0,
          keyResistance -
          entry
        )
      );
  }

  if (
    side === "SELL" &&
    keySupport !== null
  ) {
    cleanRoomUsd =
      Math.min(
        rewardUsd,
        Math.max(
          0,
          entry -
          keySupport
        )
      );
  }

  const permission =
    regimeAllowsSide(
      regime,
      strategy,
      side
    );

  let setupScore = 0;

  if (
    permission.allowed
  ) {
    setupScore += 30;
  }
  else {
    reasons.push(
      permission.reason
    );
  }

  let structurePass =
    false;

  let structureReason =
    "";

  let trigger =
    "NONE";

  // ===========================================================
  // TREND PULLBACK BUY
  // ===========================================================
  if (
    strategy ===
    "TREND_PULLBACK_BUY" &&
    side === "BUY"
  ) {
    const distanceToEMA20 =
      m5.atr14 > 0
        ? Math.abs(
            entry -
            m5.ema20
          ) /
          m5.atr14
        : 999;

    const distanceToEMA50 =
      m5.atr14 > 0
        ? Math.abs(
            entry -
            m5.ema50
          ) /
          m5.atr14
        : 999;

    const pullbackDistance =
      Math.min(
        distanceToEMA20,
        distanceToEMA50
      );

    structurePass =
      (
        pullbackDistance <=
        0.45
      ) &&
      (
        m5.close >=
        m5.ema50
      );

    structureReason =
      structurePass
        ? "Valid bullish pullback zone."
        : "Price is not in a valid bullish pullback zone.";
  }

  // ===========================================================
  // TREND PULLBACK SELL
  // ===========================================================
  else if (
    strategy ===
    "TREND_PULLBACK_SELL" &&
    side === "SELL"
  ) {
    const distanceToEMA20 =
      m5.atr14 > 0
        ? Math.abs(
            entry -
            m5.ema20
          ) /
          m5.atr14
        : 999;

    const distanceToEMA50 =
      m5.atr14 > 0
        ? Math.abs(
            entry -
            m5.ema50
          ) /
          m5.atr14
        : 999;

    const pullbackDistance =
      Math.min(
        distanceToEMA20,
        distanceToEMA50
      );

    structurePass =
      (
        pullbackDistance <=
        0.45
      ) &&
      (
        m5.close <=
        m5.ema50
      );

    structureReason =
      structurePass
        ? "Valid bearish pullback zone."
        : "Price is not in a valid bearish pullback zone.";
  }

  // ===========================================================
  // BREAKOUT RETEST BUY
  // ===========================================================
  else if (
    strategy ===
    "BREAKOUT_RETEST_BUY" &&
    side === "BUY"
  ) {
    const breakoutLevel =
      m5.previous_high20;

    const distance =
      m5.atr14 > 0
        ? Math.abs(
            entry -
            breakoutLevel
          ) /
          m5.atr14
        : 999;

    structurePass =
      (
        distance <=
        0.45
      ) &&
      (
        entry >=
        (
          breakoutLevel -
          (
            m5.atr14 *
            0.15
          )
        )
      );

    structureReason =
      structurePass
        ? "Valid bullish breakout retest."
        : "No valid bullish breakout retest.";
  }

  // ===========================================================
  // BREAKOUT RETEST SELL
  // ===========================================================
  else if (
    strategy ===
    "BREAKOUT_RETEST_SELL" &&
    side === "SELL"
  ) {
    const breakoutLevel =
      m5.previous_low20;

    const distance =
      m5.atr14 > 0
        ? Math.abs(
            entry -
            breakoutLevel
          ) /
          m5.atr14
        : 999;

    structurePass =
      (
        distance <=
        0.45
      ) &&
      (
        entry <=
        (
          breakoutLevel +
          (
            m5.atr14 *
            0.15
          )
        )
      );

    structureReason =
      structurePass
        ? "Valid bearish breakout retest."
        : "No valid bearish breakout retest.";
  }

  // ===========================================================
  // RANGE BUY
  // ===========================================================
  else if (
    strategy ===
    "RANGE_REVERSION" &&
    side === "BUY"
  ) {
    const rangeWidth =
      m30.high20 -
      m30.low20;

    const position =
      rangeWidth > 0
        ? (
            entry -
            m30.low20
          ) /
          rangeWidth
        : 0.5;

    structurePass =
      position <=
      0.20;

    structureReason =
      structurePass
        ? "BUY is near lower range edge."
        : "BUY is not near lower range edge.";
  }

  // ===========================================================
  // RANGE SELL
  // ===========================================================
  else if (
    strategy ===
    "RANGE_REVERSION" &&
    side === "SELL"
  ) {
    const rangeWidth =
      m30.high20 -
      m30.low20;

    const position =
      rangeWidth > 0
        ? (
            entry -
            m30.low20
          ) /
          rangeWidth
        : 0.5;

    structurePass =
      position >=
      0.80;

    structureReason =
      structurePass
        ? "SELL is near upper range edge."
        : "SELL is not near upper range edge.";
  }
  else {
    structureReason =
      "No valid R1 strategy structure.";
  }

  if (structurePass) {
    setupScore += 20;
  }
  else {
    reasons.push(
      structureReason
    );
  }

  // ===========================================================
  // M1 TRIGGER
  // ===========================================================
  let triggerPass =
    false;

  if (side === "BUY") {
    triggerPass =
      (
        m1.close >
        m1.ema9
      ) &&
      (
        m1.rsi14 >=
        52
      ) &&
      (
        m1.close_position >=
        0.55
      );

    if (triggerPass) {
      trigger =
        "M1_BULLISH_CONFIRMATION";
    }
  }

  if (side === "SELL") {
    triggerPass =
      (
        m1.close <
        m1.ema9
      ) &&
      (
        m1.rsi14 <=
        48
      ) &&
      (
        m1.close_position <=
        0.45
      );

    if (triggerPass) {
      trigger =
        "M1_BEARISH_CONFIRMATION";
    }
  }

  if (triggerPass) {
    setupScore += 20;
  }
  else {
    reasons.push(
      "M1 entry trigger is not confirmed."
    );
  }

  // ===========================================================
  // ROOM
  // ===========================================================
  const roomPass =
    (
      rewardUsd >= 7.0
    ) &&
    (
      cleanRoomUsd >= 7.0
    );

  if (roomPass) {
    setupScore += 15;
  }
  else {
    if (rewardUsd < 7.0) {
      reasons.push(
        "TP1 is less than $7 from entry."
      );
    }

    if (cleanRoomUsd < 7.0) {
      reasons.push(
        "Less than $7 clean structural room."
      );
    }
  }

  // ===========================================================
  // VOLATILITY + SPREAD
  // ===========================================================
  const volatilityPass =
    (
      m5.atr_ratio >=
      0.65
    ) &&
    (
      m5.atr_ratio <=
      1.60
    ) &&
    (
      market.spread_points <=
      30
    );

  if (volatilityPass) {
    setupScore += 10;
  }
  else {
    reasons.push(
      "ATR or spread is outside R1 limits."
    );
  }

  // ===========================================================
  // FRESHNESS
  // ===========================================================
  const freshnessPass =
    marketAgeSeconds <=
    30;

  if (freshnessPass) {
    setupScore += 5;
  }
  else {
    reasons.push(
      "Market snapshot is stale."
    );
  }

  // ===========================================================
  // RR
  // ===========================================================
  const rrPass =
    plannedRR >=
    1.30;

  if (!rrPass) {
    reasons.push(
      "Planned RR is below 1.30."
    );
  }

  // ===========================================================
  // ENTRY DRIFT
  // ===========================================================
  const driftPass =
    entryDriftUsd <=
    1.00;

  if (!driftPass) {
    reasons.push(
      "Reference entry is more than $1 from current market."
    );
  }

  // ===========================================================
  // FINAL
  // ===========================================================
  const allowed =
    (
      permission.allowed
    ) &&
    structurePass &&
    triggerPass &&
    roomPass &&
    volatilityPass &&
    freshnessPass &&
    rrPass &&
    driftPass &&
    (
      setupScore >=
      75
    );

  if (allowed) {
    reasons.push(
      "SETUP_R1_PASSED"
    );
  }

  return {
    allowed,

    setup_score:
      Math.min(
        100,
        Math.max(
          0,
          Math.round(
            setupScore
          )
        )
      ),

    regime,

    strategy,

    side,

    trigger,

    initial_risk_usd:
      roundNumber(
        initialRiskUsd,
        2
      ),

    reward_usd:
      roundNumber(
        rewardUsd,
        2
      ),

    planned_rr:
      roundNumber(
        plannedRR,
        3
      ),

    clean_room_usd:
      roundNumber(
        cleanRoomUsd,
        2
      ),

    entry_drift_usd:
      roundNumber(
        entryDriftUsd,
        2
      ),

    market_age_seconds:
      roundNumber(
        marketAgeSeconds,
        1
      ),

    key_support:
      keySupport,

    key_resistance:
      keyResistance,

    structure_pass:
      structurePass,

    trigger_pass:
      triggerPass,

    room_pass:
      roomPass,

    volatility_pass:
      volatilityPass,

    freshness_pass:
      freshnessPass,

    rr_pass:
      rrPass,

    drift_pass:
      driftPass,

    reasons
  };
}


// =============================================================
// LEVEL HELPERS
// =============================================================


// =============================================================
// R2 SWING ENGINE v1
// R1 remains untouched. R2 is analysis-only in this build.
// =============================================================

async function calculateR2Swing(env) {
  const row = await env.DB.prepare(`
    SELECT payload, updated_at
    FROM latest_market
    WHERE id = 1
  `).first();

  if (!row) throw new Error("No market data");

  const market = JSON.parse(row.payload);
  const generatedAt = Number(market.generated_at);
  if (!Number.isFinite(generatedAt)) throw new Error("Invalid generated_at");

  const h1 = buildTimeframeMetrics(market.H1, generatedAt, 3600);
  const m30 = buildTimeframeMetrics(market.M30, generatedAt, 1800);
  const m15 = buildTimeframeMetrics(market.M15, generatedAt, 900);
  const m5 = buildTimeframeMetrics(market.M5, generatedAt, 300);
  const m1 = buildTimeframeMetrics(market.M1, generatedAt, 60);
  if (!h1 || !m30 || !m15 || !m5 || !m1) throw new Error("Not enough closed candles");

  const marketInfo = {
    bid: Number(market.bid),
    ask: Number(market.ask),
    spread_points: Number(market.spread_points),
    generated_at: generatedAt,
    cloud_updated_at: Number(row.updated_at),
    market_age_seconds: roundNumber(Math.max(0, (Date.now() - Number(row.updated_at)) / 1000), 1)
  };

  const highVol = m15.atr_ratio >= 1.80 || m15.last_range >= m15.atr14 * 2.20;
  const trendUp = h1.close > h1.ema20 && h1.ema20_slope_atr >= -0.02 && m30.close > m30.ema20 && m30.ema20_slope_atr >= -0.03;
  const trendDown = h1.close < h1.ema20 && h1.ema20_slope_atr <= 0.02 && m30.close < m30.ema20 && m30.ema20_slope_atr <= 0.03;
  const rangeState = m30.ema_sep_atr < 0.35 && Math.abs(m30.ema20_slope_atr) < 0.12 && m30.rsi14 >= 40 && m30.rsi14 <= 60 && m30.upper_touches >= 2 && m30.lower_touches >= 2;

  const breakoutUp = r2BreakoutStrength("BUY", m15, m30, h1, marketInfo);
  const breakoutDown = r2BreakoutStrength("SELL", m15, m30, h1, marketInfo);

  let marketState = "SWING_TRANSITION";
  if (breakoutUp.confirmed && breakoutUp.score >= 70) marketState = "SWING_BREAKOUT_UP";
  else if (breakoutDown.confirmed && breakoutDown.score >= 70) marketState = "SWING_BREAKOUT_DOWN";
  else if (trendUp) marketState = "SWING_TREND_UP";
  else if (trendDown) marketState = "SWING_TREND_DOWN";
  else if (rangeState) marketState = "SWING_RANGE";
  else if (highVol) marketState = "SWING_HIGH_VOLATILITY";

  const candidates = [];

  if (marketState === "SWING_TREND_UP" || (highVol && trendUp)) {
    candidates.push(r2PullbackCandidate("BUY", marketInfo, h1, m30, m15, m5, highVol));
    candidates.push(r2BreakoutCandidate("BUY", marketInfo, h1, m30, m15, m5, breakoutUp, highVol));
  }
  else if (marketState === "SWING_TREND_DOWN" || (highVol && trendDown)) {
    candidates.push(r2PullbackCandidate("SELL", marketInfo, h1, m30, m15, m5, highVol));
    candidates.push(r2BreakoutCandidate("SELL", marketInfo, h1, m30, m15, m5, breakoutDown, highVol));
  }
  else if (marketState === "SWING_BREAKOUT_UP") {
    candidates.push(r2BreakoutCandidate("BUY", marketInfo, h1, m30, m15, m5, breakoutUp, highVol));
    candidates.push(r2RetestCandidate("BUY", marketInfo, h1, m30, m15, m5, breakoutUp, highVol));
  }
  else if (marketState === "SWING_BREAKOUT_DOWN") {
    candidates.push(r2BreakoutCandidate("SELL", marketInfo, h1, m30, m15, m5, breakoutDown, highVol));
    candidates.push(r2RetestCandidate("SELL", marketInfo, h1, m30, m15, m5, breakoutDown, highVol));
  }
  else if (marketState === "SWING_RANGE") {
    candidates.push(r2RangeCandidate("BUY", marketInfo, h1, m30, m15, m5));
    candidates.push(r2RangeCandidate("SELL", marketInfo, h1, m30, m15, m5));
  }
  else {
    const upCompression = r2BreakoutCandidate("BUY", marketInfo, h1, m30, m15, m5, breakoutUp, highVol);
    const downCompression = r2BreakoutCandidate("SELL", marketInfo, h1, m30, m15, m5, breakoutDown, highVol);
    if (upCompression.score >= 80) candidates.push(upCompression);
    if (downCompression.score >= 80) candidates.push(downCompression);
  }

  const usable = candidates.filter(Boolean).sort((a, b) => b.score - a.score);
  const best = r2SelectBestCandidate(usable, marketState);

  return {
    market: marketInfo,
    market_state: marketState,
    high_volatility: highVol,
    selector: {
      selected_strategy: best ? best.strategy : "NONE",
      selected_order_type: best ? best.order_type : "NONE",
      strategy_locked: !!(best && best.allowed),
      minimum_score: 70,
      candidates: usable.map(c => ({
        strategy: c.strategy,
        side: c.side,
        order_type: c.order_type,
        score: c.score,
        allowed: c.allowed,
        rr_tp1: c.rr_tp1
      }))
    },
    setup: best || r2NoTrade("No R2 setup reached the minimum score or structural requirements."),
    metrics: { h1, m30, m15, m5, m1 }
  };
}

function r2BreakoutStrength(side, m15, m30, h1, market) {
  const level = side === "BUY" ? m15.previous_high20 : m15.previous_low20;
  const atr = Math.max(m15.atr14, 0.01);
  const beyond = side === "BUY" ? m15.close - level : level - m15.close;
  const bodyPass = m15.body >= 0.55 * atr;
  const closePass = side === "BUY" ? m15.close_position >= 0.75 : m15.close_position <= 0.25;
  const closeBeyond = beyond > 0;
  const htfAligned = side === "BUY" ? (h1.close > h1.ema20 || m30.close > m30.ema20) : (h1.close < h1.ema20 || m30.close < m30.ema20);
  const compression = side === "BUY"
    ? (m15.upper_touches >= 2 || (m15.high20 - m15.close) <= 0.35 * atr)
    : (m15.lower_touches >= 2 || (m15.close - m15.low20) <= 0.35 * atr);

  let score = 0;
  if (compression) score += 20;
  if (Number.isFinite(level)) score += 20;
  if (bodyPass && closePass && closeBeyond) score += 20;
  else if (closeBeyond) score += 10;
  if (htfAligned) score += 15;
  if (side === "BUY" ? m15.rsi14 >= 52 : m15.rsi14 <= 48) score += 10;
  if (market.spread_points <= 30) score += 5;
  if (Math.abs(beyond) <= 0.80 * atr || !closeBeyond) score += 10;

  const grade = score >= 80 ? "A" : score >= 70 ? "B" : "C";
  return { confirmed: closeBeyond && bodyPass && closePass, score: Math.min(100, score), grade, level, compression };
}

function r2PullbackCandidate(side, market, h1, m30, m15, m5, highVol) {
  const buy = side === "BUY";
  const current = buy ? market.ask : market.bid;
  const atr = Math.max(m15.atr14, 0.01);
  const refs = buy
    ? [m15.ema20, m15.ema50, m30.ema20, m15.low20]
    : [m15.ema20, m15.ema50, m30.ema20, m15.high20];

  const directionalRefs = refs.filter(x => Number.isFinite(x) && (buy ? x <= current + 0.15 * atr : x >= current - 0.15 * atr));
  const center = (directionalRefs.length ? directionalRefs : refs).sort((a,b) => Math.abs(a-current)-Math.abs(b-current))[0];
  const halfWidth = 0.20 * atr;
  const zoneLow = center - halfWidth;
  const zoneHigh = center + halfWidth;
  const inZone = current >= zoneLow && current <= zoneHigh;
  const entry = roundNumber(inZone ? current : center, 2);

  const invalidation = buy ? Math.min(m15.low20, m30.low20) : Math.max(m15.high20, m30.high20);
  const sl = roundNumber(buy ? invalidation - 0.20 * atr : invalidation + 0.20 * atr, 2);
  const risk = Math.abs(entry - sl);
  const structuralTarget1 = buy ? Math.max(m15.high20, m30.close) : Math.min(m15.low20, m30.close);
  let tp1 = structuralTarget1;
  if (risk > 0 && Math.abs(tp1-entry)/risk < 1.30) tp1 = buy ? entry + 1.30*risk : entry - 1.30*risk;
  const tp2 = buy ? Math.max(m30.high20, entry + 2.0*risk) : Math.min(m30.low20, entry - 2.0*risk);
  const rr1 = risk > 0 ? Math.abs(tp1-entry)/risk : 0;

  let score = 0;
  const h1Bias = buy ? h1.close > h1.ema20 : h1.close < h1.ema20;
  const m30Align = buy ? m30.close >= m30.ema20 : m30.close <= m30.ema20;
  const valueGood = Math.abs(current-center) <= 0.75*atr || !inZone;
  const m5Behavior = buy ? (m5.close >= m5.ema20 || m5.rsi14 >= 50) : (m5.close <= m5.ema20 || m5.rsi14 <= 50);
  if (h1Bias) score += 25;
  if (m30Align) score += 20;
  if (valueGood) score += 20;
  if (Math.abs(center-m15.ema20) <= 0.35*atr || Math.abs(center-m30.ema20) <= 0.35*atr) score += 10;
  if (m5Behavior) score += 10;
  if (rr1 >= 1.30) score += 10;
  if (market.spread_points <= 30 && market.market_age_seconds <= 30) score += 5;
  if (highVol) score = Math.max(0, score - 5);

  const allowed = score >= 70 && rr1 >= 1.30 && risk > 0;
  return r2Candidate({
    strategy: buy ? "PULLBACK_BUY" : "PULLBACK_SELL",
    side,
    order_type: inZone ? (buy ? "BUY" : "SELL") : (buy ? "BUY_LIMIT" : "SELL_LIMIT"),
    score,
    allowed,
    entry, sl, tp1: roundNumber(tp1,2), tp2: roundNumber(tp2,2), rr1,
    expiry_hours: highVol ? 4 : (score >= 80 ? 12 : 8),
    zone_low: roundNumber(zoneLow,2), zone_high: roundNumber(zoneHigh,2),
    invalidation: roundNumber(invalidation,2),
    notes: ["H1/M30 trend pullback", inZone ? "Price is already inside value zone" : "Prefer limit entry at value zone"]
  });
}

function r2BreakoutCandidate(side, market, h1, m30, m15, m5, strength, highVol) {
  const buy = side === "BUY";
  const atr = Math.max(m15.atr14, 0.01);
  const grade = strength.grade;
  const factor = highVol ? 0.15 : grade === "A" ? 0.08 : 0.12;
  const spreadUsd = Math.max(0, market.spread_points * 0.01);
  const buffer = Math.max(factor*atr, 2*spreadUsd);
  const level = strength.level;
  const entry = roundNumber(buy ? level + buffer : level - buffer, 2);
  const invalidation = buy ? m15.low20 : m15.high20;
  const sl = roundNumber(buy ? invalidation - 0.20*atr : invalidation + 0.20*atr, 2);
  const risk = Math.abs(entry-sl);
  const t1struct = buy ? m30.high20 : m30.low20;
  let tp1 = t1struct;
  if (risk > 0 && Math.abs(tp1-entry)/risk < 1.30) tp1 = buy ? entry + 1.30*risk : entry - 1.30*risk;
  const tp2 = buy ? Math.max(h1.high20, entry + 2.0*risk) : Math.min(h1.low20, entry - 2.0*risk);
  const rr1 = risk > 0 ? Math.abs(tp1-entry)/risk : 0;

  let score = strength.score;
  const roomGood = rr1 >= 1.30;
  if (!roomGood) score = Math.max(0, score-10);
  const riskGood = risk >= 0.60*atr && risk <= 1.50*atr;
  const chase = buy ? market.ask > entry + 0.60*atr : market.bid < entry - 0.60*atr;
  const allowed = score >= 70 && roomGood && riskGood && !chase && grade !== "C";
  return r2Candidate({
    strategy: buy ? "BREAKOUT_BUY" : "BREAKOUT_SELL",
    side,
    order_type: buy ? "BUY_STOP" : "SELL_STOP",
    score, allowed, entry, sl, tp1: roundNumber(tp1,2), tp2: roundNumber(tp2,2), rr1,
    expiry_hours: highVol ? 3 : grade === "A" ? 6 : 4,
    breakout_level: roundNumber(level,2), breakout_grade: grade, breakout_buffer: roundNumber(buffer,2),
    invalidation: roundNumber(invalidation,2),
    notes: [strength.compression ? "Compression present" : "Compression weak", `Breakout grade ${grade}`, chase ? "Do not chase: price extended past stop-entry zone" : "Stop-entry remains structurally usable"]
  });
}

function r2RetestCandidate(side, market, h1, m30, m15, m5, strength, highVol) {
  const buy = side === "BUY";
  const current = buy ? market.ask : market.bid;
  const atr = Math.max(m15.atr14, 0.01);
  const level = strength.level;
  const width = (highVol ? 0.30 : strength.grade === "A" ? 0.15 : 0.20) * atr;
  const zoneLow = level - width;
  const zoneHigh = level + width;
  const inZone = current >= zoneLow && current <= zoneHigh;
  const held = buy ? m15.close >= level - 0.20*atr : m15.close <= level + 0.20*atr;
  const confirm = buy ? (m5.close >= m5.ema20 && m5.rsi14 >= 50) : (m5.close <= m5.ema20 && m5.rsi14 <= 50);
  const entry = roundNumber(inZone && confirm ? current : level, 2);
  const invalidation = buy ? Math.min(m15.low20, level-0.45*atr) : Math.max(m15.high20, level+0.45*atr);
  const sl = roundNumber(buy ? invalidation - 0.20*atr : invalidation + 0.20*atr, 2);
  const risk = Math.abs(entry-sl);
  let tp1 = buy ? m30.high20 : m30.low20;
  if (risk > 0 && Math.abs(tp1-entry)/risk < 1.30) tp1 = buy ? entry+1.30*risk : entry-1.30*risk;
  const tp2 = buy ? Math.max(h1.high20, entry+2*risk) : Math.min(h1.low20, entry-2*risk);
  const rr1 = risk>0 ? Math.abs(tp1-entry)/risk : 0;
  let score = 20 + 20 + (held?20:0) + ((buy ? h1.close>h1.ema20 || m30.close>m30.ema20 : h1.close<h1.ema20 || m30.close<m30.ema20)?15:0) + (confirm?10:0) + (rr1>=1.3?10:0) + (market.spread_points<=30?5:0);
  const allowed = score>=70 && held && rr1>=1.30;
  return r2Candidate({
    strategy: buy ? "RETEST_BUY" : "RETEST_SELL",
    side,
    order_type: inZone && confirm ? (buy ? "BUY" : "SELL") : (buy ? "BUY_LIMIT" : "SELL_LIMIT"),
    score, allowed, entry, sl, tp1:roundNumber(tp1,2), tp2:roundNumber(tp2,2), rr1,
    expiry_hours: highVol ? 4 : 8,
    zone_low:roundNumber(zoneLow,2), zone_high:roundNumber(zoneHigh,2), breakout_level:roundNumber(level,2),
    invalidation:roundNumber(invalidation,2),
    notes:[held?"Broken level is holding":"Retest failed to hold", inZone?"Price is in retest zone":"Wait for retest zone", confirm?"M5 confirmation present":"M5 confirmation not required until price reaches zone"]
  });
}

function r2RangeCandidate(side, market, h1, m30, m15, m5) {
  const buy=side==="BUY";
  const current=buy?market.ask:market.bid;
  const width=m30.high20-m30.low20;
  const pos=width>0?(current-m30.low20)/width:0.5;
  const atr=Math.max(m15.atr14,0.01);
  const edge=buy?m30.low20:m30.high20;
  const zoneWidth=0.20*width;
  const zoneLow=buy?m30.low20:m30.high20-zoneWidth;
  const zoneHigh=buy?m30.low20+zoneWidth:m30.high20;
  const inZone=current>=zoneLow&&current<=zoneHigh;
  const entry=roundNumber(inZone?current:edge,2);
  const sl=roundNumber(buy?m30.low20-0.25*atr:m30.high20+0.25*atr,2);
  const risk=Math.abs(entry-sl);
  const midpoint=(m30.high20+m30.low20)/2;
  let tp1=midpoint;
  if(risk>0&&Math.abs(tp1-entry)/risk<1.30) tp1=buy?entry+1.30*risk:entry-1.30*risk;
  const tp2=buy?m30.high20:m30.low20;
  const rr1=risk>0?Math.abs(tp1-entry)/risk:0;
  const neutral=pos>=0.40&&pos<=0.60;
  const confirm=buy?(m5.close>=m5.ema20||m5.close_position>=0.55):(m5.close<=m5.ema20||m5.close_position<=0.45);
  let score=25+15+15+(inZone?15:8)+(confirm?10:0)+(rr1>=1.3?15:0)+(market.spread_points<=30?5:0);
  const allowed=score>=70&&!neutral&&rr1>=1.30;
  return r2Candidate({
    strategy:buy?"RANGE_BUY":"RANGE_SELL", side,
    order_type:inZone&&confirm?(buy?"BUY":"SELL"):(buy?"BUY_LIMIT":"SELL_LIMIT"),
    score,allowed,entry,sl,tp1:roundNumber(tp1,2),tp2:roundNumber(tp2,2),rr1,
    expiry_hours:6,zone_low:roundNumber(zoneLow,2),zone_high:roundNumber(zoneHigh,2),
    invalidation:roundNumber(buy?m30.low20:m30.high20,2),
    notes:[neutral?"No new entry in middle 40-60% of range":"Range edge setup", confirm?"M5 behavior supports reversal":"Wait for edge behavior"]
  });
}

function r2Candidate(x) {
  const risk=Math.abs(x.entry-x.sl);
  return {
    allowed:!!x.allowed,
    strategy:x.strategy,
    side:x.side,
    order_type:x.order_type,
    setup_score:Math.min(100,Math.max(0,Math.round(x.score))),
    score:Math.min(100,Math.max(0,Math.round(x.score))),
    entry:roundNumber(x.entry,2),
    sl:roundNumber(x.sl,2),
    tp1:roundNumber(x.tp1,2),
    tp2:roundNumber(x.tp2,2),
    risk_usd_price:roundNumber(risk,2),
    rr_tp1:roundNumber(x.rr1,3),
    expiry_hours:x.expiry_hours,
    overnight_allowed:x.expiry_hours>=8,
    zone_low:x.zone_low??null,
    zone_high:x.zone_high??null,
    breakout_level:x.breakout_level??null,
    breakout_grade:x.breakout_grade??null,
    breakout_buffer:x.breakout_buffer??null,
    invalidation:x.invalidation??null,
    lot_rule:"<200=0.01; 200-299=0.02; 300-399=0.03; +0.01 per additional $100 balance",
    points_note:"$10 XAU price movement = 1000 platform points when _Point=0.01",
    notes:x.notes||[]
  };
}

function r2NoTrade(reason) {
  return {
    allowed:false,
    strategy:"NONE",
    side:null,
    order_type:"NONE",
    setup_score:0,
    score:0,
    entry:null,
    sl:null,
    tp1:null,
    tp2:null,
    rr_tp1:null,
    expiry_hours:null,
    overnight_allowed:false,
    strategy_locked:false,
    notes:[reason]
  };
}

function r2SelectBestCandidate(candidates, marketState) {
  if (!candidates.length) return null;
  const valid=candidates.filter(c=>c.allowed&&c.score>=70);
  if (!valid.length) return candidates[0];

  valid.sort((a,b)=>{
    const d=b.score-a.score;
    if(Math.abs(d)>=5) return d;
    const regimePriority=(c)=>{
      if(marketState.includes("TREND")&&c.strategy.includes("PULLBACK")) return 4;
      if(marketState.includes("BREAKOUT")&&c.strategy.includes("BREAKOUT")) return 4;
      if(marketState.includes("RANGE")&&c.strategy.includes("RANGE")) return 4;
      if(c.strategy.includes("RETEST")) return 3;
      return 2;
    };
    const p=regimePriority(b)-regimePriority(a);
    if(p!==0) return p;
    if(b.rr_tp1!==a.rr_tp1) return b.rr_tp1-a.rr_tp1;
    return a.risk_usd_price-b.risk_usd_price;
  });
  return valid[0];
}

function nearestAbove(
  price,
  levels
) {
  const candidates =
    levels
      .map(Number)
      .filter(
        level =>
          Number.isFinite(level) &&
          level > price
      )
      .sort(
        (a, b) =>
          a - b
      );

  return candidates.length
    ? candidates[0]
    : null;
}


function nearestBelow(
  price,
  levels
) {
  const candidates =
    levels
      .map(Number)
      .filter(
        level =>
          Number.isFinite(level) &&
          level < price
      )
      .sort(
        (a, b) =>
          b - a
      );

  return candidates.length
    ? candidates[0]
    : null;
}


// =============================================================
// TIMEFRAME METRICS
// =============================================================

function buildTimeframeMetrics(
  rawBars,
  generatedAt,
  timeframeSeconds
) {
  if (!Array.isArray(rawBars)) {
    return null;
  }

  const bars =
    rawBars.filter(
      bar =>
        Number.isFinite(
          Number(bar.t)
        ) &&
        generatedAt >=
        (
          Number(bar.t) +
          timeframeSeconds
        )
    );

  if (bars.length < 60) {
    return null;
  }

  const closes =
    bars.map(
      b =>
        Number(b.c)
    );

  const ema9Series =
    emaSeries(
      closes,
      9
    );

  const ema20Series =
    emaSeries(
      closes,
      20
    );

  const ema50Series =
    emaSeries(
      closes,
      50
    );

  const last =
    bars[
      bars.length - 1
    ];

  const previous =
    bars[
      bars.length - 2
    ];

  const ema9 =
    lastValue(
      ema9Series
    );

  const ema20 =
    lastValue(
      ema20Series
    );

  const ema50 =
    lastValue(
      ema50Series
    );

  const currentAtr =
    atr(
      bars,
      14
    );

  const atrHistory =
    rollingAtrValues(
      bars,
      14,
      31
    );

  let historicalAtr =
    atrHistory.slice(
      0,
      Math.max(
        0,
        atrHistory.length - 1
      )
    );

  if (
    historicalAtr.length >
    30
  ) {
    historicalAtr =
      historicalAtr.slice(
        -30
      );
  }

  const medianAtr =
    median(
      historicalAtr
    );

  const atrRatio =
    (
      Number.isFinite(
        medianAtr
      ) &&
      medianAtr > 0
    )
      ? currentAtr /
        medianAtr
      : 1;

  const rsiValue =
    rsi(
      closes,
      14
    );

  let ema20SlopeAtr = 0;

  if (
    ema20Series.length >= 6 &&
    currentAtr > 0
  ) {
    ema20SlopeAtr =
      (
        ema20Series[
          ema20Series.length - 1
        ] -
        ema20Series[
          ema20Series.length - 6
        ]
      ) /
      currentAtr;
  }

  const recent20 =
    bars.slice(-20);

  const previous20 =
    bars.slice(
      -21,
      -1
    );

  if (
    recent20.length < 20 ||
    previous20.length < 20
  ) {
    return null;
  }

  const high20 =
    Math.max(
      ...recent20.map(
        b =>
          Number(b.h)
      )
    );

  const low20 =
    Math.min(
      ...recent20.map(
        b =>
          Number(b.l)
      )
    );

  const previousHigh20 =
    Math.max(
      ...previous20.map(
        b =>
          Number(b.h)
      )
    );

  const previousLow20 =
    Math.min(
      ...previous20.map(
        b =>
          Number(b.l)
      )
    );

  const rangeWidth =
    high20 -
    low20;

  const rangeWidthAtr =
    currentAtr > 0
      ? rangeWidth /
        currentAtr
      : 0;

  const touchTolerance =
    currentAtr *
    0.25;

  let upperTouches = 0;
  let lowerTouches = 0;

  for (
    const bar
    of recent20
  ) {
    if (
      Math.abs(
        Number(bar.h) -
        high20
      ) <=
      touchTolerance
    ) {
      upperTouches++;
    }

    if (
      Math.abs(
        Number(bar.l) -
        low20
      ) <=
      touchTolerance
    ) {
      lowerTouches++;
    }
  }

  const open =
    Number(last.o);

  const high =
    Number(last.h);

  const low =
    Number(last.l);

  const close =
    Number(last.c);

  const lastRange =
    high -
    low;

  const body =
    Math.abs(
      close -
      open
    );

  let closePosition =
    0.5;

  if (lastRange > 0) {
    closePosition =
      (
        close -
        low
      ) /
      lastRange;
  }

  const emaSepAtr =
    currentAtr > 0
      ? Math.abs(
          ema20 -
          ema50
        ) /
        currentAtr
      : 0;

  return {
    close:
      roundNumber(
        close,
        4
      ),

    previous_close:
      roundNumber(
        Number(
          previous.c
        ),
        4
      ),

    ema9:
      roundNumber(
        ema9,
        4
      ),

    ema20:
      roundNumber(
        ema20,
        4
      ),

    ema50:
      roundNumber(
        ema50,
        4
      ),

    rsi14:
      roundNumber(
        rsiValue,
        2
      ),

    atr14:
      roundNumber(
        currentAtr,
        4
      ),

    atr_ratio:
      roundNumber(
        atrRatio,
        3
      ),

    ema_sep_atr:
      roundNumber(
        emaSepAtr,
        3
      ),

    ema20_slope_atr:
      roundNumber(
        ema20SlopeAtr,
        3
      ),

    high20:
      roundNumber(
        high20,
        4
      ),

    low20:
      roundNumber(
        low20,
        4
      ),

    previous_high20:
      roundNumber(
        previousHigh20,
        4
      ),

    previous_low20:
      roundNumber(
        previousLow20,
        4
      ),

    range_width_atr:
      roundNumber(
        rangeWidthAtr,
        3
      ),

    upper_touches:
      upperTouches,

    lower_touches:
      lowerTouches,

    last_range:
      roundNumber(
        lastRange,
        4
      ),

    body:
      roundNumber(
        body,
        4
      ),

    close_position:
      roundNumber(
        closePosition,
        3
      ),

    candle_time:
      Number(
        last.t
      )
  };
}


// =============================================================
// EMA
// =============================================================

function emaSeries(
  values,
  period
) {
  if (
    !Array.isArray(values) ||
    values.length === 0
  ) {
    return [];
  }

  const multiplier =
    2 /
    (
      period + 1
    );

  const result = [];

  let current =
    Number(values[0]);

  result.push(current);

  for (
    let i = 1;
    i < values.length;
    i++
  ) {
    current =
      (
        Number(
          values[i]
        ) *
        multiplier
      ) +
      (
        current *
        (
          1 -
          multiplier
        )
      );

    result.push(
      current
    );
  }

  return result;
}


// =============================================================
// RSI
// =============================================================

function rsi(
  values,
  period = 14
) {
  if (
    values.length <=
    period
  ) {
    return 50;
  }

  let gain = 0;
  let loss = 0;

  for (
    let i = 1;
    i <= period;
    i++
  ) {
    const change =
      Number(
        values[i]
      ) -
      Number(
        values[
          i - 1
        ]
      );

    if (change >= 0) {
      gain += change;
    }
    else {
      loss += -change;
    }
  }

  let averageGain =
    gain /
    period;

  let averageLoss =
    loss /
    period;

  for (
    let i =
      period + 1;
    i < values.length;
    i++
  ) {
    const change =
      Number(
        values[i]
      ) -
      Number(
        values[
          i - 1
        ]
      );

    const currentGain =
      change > 0
        ? change
        : 0;

    const currentLoss =
      change < 0
        ? -change
        : 0;

    averageGain =
      (
        (
          averageGain *
          (
            period - 1
          )
        ) +
        currentGain
      ) /
      period;

    averageLoss =
      (
        (
          averageLoss *
          (
            period - 1
          )
        ) +
        currentLoss
      ) /
      period;
  }

  if (
    averageLoss === 0
  ) {
    return 100;
  }

  const rs =
    averageGain /
    averageLoss;

  return (
    100 -
    (
      100 /
      (
        1 +
        rs
      )
    )
  );
}


// =============================================================
// TRUE RANGE
// =============================================================

function trueRanges(
  bars
) {
  const result = [];

  for (
    let i = 1;
    i < bars.length;
    i++
  ) {
    const high =
      Number(
        bars[i].h
      );

    const low =
      Number(
        bars[i].l
      );

    const previousClose =
      Number(
        bars[
          i - 1
        ].c
      );

    result.push(
      Math.max(
        high - low,

        Math.abs(
          high -
          previousClose
        ),

        Math.abs(
          low -
          previousClose
        )
      )
    );
  }

  return result;
}


// =============================================================
// ATR
// =============================================================

function atr(
  bars,
  period = 14
) {
  const values =
    trueRanges(bars);

  if (
    values.length <
    period
  ) {
    return 0;
  }

  let current =
    values
      .slice(
        0,
        period
      )
      .reduce(
        (
          sum,
          value
        ) =>
          sum +
          value,
        0
      ) /
    period;

  for (
    let i = period;
    i < values.length;
    i++
  ) {
    current =
      (
        (
          current *
          (
            period - 1
          )
        ) +
        values[i]
      ) /
      period;
  }

  return current;
}


// =============================================================
// ROLLING ATR
// =============================================================

function rollingAtrValues(
  bars,
  period,
  count
) {
  const result = [];

  const minimumBars =
    period + 1;

  const start =
    Math.max(
      minimumBars,
      bars.length -
      count +
      1
    );

  for (
    let end = start;
    end <= bars.length;
    end++
  ) {
    const subset =
      bars.slice(
        0,
        end
      );

    const value =
      atr(
        subset,
        period
      );

    if (
      Number.isFinite(value) &&
      value > 0
    ) {
      result.push(value);
    }
  }

  return result;
}


// =============================================================
// REGIME SCORE
// =============================================================

function calculateRegimeScore(
  regime,
  h1,
  m30,
  m15,
  m5
) {
  let score = 30;

  if (
    regime ===
    "TREND_UP"
  ) {
    score = 60;

    if (
      h1.ema_sep_atr >=
      0.30
    ) {
      score += 10;
    }

    if (
      m30.ema_sep_atr >=
      0.30
    ) {
      score += 10;
    }

    if (
      m15.rsi14 >=
      55
    ) {
      score += 10;
    }

    if (
      m5.close >
      m5.ema20
    ) {
      score += 10;
    }
  }

  else if (
    regime ===
    "TREND_DOWN"
  ) {
    score = 60;

    if (
      h1.ema_sep_atr >=
      0.30
    ) {
      score += 10;
    }

    if (
      m30.ema_sep_atr >=
      0.30
    ) {
      score += 10;
    }

    if (
      m15.rsi14 <=
      45
    ) {
      score += 10;
    }

    if (
      m5.close <
      m5.ema20
    ) {
      score += 10;
    }
  }

  else if (
    regime ===
    "BREAKOUT_UP" ||
    regime ===
    "BREAKOUT_DOWN"
  ) {
    score = 70;

    if (
      m5.body >=
      (
        m5.atr14 *
        0.75
      )
    ) {
      score += 10;
    }

    if (
      m5.atr_ratio >=
      1.10 &&
      m5.atr_ratio <
      1.80
    ) {
      score += 10;
    }

    if (
      regime ===
      "BREAKOUT_UP" &&
      m15.close >
      m15.ema20
    ) {
      score += 10;
    }

    if (
      regime ===
      "BREAKOUT_DOWN" &&
      m15.close <
      m15.ema20
    ) {
      score += 10;
    }
  }

  else if (
    regime ===
    "RANGE"
  ) {
    score = 70;

    if (
      m30.upper_touches >=
      3
    ) {
      score += 10;
    }

    if (
      m30.lower_touches >=
      3
    ) {
      score += 10;
    }

    if (
      Math.abs(
        m30.ema20_slope_atr
      ) <
      0.05
    ) {
      score += 10;
    }
  }

  else if (
    regime ===
    "HIGH_VOLATILITY"
  ) {
    score = 100;
  }

  return Math.max(
    0,
    Math.min(
      100,
      Math.round(score)
    )
  );
}


// =============================================================
// GENERAL HELPERS
// =============================================================

function median(values) {
  if (
    !Array.isArray(values) ||
    values.length === 0
  ) {
    return NaN;
  }

  const sorted =
    [...values]
      .sort(
        (a, b) =>
          a - b
      );

  const middle =
    Math.floor(
      sorted.length /
      2
    );

  if (
    sorted.length %
    2 ===
    0
  ) {
    return (
      sorted[
        middle - 1
      ] +
      sorted[
        middle
      ]
    ) /
    2;
  }

  return sorted[middle];
}


function lastValue(values) {
  if (
    !values ||
    values.length === 0
  ) {
    return null;
  }

  return values[
    values.length - 1
  ];
}


function average(values) {
  if (
    !Array.isArray(values) ||
    values.length === 0
  ) {
    return null;
  }

  let sum = 0;

  for (
    const value
    of values
  ) {
    sum += value;
  }

  return (
    sum /
    values.length
  );
}


function averageRounded(
  values,
  digits = 3
) {
  const value =
    average(values);

  if (value === null) {
    return null;
  }

  return roundNumber(
    value,
    digits
  );
}


function roundNumber(
  value,
  digits = 4
) {
  if (
    !Number.isFinite(value)
  ) {
    return null;
  }

  const factor =
    10 ** digits;

  return (
    Math.round(
      value *
      factor
    ) /
    factor
  );
}


function nullableNumber(
  value
) {
  if (
    value === null ||
    value === undefined ||
    value === ""
  ) {
    return null;
  }

  const number =
    Number(value);

  return Number.isFinite(
    number
  )
    ? number
    : null;
}


function toNullableNumber(
  value
) {
  return nullableNumber(
    value
  );
}


// =============================================================
// RESPONSES
// =============================================================

function json(
  data,
  status = 200
) {
  return new Response(
    JSON.stringify(data),
    {
      status,
      headers: {
        "Content-Type":
          "application/json; charset=UTF-8",

        "Cache-Control":
          "no-store, no-cache, must-revalidate, max-age=0",

        "CDN-Cache-Control":
          "no-store",

        "Cloudflare-CDN-Cache-Control":
          "no-store",

        "Pragma":
          "no-cache",

        "Expires":
          "0"
      }
    }
  );
}


function html(
  content,
  status = 200
) {
  return new Response(
    content,
    {
      status,
      headers: {
        "Content-Type":
          "text/html; charset=UTF-8",

        "Cache-Control":
          "no-store"
      }
    }
  );
}


function escapeHtml(value) {
  return String(value)
    .replaceAll(
      "&",
      "&amp;"
    )
    .replaceAll(
      "<",
      "&lt;"
    )
    .replaceAll(
      ">",
      "&gt;"
    )
    .replaceAll(
      '"',
      "&quot;"
    )
    .replaceAll(
      "'",
      "&#039;"
    );
}