from pathlib import Path

import numpy as np
import pandas as pd
from itertools import combinations


BASE_DIR = Path(__file__).resolve().parent
INPUT_CSV = BASE_DIR / "fairness_ALL_report.csv"
OUTPUT_DIR = BASE_DIR / "res"

KEY_COLS = [
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
]

POLICY_ORDER = ["SA", "PEA", "LEXMMFSA", "LEXMMFPEA"]


def main() -> None:
    OUTPUT_DIR.mkdir(exist_ok=True)

    df = pd.read_csv(INPUT_CSV)
    for col in ["RegretExpected", "RegretMin", "RegretMax"]:
        df[col] = df[col].replace([np.inf, -np.inf], np.nan)

    none_df = df.loc[df["Fairness"] == "NONE", KEY_COLS + ["ExpectedCost"]].rename(
        columns={"ExpectedCost": "ExpectedCost_NONE"}
    )
    fair_df = df.loc[df["Fairness"] != "NONE"].copy()

    joined = fair_df.merge(none_df, on=KEY_COLS, how="left", validate="many_to_one")
    if joined["ExpectedCost_NONE"].isna().any():
        raise ValueError("Some fairness rows are missing their NONE baseline.")

    joined["PriceOfFairnessAbs"] = joined["ExpectedCost"] - joined["ExpectedCost_NONE"]
    joined["PriceOfFairnessPct"] = (
        100.0 * joined["PriceOfFairnessAbs"] / joined["ExpectedCost_NONE"]
    )
    joined = joined.sort_values(KEY_COLS + ["Fairness"])

    price_long = joined[
        KEY_COLS
        + [
            "Fairness",
            "ExpectedCost_NONE",
            "ExpectedCost",
            "PriceOfFairnessAbs",
            "PriceOfFairnessPct",
        ]
    ]
    price_long.to_csv(OUTPUT_DIR / "price_of_fairness_long.csv", index=False)

    price_matrix = joined.pivot(
        index=KEY_COLS, columns="Fairness", values="PriceOfFairnessPct"
    ).reset_index()
    price_matrix = price_matrix.rename(
        columns={policy: f"PoF_pct_{policy}" for policy in POLICY_ORDER}
    )
    price_matrix = price_matrix[KEY_COLS + [f"PoF_pct_{policy}" for policy in POLICY_ORDER]]
    price_matrix.to_csv(OUTPUT_DIR / "price_of_fairness_matrix.csv", index=False)

    regret_parts = []
    for metric in ["RegretExpected", "RegretMin", "RegretMax"]:
        wide = fair_df.pivot(index=KEY_COLS, columns="Fairness", values=metric).reset_index()
        wide = wide.rename(columns={policy: f"{metric}_{policy}" for policy in POLICY_ORDER})
        wide = wide[KEY_COLS + [f"{metric}_{policy}" for policy in POLICY_ORDER]]
        regret_parts.append(wide)

    regret_matrix = regret_parts[0]
    for part in regret_parts[1:]:
        regret_matrix = regret_matrix.merge(part, on=KEY_COLS, how="outer", validate="one_to_one")
    regret_matrix = regret_matrix.sort_values(KEY_COLS)
    regret_matrix.to_csv(OUTPUT_DIR / "regret_matrix.csv", index=False)

    summary_rows = []
    for policy in POLICY_ORDER:
        values = fair_df.loc[fair_df["Fairness"] == policy, "RegretExpected"].dropna()
        summary_rows.append(
            {
                "Fairness": policy,
                "ValidRows": int(values.shape[0]),
                "MeanRegretExpected": float(values.mean()) if len(values) else np.nan,
                "MedianRegretExpected": float(values.median()) if len(values) else np.nan,
                "MinRegretExpected": float(values.min()) if len(values) else np.nan,
                "MaxRegretExpected": float(values.max()) if len(values) else np.nan,
            }
        )
    pd.DataFrame(summary_rows).to_csv(OUTPUT_DIR / "regret_summary.csv", index=False)

    best_counts = {policy: 0 for policy in POLICY_ORDER}
    eligible_rows = 0
    for _, row in regret_matrix.iterrows():
        values = {
            policy: row.get(f"RegretExpected_{policy}")
            for policy in POLICY_ORDER
            if pd.notna(row.get(f"RegretExpected_{policy}"))
        }
        if not values:
            continue
        eligible_rows += 1
        best_value = min(values.values())
        for policy, value in values.items():
            if value == best_value:
                best_counts[policy] += 1

    pd.DataFrame(
        {
            "Fairness": POLICY_ORDER,
            "BestCount": [best_counts[policy] for policy in POLICY_ORDER],
            "EligibleRows": [eligible_rows] * len(POLICY_ORDER),
        }
    ).to_csv(OUTPUT_DIR / "regret_best_policy_counts.csv", index=False)

    pairwise_rows = []
    for policy_a, policy_b in combinations(POLICY_ORDER, 2):
        col_a = f"RegretExpected_{policy_a}"
        col_b = f"RegretExpected_{policy_b}"
        pair = regret_matrix[[col_a, col_b]].dropna()
        pairwise_rows.append(
            {
                "PolicyA": policy_a,
                "PolicyB": policy_b,
                "ComparableRows": int(pair.shape[0]),
                "PolicyA_better_count": int((pair[col_a] < pair[col_b]).sum()),
                "PolicyB_better_count": int((pair[col_b] < pair[col_a]).sum()),
                "TieCount": int((pair[col_a] == pair[col_b]).sum()),
            }
        )
    pd.DataFrame(pairwise_rows).to_csv(OUTPUT_DIR / "regret_pairwise_counts.csv", index=False)

    print("Generated files:")
    for name in [
        "price_of_fairness_long.csv",
        "price_of_fairness_matrix.csv",
        "regret_matrix.csv",
        "regret_summary.csv",
        "regret_best_policy_counts.csv",
        "regret_pairwise_counts.csv",
    ]:
        print(name)


if __name__ == "__main__":
    main()
