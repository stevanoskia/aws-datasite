# Runbook: <alert or procedure name>

- **Trigger:** the alert rule (name, expression, threshold, duration) or the situation that starts this procedure
- **Severity:** critical | warning | info
- **Requirements:** R5.6 / R5.7

## What it detects
In one or two sentences, what is wrong when this fires.

## Why this threshold
The reasoning behind the number and the duration (normal baseline, what was observed under load, what would be too noisy).

## Investigation steps
1. First look (which dashboard / panel, what to compare)
2. Logs to check (LogQL query)
3. Database checks (SQL)
4. Likely causes and how to tell them apart

## Fix / mitigation
What to do for each likely cause.

## Recovery check
How to confirm it is resolved (the alert clears, the metric is back in range).

## Tested
| Date | How it was triggered | Fired after | Recovered after | Notes |
|---|---|---|---|---|
| | | | | |
