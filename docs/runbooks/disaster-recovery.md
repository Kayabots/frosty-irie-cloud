# Runbook: backup, restore and cross-cloud failover

| | Target | How it is met |
|---|---|---|
| **RPO** (data loss) | ≤ 5 min inside AWS · ≤ 6 h across clouds | DynamoDB PITR; `dr.yml` replicates AWS → Azure every 6 h |
| **RTO** (downtime) | ≤ 1 h for ordering | Browser already fails over to the Azure API; CloudFront fails over to the Azure site; WhatsApp is the last-resort channel |
| **Restore test** | Monthly (AWS, automated) · quarterly (Azure, manual) | `dr.yml` restore drill; section 4 below |

Evidence for every step lands in GitHub Actions artifacts (`evidence-dr-*`, kept 400 days). Attach the drill record to the matching Vanta test each quarter.

---

## 1. What already fails over by itself

1. **Order API.** `app.js` posts to the AWS API first. On a timeout, a network error or a 5xx, it retries the same order against the Azure Function. A 4xx (bad order) is shown to the customer and not retried.
2. **Website.** The CloudFront origin group serves the Azure Storage copy when S3 returns 403/404/5xx.
3. **Kitchen.** If both APIs are down, the customer gets a pre-filled WhatsApp message. Orders are never lost silently.

No human action is needed for 1–3. Alarms (Lambda errors, API 5xx, Function 5xx) email the owner.

## 2. AWS region or account outage (CloudFront itself unreachable)

1. Confirm on https://health.aws.amazon.com.
2. Share the Azure site URL (`terraform -chdir=infra/azure output website_url`) on WhatsApp status and Instagram.
3. If `frostyirie.cr` is live, point its DNS at the Azure endpoint (keep TTL at 300 s in normal operation).
4. Orders now land in Cosmos DB only. Record the start time.

**Failback** after AWS recovers:

```bash
# GitHub → Actions → "DR · cross-cloud sync and restore drill" → Run workflow → azure-to-aws
# or locally, logged in to both clouds:
export ORDERS_TABLE=frostyirie-prod-orders CONTACTS_TABLE=frostyirie-prod-order-contacts
export COSMOS_ENDPOINT=$(terraform -chdir=infra/azure output -raw cosmos_endpoint)
python scripts/dr_sync.py azure-to-aws
```

Then revert DNS and run `aws-to-azure` once to re-align. Syncs are idempotent upserts keyed by `orderId`.

## 3. Restore AWS data (bad deploy, accidental delete, corruption)

Point-in-time restore always creates a **new** table. Nothing is overwritten.

```bash
aws dynamodb restore-table-to-point-in-time \
  --source-table-name frostyirie-prod-orders \
  --target-table-name frostyirie-prod-orders-restored \
  --restore-date-time 2026-10-01T15:00:00Z
aws dynamodb wait table-exists --table-name frostyirie-prod-orders-restored
```

Then choose one:

- **Copy back selected items** (usual case): export the affected `orderId`s from the restored table and `put-item` them into the live table.
- **Swap tables** (large-scale corruption): open a PR that changes `ORDERS_TABLE` to the restored name and imports it (`terraform import`), then approve the deploy.

From a daily AWS Backup recovery point instead: AWS Console → Backup → Vaults → `frostyirie-prod-vault` → pick the recovery point → Restore.

Website content never needs a restore: redeploy from Git (`workflow_dispatch` on the Deploy workflow). A single overwritten object can be recovered from S3 version history.

## 4. Restore Azure data (quarterly drill)

Cosmos DB continuous backup restores into a **new account**. A restored account is not free tier, so delete it at the end of the drill (it costs cents per hour).

```bash
RG=$(terraform -chdir=infra/azure output -raw resource_group)
ACC=$(terraform -chdir=infra/azure output -raw cosmos_account)
az cosmosdb restorable-database-account list --account-name "$ACC" -o table
az cosmosdb restore --resource-group "$RG" --account-name "$ACC" \
  --target-database-account-name "${ACC}-drill" \
  --restore-timestamp "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
  --location eastus2
# verify item counts in the Data Explorer, record the timings, then:
az cosmosdb delete --resource-group "$RG" --name "${ACC}-drill" --yes
```

Record: start time, restore point, completion time, item counts, deletion confirmed. Save it as `evidence/restore-drill-azure-YYYYMMDD.json` in the same shape as the AWS drill output and upload it to Vanta.

Static site blobs: versioning and 7-day soft delete are on. Restore with `az storage blob undelete`, or simply redeploy.

## 5. After any incident

1. Open an issue with the `incident` label: timeline, customer impact, orders affected.
2. If personal data may have been exposed, assess within 72 h whether a GDPR Art. 33 notification is required.
3. Record the lessons learned and link the PR that fixes the root cause.
