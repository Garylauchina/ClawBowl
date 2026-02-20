# Skill: Real-Time Data Query

## CRITICAL RULE

**NEVER generate simulated, fabricated, or placeholder data.** Every number, price,
date, or factual claim about the real world MUST come from a `web_search` call in
the current turn. If you cannot retrieve real data, say so explicitly — do NOT
fill in with made-up values.

This rule applies to **all contexts**: direct user questions, cron job executions,
heartbeat checks, and sub-agent tasks.

## When to Use

Use this skill whenever the task involves **time-sensitive information**, including:

- Stock prices, crypto prices, exchange rates, market data
- Weather forecasts, current conditions
- News, current events, sports scores
- Product prices, availability, release dates
- Any query containing "最新", "当前", "今天", "现在", "real-time", "current", "latest"
- **Cron job tasks that require delivering factual data to the user**

## How to Use

### Step 1: Search

Always call `web_search` first — no exceptions:

```
web_search("query here")
```

### Step 2: Verify & Synthesize

- Cross-reference multiple results when possible
- Check the date of the source — prefer the most recent
- If results conflict, mention the discrepancy

### Step 3: Present

- Always state when the data was retrieved
- Format numbers clearly (use commas, currency symbols)
- If data might be delayed (e.g., stock prices), note the potential delay

## Fallback

If `web_search` fails or returns no useful results:

1. Tell the user explicitly: "无法获取实时数据，以下信息基于训练数据，可能已过时。"
2. Provide your best answer from training data with a clear caveat
3. Suggest alternative ways the user can check (e.g., specific websites)
4. **NEVER silently fall back to generating fake data**

## Tips

- For financial data, search for the specific ticker/symbol + "price"
- For weather, include the city name + "weather"
- For news, use specific keywords rather than broad queries
- Tavily API (if configured) provides structured search results — prefer it when available
