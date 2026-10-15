# Logical architecture

## Processing flow

```text
Approved upstream sources
  ├── account/reporting-date + Stage/SICR + pool
  ├── scenario-specific annual PD
  ├── annual LGD and EAD at default
  ├── scenario weights
  └── period EIR
          |
          v
Input validation and source-version capture
          |
          v
Controlled run creation (Run ID, parameters, status)
          |
          v
Immutable input snapshot / normalized run inputs
          |
          v
Account × forecast period × scenario ECL calculation
          |
          v
Stage-specific account outputs
          |
          v
Pool / product / portfolio aggregation
          |
          v
Reconciliation + quality gates
          |
          v
Publish completed run only
```

## Design principles

- **Explicit lineage:** every output refers to a run ID and source snapshot/version.
- **Determinism:** rerunning the same source versions and parameters produces the same result.
- **Atomic publication:** a failed run is not exposed as a complete result.
- **Validation before calculation:** missing periods, duplicate keys, invalid PD, missing scenario weights, and inconsistent account Stage values fail the run.
- **Auditable calculations:** retain calculation period, scenario, applied weights, discount factor, EAD, LGD, PD, and contribution to ECL as permitted by the approved data-retention policy.
- **Separate calculation and aggregation:** detailed contributions should reconcile to account results, then to pool/product/portfolio totals.
- **SQL Server 2016 compatibility:** use supported T-SQL constructs and avoid relying on features introduced in later versions.
- **No sensitive public fixtures:** test data must be synthetic.

## Proposed logical components

1. **Run controller:** creates the run, validates requested scope (full portfolio or selective product/pool), tracks status and prevents unsafe concurrent or duplicate publication.
2. **Input resolver:** identifies approved sources and source versions; physical table names remain unknown until inspected.
3. **Validator:** checks key uniqueness, coverage, ranges, scenario weights, required periods, Stage validity, and cross-source alignment.
4. **Snapshot layer:** stores the exact records used by a run or otherwise guarantees reproducible source-version references.
5. **Calculation layer:** applies approved Stage horizon, scenario aggregation, PD/LGD/EAD semantics, and discounting convention.
6. **Aggregation layer:** produces account, pool, product, and portfolio outputs without double counting.
7. **Reconciliation layer:** compares input/output populations and totals, validates scenario weights sum to 100%, and captures exceptions.
8. **Publication layer:** exposes only successful and reconciled runs.
9. **Audit layer:** records parameters, source versions, timestamps, procedure/software version, counts, totals, statuses, and failure details.

## Run modes

- Full portfolio.
- Selective run by product and/or pool.

The implementation must define safe behavior for overlapping and repeated runs before these modes are enabled in production.