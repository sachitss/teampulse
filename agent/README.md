# agent — Windows monitoring agent, C#/.NET 8 (Phase 3)

Not built yet. Build it per `prompt-B-windows-agent.md` and `agent-api-contract.md`, with the Lite limits from the main prompt (§1.3):

- no window titles and no full URLs
- no file activity and no manager-triggered screenshots
- privacy pause of up to 30 minutes
- nothing collected on leave days or holidays

The database already refuses evidence that breaks these rules, and refuses any evidence for an employee who has not consented.
