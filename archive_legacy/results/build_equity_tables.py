#!/usr/bin/env python3
import argparse
from pathlib import Path

import numpy as np
import pandas as pd


GROUP_COLS = [
    "InstanceNo",
    "InstanceFile",
    "NBstage",
    "Childs",
    "Periods",
    "#scen",
    "Theta",
    "Avg_d",
    "Dev_d",
    "J",
    "Fairness",
]


def jain_index(values: np.ndarray) -> float:
    x = np.asarray(values, dtype=float)
    denom = len(x) * np.sum(x * x)
    if np.isclose(denom, 0.0):
        return 1.0
    return float((np.sum(x) ** 2) / denom)


def gini_coefficient(values: np.ndarray) -> float:
    x = np.asarray(values, dtype=float)
    if np.allclose(x, 0.0):
        return 0.0
    if np.any(x < 0):
        raise ValueError("Gini coefficient requires nonnegative values in this implementation.")
    x_sorted = np.sort(x)
    n = len(x_sorted)
    index = np.arange(1, n + 1)
    return float((np.sum((2 * index - n - 1) * x_sorted)) / (n * np.sum(x_sorted)))


def max_min_ratio(values: np.ndarray) -> float:
    x = np.asarray(values, dtype=float)
    x_min = np.min(x)
    x_max = np.max(x)
    if np.isclose(x_min, 0.0):
        return np.inf if not np.isclose(x_max, 0.0) else 1.0
    return float(x_max / x_min)


def build_metric_table(df: pd.DataFrame, value_col: str, require_positive: bool = False) -> pd.DataFrame:
    rows = []
    for group_key, grp in df.groupby(GROUP_COLS, dropna=False):
        values = grp[value_col].astype(float).to_numpy()
        row = dict(zip(GROUP_COLS, group_key))
        valid = True
        if require_positive and np.any(values <= 0):
            valid = False
            row["JainIndex"] = np.nan
            row["GiniCoefficient"] = np.nan
            row["MaxMinRatio"] = np.nan
        else:
            row["JainIndex"] = jain_index(values)
            row["GiniCoefficient"] = gini_coefficient(values)
            row["MaxMinRatio"] = max_min_ratio(values)
        row["ValidGroup"] = valid
        rows.append(row)

    metric_df = pd.DataFrame(rows)

    summary = (
        metric_df.groupby("Fairness", dropna=False)
        .agg(
            AvgJainIndex=("JainIndex", "mean"),
            AvgGiniCoefficient=("GiniCoefficient", "mean"),
            AvgMaxMinRatio=("MaxMinRatio", lambda s: np.mean(s[np.isfinite(s)]) if np.any(np.isfinite(s)) else np.nan),
            NumGroups=("ValidGroup", "size"),
            NumValidGroups=("ValidGroup", lambda s: int(np.sum(s))),
            NumFiniteMaxMin=("MaxMinRatio", lambda s: int(np.isfinite(s).sum())),
        )
        .reset_index()
    )
    return summary


def save_markdown_tables(tables: dict[str, pd.DataFrame], out_path: Path) -> None:
    sections = []
    for title, table in tables.items():
        sections.append(f"## {title}\n")
        header = "| " + " | ".join(table.columns) + " |"
        sep = "| " + " | ".join(["---"] * len(table.columns)) + " |"
        rows = [
            "| " + " | ".join(str(row[col]) for col in table.columns) + " |"
            for _, row in table.iterrows()
        ]
        sections.append("\n".join([header, sep] + rows))
        sections.append("\n")
    out_path.write_text("\n".join(sections))


def main() -> None:
    parser = argparse.ArgumentParser(description="Build fairness equity summary tables.")
    parser.add_argument(
        "--input",
        default="fairness_ALL_report_by_house_1024.csv",
        help="Input by-house CSV",
    )
    parser.add_argument(
        "--out-prefix",
        default="equity_tables_1024",
        help="Prefix for output tables",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    df = pd.read_csv(input_path)

    if "Savings" not in df.columns:
        if {"AllGridExpectedCost", "CostExpected"}.issubset(df.columns):
            df["Savings"] = df["AllGridExpectedCost"] - df["CostExpected"]
        else:
            raise ValueError("Input must contain 'Savings' or both 'AllGridExpectedCost' and 'CostExpected'.")

    df = df[df["Status"] == True].copy()

    tables = {
        "CostExpected": build_metric_table(df, "CostExpected"),
        "Savings": build_metric_table(df, "Savings", require_positive=True),
        "PVReceivedExpected": build_metric_table(df, "PVReceivedExpected"),
    }

    out_prefix = Path(args.out_prefix)
    for name, table in tables.items():
        safe_name = name.lower()
        table.to_csv(f"{out_prefix}_{safe_name}.csv", index=False)

    save_markdown_tables(tables, Path(f"{out_prefix}.md"))

    for name, table in tables.items():
        print(f"\n{name}")
        print(table.to_string(index=False))


if __name__ == "__main__":
    main()
