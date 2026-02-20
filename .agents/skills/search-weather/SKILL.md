---
name: search-weather
description: Search The Weather Network for current conditions and short forecast.
---

# Search Weather

Use this skill when the user asks for weather conditions or short forecasts.

## Goal

Find weather information from The Weather Network and summarize it clearly.

## Required Source

Use `WEB_SEARCH` and prioritize results from:
- `theweathernetwork.com`

## Suggested Query Patterns

- `site:theweathernetwork.com <city> weather`
- `site:theweathernetwork.com <city> hourly forecast`
- `site:theweathernetwork.com <city> 7 day forecast`

## Workflow

1. If location is missing or ambiguous, ask a short follow-up for city + region/country.
2. Run `WEB_SEARCH` with a targeted query (include `site:theweathernetwork.com`).
3. Prefer the most relevant city page and forecast page from The Weather Network.
4. Summarize:
- current conditions (if available)
- next-hours / today trend
- short forecast (next few days)
5. Include source links in the response.

## Output Style

- Keep it concise and practical.
- If confidence is low (location mismatch), say so and ask for clarification.
