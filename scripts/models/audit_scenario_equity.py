#!/usr/bin/env python3
"""Read-only repository audit and historical table reconstruction (stdlib only)."""
import argparse
import csv
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path
import statistics
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = "c8e7a25"
POLICIES = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]
KEYS = ["InstanceNo", "InstanceFile", "NBstage", "Childs", "Periods", "#scen",
        "Theta", "Avg_d", "Dev_d", "J"]
# Tables 5 and 6, pages 26–27 of the supplied repository manuscript PDF.
MANUSCRIPT = {
    (0.2, "PV"): [[.53,.48,47.22],[.98,.04,1.28],[.66,.35,7.74],[1,0,1.01],[.69,.34,6.69]],
    (0.6, "PV"): [[.52,.48,65.35],[.96,.07,1.53],[.67,.35,9.21],[1,0,1.01],[.65,.38,7.98]],
    (0.2, "Savings"): [[.54,.46,28.38],[.71,.31,6.38],[.93,.08,1.83],[.74,.29,5.15],[1,0,1]],
    (0.6, "Savings"): [[.53,.48,30.12],[.67,.35,11.75],[.85,.16,3.08],[.73,.31,6.42],[1,0,1]],
}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write_csv(path, rows, fields=None):
    rows = list(rows)
    fields = fields or list(rows[0])
    temp = path.with_suffix(path.suffix + ".tmp")
    with temp.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    temp.replace(path)


def seed(row, include_profile=False):
    key = "|".join([row["InstanceFile"], row["NBstage"], row["Childs"],
                    row["Periods"], row["J"], repr(float(row["Theta"])),
                    repr(float(row["Avg_d"])), repr(float(row["Dev_d"]))] + (["mixed"] if include_profile else []))
    acc = 1469598103934665603
    for b in key.encode():
        acc = ((acc ^ b) * 1099511628211) % (2**64)
    return acc % (2**31 - 1) + 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "results_models/scenario_equity")
    parser.add_argument("--verify-preservation", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    baseline = out / "historical_file_hashes.csv"
    if args.verify_preservation:
        changes = []
        for row in csv.DictReader(baseline.open()):
            p = ROOT / row["Path"]
            if not p.is_file() or digest(p) != row["SHA256"]:
                changes.append(row["Path"])
        (out / "historical_preservation.json").write_text(json.dumps({"FilesChanged": changes,
            "Passed": not changes}, indent=2) + "\n")
        if changes:
            raise SystemExit(f"Historical files changed: {changes}")
        print("PASS: every pre-existing repository file is unchanged")
        return
    if baseline.exists():
        raise SystemExit("Audit already exists; use --verify-preservation or a new output directory")

    inventory = []
    for p in sorted(ROOT.rglob("*")):
        if not p.is_file() or ".git" in p.relative_to(ROOT).parts or p.is_relative_to(out) or p.resolve()==Path(__file__).resolve():
            continue
        row = {"Path": str(p.relative_to(ROOT)), "Bytes": p.stat().st_size,
               "SHA256": digest(p), "Extension": p.suffix, "CSVColumns": ""}
        if p.suffix == ".csv":
            with p.open(errors="replace", newline="") as f:
                row["CSVColumns"] = "|".join(next(csv.reader(f), []))
        if p.suffix == ".zip":
            with zipfile.ZipFile(p) as z:
                row["CSVColumns"] = "|".join(z.namelist())
        inventory.append(row)
    write_csv(baseline, inventory)
    write_csv(out / "results_inventory.csv", [r for r in inventory if
        r["Path"].startswith(("results_", "archive_legacy/results"))])
    git = lambda *args: subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()
    (out / "audit_provenance.json").write_text(json.dumps({"GitRevision": git("rev-parse", "HEAD"),
        "InitialGitStatus": git("status", "--short"), "ReferenceRevision": git("rev-parse", REFERENCE),
        "HistoricalFileCount": len(inventory), "AuditDate": "2026-10-09",
        "ReferenceIsExactOriginalRun": False, "Reason":
        "Original run commit/runtime not recorded; earliest tracked formulation selected and generator checked against archived inputs."}, indent=2) + "\n")

    source = ROOT / "results_models/fairness_ALL_report_by_house_1024.csv"
    rows = list(csv.DictReader(source.open()))
    groups = defaultdict(list)
    for r in rows:
        if r["Status"].lower() == "true":
            groups[tuple(r[k] for k in KEYS) + (r["Fairness"],)].append(r)
    configs = sorted(set(k[:-1] for k in groups), key=lambda k:
        (int(k[0]), int(k[-1]), float(k[6]), float(k[8])))
    manifest = []
    config_ids = {}
    for i, key in enumerate(configs, 1):
        row = dict(zip(KEYS, key))
        config_id = f"M{i:03d}"
        config_ids[key] = config_id
        manifest.append(dict(ConfigID=config_id, RandomInstanceID=f"Drahi_{row['InstanceNo']}",
            InstanceFile=row["InstanceFile"], InstFolder="codes/inst/inst2020",
            TreeSpec="6:4:4", NBstage=6, Childs=4, Periods=4, Scenarios=1024,
            J=int(row["J"]), Theta=float(row["Theta"]), Sigma=float(row["Theta"]),
            Avg_d=float(row["Avg_d"]), Dev_d=float(row["Dev_d"]), DemandProfile="mixed",
            BatteryScale=1.0, PVScale=1.0, GeneratorSeed=seed(row),
            SeedConvention="without_demand_profile",
            InstanceSHA256=digest(ROOT / "codes/inst/inst2020" / row["InstanceFile"]),
            DatasetID="manuscript_design_rerun", FormulationID="legacy_continuous_battery",
            ReferenceRevision=git("rev-parse", REFERENCE), SAFairnessAbsTol=0.0,
            LexEpsAbs=1.0, Provenance="historical_seed_without_profile_reconstructed_input_checks_matched"))
    write_csv(out / "config_manifest.csv", manifest)

    metric_rows, expected_rows, aggregate = [], [], defaultdict(list)
    for key, rs in sorted(groups.items()):
        if len(rs) != int(rs[0]["J"]) or len({r["House"] for r in rs}) != len(rs):
            raise ValueError(f"Incomplete/duplicate households: {key}")
        for r in rs:
            b, k = float(r["AllGridExpectedCost"]), float(r["CostExpected"])
            if not math.isclose(float(r["Savings"]), b-k, rel_tol=1e-12, abs_tol=1e-8):
                raise ValueError("Historical savings/benchmark inconsistency")
            expected_rows.append(dict(ConfigID=config_ids[key[:-1]], RandomInstanceID=f"Drahi_{r['InstanceNo']}",
                Sigma=float(r["Theta"]), Fairness=r["Fairness"], House=int(r["House"]),
                InstanceFile=r["InstanceFile"], TreeSpec="6:4:4", NBstage=int(r["NBstage"]),
                Childs=int(r["Childs"]), Periods=int(r["Periods"]), Scenarios=int(r["#scen"]),
                J=int(r["J"]), Theta=float(r["Theta"]), Avg_d=float(r["Avg_d"]), Dev_d=float(r["Dev_d"]),
                FormulationID="historical_formulation_unrecorded", Provenance="historical_expectations_original_runtime_unrecorded",
                ExpectedDemand=float(r["ExpectedDemand"]),
                ExpectedPV=float(r["PVReceivedExpected"]), ExpectedSavings=b-k,
                ExpectedBenchmark=b, ExpectedOperatingCost=k, Status=True,
                DatasetID="historical_expected_only", SourceFile=str(source.relative_to(ROOT))))
        for resource, col in [("PV", "PVReceivedExpected"), ("Savings", "Savings")]:
            x = [float(r[col]) for r in rs]
            valid = min(x) > 0 if resource == "Savings" else min(x) >= 0 and sum(x)>0
            n = len(x)
            values = [sum(x)**2/(n*sum(v*v for v in x)),
                sum(abs(a-b) for a in x for b in x)/(2*n*sum(x)), max(x)/min(x)] if valid else [None]*3
            metric_rows.append(dict(ConfigID=config_ids[key[:-1]], Sigma=float(key[6]),
                Fairness=key[-1], Resource=resource, Jain=values[0], Gini=values[1],
                MaxMin=values[2], Valid=valid, Minimum=min(x), Maximum=max(x),
                ValidityReason="valid" if valid else "nonpositive_savings_excluded_by_historical_script"))
            aggregate[(float(key[6]), key[-1], resource)].append(values)
    write_csv(out / "historical_expected_household_results.csv", expected_rows)
    write_csv(out / "historical_instance_equity.csv", metric_rows)
    comparisons = []
    for (sigma, policy, resource), ms in sorted(aggregate.items()):
        for i, metric in enumerate(["Jain", "Gini", "MaxMin"]):
            valid = [m[i] for m in ms if m[i] is not None]
            recomputed = statistics.mean(valid)
            published = MANUSCRIPT[(sigma,resource)][POLICIES.index(policy)][i]
            diff = abs(recomputed-published)
            comparisons.append(dict(Sigma=sigma, Fairness=policy, Resource=resource, Metric=metric,
                ManuscriptValue=published, RecomputedValue=recomputed, AbsoluteDifference=diff,
                RelativeDifference=diff/abs(published) if published else None,
                ValidationStatus="PASS_ROUNDING" if diff <= .005+1e-10 else "FAIL",
                AbsoluteTolerance=.005+1e-10, NumInstances=len(ms), NumValidInstances=len(valid),
                MissingInstanceFraction=1-len(valid)/len(ms),
                Aggregation="equal_configuration_mean_valid_only_historical_convention"))
    write_csv(out / "manuscript_comparison.csv", comparisons)
    write_csv(out / "recovery_classification.csv", [
        dict(Category="A", Source="none", AvailableConfigurations=0, Reason="No complete in-sample scenario CSVs"),
        dict(Category="B", Source="results_models/*validation/*.bin", AvailableConfigurations=5,
             Reason="Four overlapping decision snapshots; one S3:C2:P8,J5,Theta0.2 instance; validate and deduplicate"),
        dict(Category="C", Source=str(source.relative_to(ROOT)), AvailableConfigurations=400,
             Reason="Only expectation and marginal extrema retained; all original scenario joint outcomes require solves"),
        dict(Category="excluded", Source="results_oos/;results_oos_timing_probe/", AvailableConfigurations=0,
             Reason="Rolling-horizon trajectories and model exports are not in-sample stochastic solutions")])
    # Copy immutable tracked sources into the analysis directory, never touch the active model.
    reference_dir = out / "reference_source"
    reference_dir.mkdir(exist_ok=True)
    for name in ["multi.jl", "structuresMulti.jl", "parametersMS.jl", "epp.jl",
                 "mmf_pea.jl", "mmf_sa.jl", "conditional_fairness.jl", "static_demand_share.jl"]:
        (reference_dir/name).write_bytes(subprocess.check_output(
            ["git", "show", f"{REFERENCE}:codes/{name}"], cwd=ROOT))
    print(f"Audit: {len(inventory)} files; {len(configs)} configurations; {len(groups)} policy solves missing")
    print(f"Manuscript comparisons: {sum(r['ValidationStatus']=='PASS_ROUNDING' for r in comparisons)}/{len(comparisons)} pass")


if __name__ == "__main__":
    main()
