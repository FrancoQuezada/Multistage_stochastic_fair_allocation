#!/usr/bin/env python3
"""Independently verify exported CSV arithmetic and cross-file consistency.

Streams one scenario at a time; does not invoke Julia or any optimizer.
"""
import argparse
import csv
import itertools
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ATOL = 1e-10


def read_rows(path):
    with path.open(newline="") as stream:
        yield from csv.DictReader(stream)


def key(row, *extra):
    return tuple(row[name] for name in ("DatasetID", "ConfigID", "Fairness", *extra))


def metrics(values):
    low, high = min(values), max(values)
    if low < 0 or high <= ATOL:
        return {"Jain": None, "Gini": None, "MaxMin": None}
    scaled = [x / high for x in values]
    total = math.fsum(scaled)
    return {
        "Jain": total**2 / (len(values) * math.fsum(x*x for x in scaled)),
        "Gini": math.fsum(abs(x-y) for x in scaled for y in scaled) / (2*len(values)*total),
        "MaxMin": high/low if low > ATOL else None,
    }


def check_value(actual, expected, context, *, atol=1e-8, rtol=1e-9):
    if expected is None:
        assert actual == "", f"Expected missing value: {context}: {actual}"
    else:
        assert actual != "", f"Unexpected missing value: {context}"
        assert math.isclose(float(actual), expected, abs_tol=atol, rel_tol=rtol), (
            f"Value mismatch: {context}: {actual} versus {expected}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "results_models/scenario_equity")
    args = parser.parse_args()
    out = args.output.resolve()
    expected = {key(r, "House"): r for r in read_rows(out / "expected_household_results.csv")}
    instance_metrics = {key(r, "Resource", "Metric"): r for r in read_rows(out / "instance_equity_summary.csv")}
    assert len(expected) == sum(1 for _ in read_rows(out / "expected_household_results.csv")), "Duplicate expected household rows"
    assert len(instance_metrics) == sum(1 for _ in read_rows(out / "instance_equity_summary.csv")), "Duplicate instance metric rows"

    counts = {}
    max_savings_residual = 0.0
    completed = set()
    current = None
    accumulations = {}
    weighted = {}
    probability_sum = 0.0
    scenario_count = 0

    def finish_instance():
        if current is None:
            return
        assert math.isclose(probability_sum, 1, abs_tol=1e-10), f"Probability sum: {current}"
        assert scenario_count == int(metadata["Scenarios"]), f"Scenario count: {current}"
        for house, quantities in accumulations.items():
            row = expected[(*current, str(house))]
            for name, value in quantities.items():
                check_value(row[name], value, (*current, house, name), atol=1e-6)
        for (resource, metric), values in weighted.items():
            row = instance_metrics[(*current, resource, metric)]
            missing_mass = math.fsum(p for p, x in values if x is None)
            valid_mass = math.fsum(p for p, x in values if x is not None)
            contribution = math.fsum(p*x for p, x in values if x is not None)
            check_value(row["MissingProbabilityMass"], missing_mass, (*current, resource, metric, "missing_mass"))
            check_value(row["ValidProbabilityMass"], valid_mass, (*current, resource, metric, "valid_mass"))
            check_value(row["ValidContribution"], contribution, (*current, resource, metric, "valid_contribution"))
            full_mean = contribution if missing_mass == 0 else None
            check_value(row["ExpectedScenarioEquity"], full_mean, (*current, resource, metric, "scenario_expectation"))
            conditional = contribution / valid_mass if valid_mass else None
            check_value(row["ConditionalValidMean"], conditional, (*current, resource, metric, "conditional_mean"))
            # Use the exported canonical expected vector after checking its
            # weighted scenario identity above. Tiny cancellation differences
            # around zero must not silently change the vector's validity flags.
            outcomes = [float(expected[(*current,str(house))]["ExpectedPV" if resource == "PV" else "ExpectedSavings"])
                        for house in accumulations]
            check_value(row["EquityOfExpectedOutcomes"], metrics(outcomes)[metric], (*current, resource, metric, "exante"))
            std = math.sqrt(math.fsum(p*(x-conditional)**2 for p,x in values if x is not None) / valid_mass) if valid_mass else None
            check_value(row["ScenarioStd"], std if missing_mass == 0 else None, (*current, resource, metric, "std"))
            check_value(row["ConditionalValidStd"], std, (*current, resource, metric, "conditional_std"))
        completed.add(current)

    groups = itertools.groupby(read_rows(out / "scenario_household_results.csv"), lambda r: key(r, "Scenario"))
    scenario_metrics = read_rows(out / "scenario_equity_metrics.csv")
    for pair in itertools.zip_longest(groups, scenario_metrics):
        group, metric_row = pair
        assert group is not None and metric_row is not None, "Scenario/household CSV row count mismatch"
        scenario_key, household_iterator = group
        assert scenario_key == key(metric_row, "Scenario"), f"Scenario order/key mismatch: {scenario_key}"
        configuration = scenario_key[:3]
        if configuration != current:
            finish_instance()
            assert configuration not in completed, f"Duplicate configuration block: {configuration}"
            current = configuration
            metadata = metric_row
            assert (ROOT / metadata['SourceFile']).is_file(), f"Missing source decisions: {metadata['SourceFile']}"
            accumulations, weighted = {}, {(r,m): [] for r in ("PV","Savings") for m in ("Jain","Gini","MaxMin")}
            probability_sum, scenario_count = 0.0, 0
        probability = float(metric_row["ScenarioProbability"])
        assert math.isfinite(probability) and probability >= 0
        scenario_count += 1
        assert int(metric_row["Scenario"]) == scenario_count, f"Missing/duplicate scenario: {scenario_key}"
        probability_sum += probability
        household_rows = list(household_iterator)
        assert len(household_rows) == int(metric_row["J"])
        assert [int(r["House"]) for r in household_rows] == list(range(1, len(household_rows)+1))
        pv = [float(r["ScenarioPVAllocation"]) for r in household_rows]
        savings = [float(r["ScenarioSavings"]) for r in household_rows]
        totals = {"PV": math.fsum(pv), "Savings": math.fsum(savings)}
        for r in household_rows:
            assert r["Status"] == "true" and r["ScenarioProbability"] == metric_row["ScenarioProbability"]
            b, k, s = (float(r[n]) for n in ("ScenarioAllGridBenchmark", "ScenarioOperatingCost", "ScenarioSavings"))
            max_savings_residual = max(max_savings_residual, abs(b-k-s))
            check_value(r["ScenarioSavings"], b-k, (*scenario_key, r["House"], "B-K"))
            for resource in ("PV", "Savings"):
                total = totals[resource]
                quantity = float(r["ScenarioPVAllocation" if resource == "PV" else "ScenarioSavings"])
                share = quantity/total if abs(total) > ATOL else None
                check_value(r[f"Scenario{resource}Share"], share, (*scenario_key, r["House"], "share"))
            quantities = accumulations.setdefault(int(r["House"]), {n: 0.0 for n in (
                "ExpectedPV", "ExpectedSavings", "ExpectedBenchmark", "ExpectedOperatingCost")})
            for expected_name, scenario_name in (("ExpectedPV","ScenarioPVAllocation"),
                    ("ExpectedSavings","ScenarioSavings"), ("ExpectedBenchmark","ScenarioAllGridBenchmark"),
                    ("ExpectedOperatingCost","ScenarioOperatingCost")):
                quantities[expected_name] += probability * float(r[scenario_name])
        for resource, values in (("PV", pv), ("Savings", savings)):
            independently_computed = metrics(values)
            for metric, value in independently_computed.items():
                check_value(metric_row[resource+metric], value, (*scenario_key, resource, metric))
                assert (metric_row[resource+metric+"Valid"] == "true") == (value is not None)
                if probability > 0:
                    weighted[(resource,metric)].append((probability,value))
            assert (metric_row[resource+"MetricValid"] == "true") == all(v is not None for v in independently_computed.values())
            check_value(metric_row[resource+"Min"], min(values), (*scenario_key, resource, "min"))
            check_value(metric_row[resource+"Max"], max(values), (*scenario_key, resource, "max"))
            check_value(metric_row["TotalPVAllocation" if resource == "PV" else "TotalSavings"], totals[resource], (*scenario_key, resource, "total"))
        count = counts.setdefault(configuration[0], {"PolicySolutions": 0, "Scenarios": 0, "HouseholdScenarios": 0,
            "MinimumScenarioProbability": probability, "MaximumScenarioProbability": probability})
        count["Scenarios"] += 1
        count["HouseholdScenarios"] += len(household_rows)
        count["MinimumScenarioProbability"] = min(count["MinimumScenarioProbability"], probability)
        count["MaximumScenarioProbability"] = max(count["MaximumScenarioProbability"], probability)
    finish_instance()
    for dataset, _, _ in completed:
        counts[dataset]["PolicySolutions"] += 1
    export_keys = {k[:3] for k in expected if k[0] != "historical_expected_only"}
    assert export_keys == completed, "Expected rows do not cover exactly the scenario solutions"
    assert {k[:3] for k in instance_metrics} == completed, "Instance metrics do not cover exactly the scenario solutions"
    report = {"Passed": True, "OptimizationInvoked": False, "CountsByDataset": counts,
              "ExpectedHouseholdRows": len(expected), "InstanceMetricRows": len(instance_metrics),
              "MaximumSavingsArithmeticResidual": max_savings_residual,
              "Checks": "CSV key coverage; scenario probabilities; household counts; raw B-K; signed shares; all six metrics and flags; extrema/totals; all household expectations; ex-ante metrics; strict scenario expectations; valid/missing mass; weighted standard deviations"}
    (out / "export_verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
