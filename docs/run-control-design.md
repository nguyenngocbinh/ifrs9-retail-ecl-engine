# Run control, snapshots, and audit design

Status: design proposal for SQL Server 2016. This document defines lifecycle behavior; it does not implement ECL formulas or deploy database objects.

## 1. Run identity and scope

Every execution receives a new `RUN_ID`. A rerun must never overwrite prior input snapshots, calculation detail, account results, or summary rows. The run records `PROCESS_DATE`, `RUN_TYPE`, the explicitly selected scenario-weight version, `CALCULATION_VERSION`, requester, and optional scope.

- `FULL`: the full approved portfolio for the reporting date.
- `SELECTIVE`: a requested product, pool, or both; at least one selector is required.
- Do not silently widen a selective run to the full portfolio.
- Keep the exact requested scope in run metadata and report the actual included/excluded population during reconciliation.

The logical schema currently has one product selector and one pool selector. If future requirements include multiple products/pools in one selective request, introduce a normalized run-scope table rather than encoding lists in a string.

## 2. Lifecycle and allowed transitions

The current `ecl_core.RunControl.RUN_STATUS` values support this lifecycle:

| Current state | Allowed next state | Meaning |
|---|---|---|
| CREATED | VALIDATING, CANCELLED, FAILED | Run request persisted |
| VALIDATING | CALCULATING, VALIDATION_FAILED, CANCELLED, FAILED | Inputs and run scope checked |
| CALCULATING | SUCCEEDED, RECONCILIATION_FAILED, CANCELLED, FAILED | Calculation finished; reconciliation outcome must be evidenced |
| SUCCEEDED | PUBLISHED | A successful, reconciled result is made available |
| VALIDATION_FAILED | terminal | Do not calculate or publish |
| RECONCILIATION_FAILED | terminal | Do not publish; create a new RUN_ID for a rerun |
| FAILED | terminal | Do not publish; create a new RUN_ID for a rerun |
| CANCELLED | terminal | Do not publish |
| PUBLISHED | terminal | Immutable published run |

No transition may move a terminal failure/cancellation state back into processing. A rerun is a new run, not a reset of the old row. Only the orchestration procedure/service should update lifecycle state.

## 3. Validation and publication gates

Before moving from VALIDATING to CALCULATING, require:
- unique account key within the run and one Stage per account/reporting date;
- all required input sets bound to the run and compatible reporting date/version;
- PD coverage for each required account × scenario × period, with valid domain;
- LGD/EAD coverage for each required account × period;
- shared EIR coverage for each required forecast period;
- scenario-weight version explicitly selected, complete for all three scenarios, non-negative, and sum-to-one within an approved tolerance;
- maturity/horizon coverage checked without prorating annual PD or EAD for a partial final year;
- POCI detected, recorded as a validation finding, and excluded from ordinary calculation in every case. ERROR/FATAL blocks the run; WARN may continue only if exclusion is visible and reconciled.

Before moving to SUCCEEDED, require persisted reconciliation evidence for input/output account counts, detail-to-account totals, and account-to-pool/product/portfolio totals. Any failed gate must prevent publication. PUBLISHED must be a separate transition after SUCCEEDED.

These gates are a design contract only; they are not represented as implemented or tested stored procedures in this PR.

## 4. Snapshot and version invariants

- Every staged input row is keyed by `RUN_ID`; the selected records must be stable for the life of that run.
- `VERSION_ID` and `IS_ACTIVE` are candidate-selection metadata at load time. Changing active flags later must not change a historical run.
- Bind each run to one explicit scenario-weight version. Never select “whatever is active now” during a rerun of an existing RUN_ID.
- Capture source/logical version identifiers and row counts in audit events before calculation starts.
- After a run enters CALCULATING, input snapshots are read-only to the processing principal.
- For a rerun, create a new RUN_ID and preserve the old run, including failed runs and their validation findings.

The current DDL stores a generic VERSION_ID on each input table. A production implementation must also persist a clear run-to-input-version manifest (one row per logical input family) before calculation, so that a run's source references are explicit and auditable. This manifest is a schema gap to address before source ingestion is implemented.

## 5. Concurrency and idempotency

Before enabling production scheduling, implement a transactionally enforced concurrency policy. At minimum:
- serialize publication for the same `PROCESS_DATE` and overlapping scope;
- prevent two workers from advancing the same RUN_ID concurrently;
- use row locks/compare-and-set semantics for state transitions;
- make event writes and state changes atomic where possible;
- make a repeated request either return the existing request/run identity or create a clearly linked new RUN_ID according to an approved idempotency key;
- never treat a duplicate run as successful merely because a previous run exists.

SQL Server application locks (`sp_getapplock`) are a candidate for scope-level serialization, but the exact lock resource and overlap rules must be implemented and tested before production use.

## 6. Audit and recovery

Append a `ecl_audit.RunEvent` for every lifecycle transition and material processing milestone. Record the prior/new status, event timestamp, actor, input row counts, validation/reconciliation outcome, and failure summary. Detailed validation findings go to `ecl_audit.ValidationError`.

Use least-privilege roles: the orchestration identity may create runs and append events; calculation workers may read snapshots and write their assigned output tables; consumers may read only published results. Enforce append-only audit behavior through permissions and controlled procedures rather than relying on naming alone.

On failure, preserve the run and its diagnostic records. Do not publish partial output. Recovery creates a new run with a new RUN_ID after the cause is addressed. Cancellation must be cooperative and recorded; it must not mark a run cancelled while a transaction is still publishing results.

## 7. Implementation sequence

1. Add a run-to-input-version manifest and explicit reconciliation evidence table/contract.
2. Implement SQL Server 2016-compatible procedures for run creation, guarded state transitions, event logging, and snapshot sealing.
3. Add deterministic tests for illegal transitions, concurrent state changes, duplicate requests, selective scope, failed validation, and publication blocking.
4. Test deployment and rerun behavior on a disposable SQL Server 2016-compatible instance.
5. Only after the operational foundation is tested, implement validation procedures and later calculation routines when methodology gates are approved.

No ECL formula is implemented or approved by this design document.
