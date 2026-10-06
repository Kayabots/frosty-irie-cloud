## What changes

<!-- One or two sentences. Link the issue or drift ticket. -->

## Type
- [ ] Menu / prices (`app/menu/menu.json`) — confirmed against the printed menu
- [ ] Website / API code
- [ ] Infrastructure (Terraform)
- [ ] Policy / compliance mapping
- [ ] Pipeline

## Change-management checklist (SOX ITGC · ISO 27001 A.8.32 · SOC 2 CC8.1)
- [ ] CI is green: tests, secret scan, Checkov, Conftest policy gate
- [ ] Terraform plan reviewed for both clouds (see the job summary)
- [ ] No new policy suppressions, or each one is recorded in `compliance/exceptions.md`
- [ ] Personal data impact considered (new fields? retention still 30 days?)
- [ ] Rollback plan: revert this PR; data changes are covered by PITR / continuous backup

## Reviewer
The author cannot approve their own PR or the `prod` deployment (segregation of duties).
