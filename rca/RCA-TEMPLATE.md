# RCA-00X: <Short title>

| Field | Value |
|---|---|
| Incident ID | INC-00X |
| Date | YYYY-MM-DD |
| Severity | SEV1 / SEV2 / SEV3 |
| Status | Resolved |
| Duration | detected HH:MM → resolved HH:MM (N min) |
| Services | order-api, mysql |
| Author | Your Name |

## 1. Summary
Two or three sentences: what broke, who was affected, how it was fixed.

## 2. Customer impact
Which endpoints failed, error rate, latency, how many requests/orders affected.

## 3. Timeline (24h clock)
| Time | Event |
|---|---|
| HH:MM | Change / trigger happened |
| HH:MM | First alert / symptom noticed |
| HH:MM | Investigation started |
| HH:MM | Root cause identified |
| HH:MM | Fix applied |
| HH:MM | Recovery verified |

## 4. Detection
How was it noticed (Postman test failed, curl, log alert, user report)? How could it be noticed faster?

## 5. Diagnosis (commands + evidence)
```bash
# the commands you ran, in order, with key output
```

## 6. Root cause (5 Whys)
1. Why did X fail? → because ...
2. Why ...? → ...
3. ...
**Root cause:** one clear sentence.

## 7. Resolution
What fixed it (immediate mitigation vs permanent fix). Commands used.

## 8. Preventive actions
| # | Action | Type | Owner | Status |
|---|---|---|---|---|
| 1 | ... | Prevent / Detect / Mitigate | ... | Open / Done |

## 9. Lessons learned
- What went well
- What went badly
- Where we got lucky
