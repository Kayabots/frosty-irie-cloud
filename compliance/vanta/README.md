# Connecting Frosty Irie to Vanta

Vanta watches the live environment through its own integrations. This repository adds three things it cannot see by itself: the pre-deployment policy gate, the DR and restore drill results, and the mapping from each control to the code that implements it.

> Vanta's setup screens and the exact permissions they request change over time. Treat the steps below as the shape of the work, and follow what the Vanta console shows when you connect.

## 1. Frameworks to enable

In Vanta, enable **SOC 2**, **ISO 27001:2022**, **NIST CSF 2.0** and **GDPR**. Enable **SOX ITGC** too if your plan includes it. Otherwise track the SOX ITGC references from `compliance/controls.yaml` as custom controls.

## 2. Integrations

| Integration | How it connects | What it monitors here |
|---|---|---|
| **AWS** | Cross-account role created by `infra/bootstrap/aws/vanta.tf`. Paste the role ARN (output `vanta_role_arn`) into Vanta. Set `vanta_account_id` and `vanta_external_id` from the Vanta AWS setup page before applying. | Encryption, public access, CloudTrail, backups, IAM, resource inventory via `Vanta*` tags |
| **Azure** | Grant the Vanta enterprise application **Reader** on the subscription (plus whatever read roles the Vanta setup page lists) | Storage and Cosmos settings, Defender for Cloud, policy compliance, resource tags |
| **GitHub** | Install the Vanta GitHub App on the repository | Branch protection, PR reviews before merge, Dependabot and code scanning alerts |

The AWS role gets `SecurityAudit` and an explicit **deny** on reading table items or S3 objects. Vanta sees configuration, never customer orders.

## 3. Tags Vanta reads

Set once in Terraform (`local.tags`) and on each data store:

| Tag | Where | Meaning |
|---|---|---|
| `VantaOwner` | every resource (provider default tags / `local.tags`) | Accountable owner email |
| `VantaNonProd` | every resource | `false` for prod |
| `VantaDescription` | key resources | Human description in the inventory |
| `VantaContainsUserData` | tables / Cosmos | `true` only where personal data lives |
| `VantaUserDataStored` | contacts table, Cosmos | Which personal fields are stored |

OPA rule `TAG-001` and Azure Policy `fi-require-tags` fail a deployment that drops these, so Vanta's inventory stays complete.

## 4. Custom controls and evidence

For each control in `compliance/controls.yaml`, create or map a Vanta control with the same ID (`FI-01`…`FI-20`). Link evidence as follows:

| Evidence (GitHub Actions artifact) | Produced by | Upload to Vanta | Controls |
|---|---|---|---|
| `evidence-plan-aws`, `evidence-plan-azure` (`policy-*.json`) | CI on every PR | Sample per quarter | FI-01…04, FI-08, FI-16, FI-19 |
| `evidence-deploy-policy` | Deploy workflow | Each production change, or a quarterly sample | FI-07, FI-08 |
| `evidence-unit-tests` (`unit-tests.xml`) | CI | Quarterly | FI-16, FI-17, FI-18 |
| `evidence-dr-restore-drill-*` | Monthly DR workflow | Monthly | FI-15 |
| `evidence-dr-aws-to-azure-*` | 6-hourly DR workflow | Quarterly sample | FI-14 |
| `evidence-smoke` | Deploy workflow | Quarterly sample | FI-14, FI-19 |
| Drift issues (label `drift`) | Nightly drift workflow | Link the issue list | FI-09 |

To automate the uploads later, add a step to these workflows that calls Vanta's API with an API token stored as a GitHub secret. Check Vanta's current API documentation for the evidence-upload endpoint before building it.

## 5. Policies to adopt in Vanta

Use Vanta's policy templates and point them at this implementation: Information Security, Access Control, Change Management (maps to FI-07/08), Business Continuity & Disaster Recovery (`docs/runbooks/disaster-recovery.md`), Data Retention (30-day contact TTL, FI-16), Privacy (`app/web/privacy.html`), and Vendor Management (AWS, Microsoft, GitHub, Vanta, Meta/WhatsApp).
