from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns


BASE_DIR = Path(__file__).resolve().parent
INPUT_CSV = BASE_DIR / "res" / "price_of_fairness_long.csv"
OUTPUT_PNG = BASE_DIR / "res" / "price_of_fairness_distribution.png"
OUTPUT_PDF = BASE_DIR / "res" / "price_of_fairness_distribution.pdf"

ORDER = ["PEA", "LEXMMFPEA", "SA", "LEXMMFSA"]
LABELS = {
    "PEA": "PEA",
    "LEXMMFPEA": "LexMMF-PEA",
    "SA": "SA",
    "LEXMMFSA": "LexMMF-SA",
}
PALETTE = {
    "PEA": "#2F7D62",
    "LEXMMFPEA": "#8DAA48",
    "SA": "#D17C2F",
    "LEXMMFSA": "#A6404B",
}
BG = "#F6F1E8"
PANEL = "#FFFDF8"
GRID = "#D9D1C4"
TEXT = "#201A17"
MUTED = "#6C625B"
MEAN = "#143D59"


def main() -> None:
    df = pd.read_csv(INPUT_CSV)
    df = df[df["Fairness"].isin(ORDER)].copy()
    df["Fairness"] = pd.Categorical(df["Fairness"], categories=ORDER, ordered=True)

    summary = (
        df.groupby("Fairness", observed=True)["PriceOfFairnessPct"]
        .agg(["mean", "median", "max", "count"])
        .reindex(ORDER)
    )

    sns.set_theme(style="white")
    fig = plt.figure(figsize=(13.4, 7.3), facecolor=BG)
    gs = fig.add_gridspec(1, 2, width_ratios=[4.4, 1.55], wspace=0.06)
    ax = fig.add_subplot(gs[0, 0], facecolor=PANEL)
    ax_side = fig.add_subplot(gs[0, 1], facecolor=PANEL)

    sns.violinplot(
        data=df,
        x="PriceOfFairnessPct",
        y="Fairness",
        hue="Fairness",
        order=ORDER,
        orient="h",
        palette=PALETTE,
        legend=False,
        inner=None,
        cut=0,
        linewidth=1.0,
        saturation=0.95,
        ax=ax,
    )

    sns.boxplot(
        data=df,
        x="PriceOfFairnessPct",
        y="Fairness",
        order=ORDER,
        orient="h",
        width=0.22,
        showcaps=True,
        showfliers=False,
        boxprops={"facecolor": "white", "edgecolor": TEXT, "linewidth": 1.1, "zorder": 3},
        whiskerprops={"color": TEXT, "linewidth": 1.0},
        capprops={"color": TEXT, "linewidth": 1.0},
        medianprops={"color": TEXT, "linewidth": 1.5},
        ax=ax,
    )

    sns.stripplot(
        data=df.sample(frac=1.0, random_state=0),
        x="PriceOfFairnessPct",
        y="Fairness",
        order=ORDER,
        orient="h",
        color=TEXT,
        alpha=0.12,
        size=2.3,
        jitter=0.16,
        ax=ax,
    )

    y_positions = np.arange(len(ORDER))
    mean_values = summary["mean"].to_numpy()
    median_values = summary["median"].to_numpy()

    ax.scatter(
        mean_values,
        y_positions,
        marker="D",
        s=64,
        color=MEAN,
        edgecolors="white",
        linewidths=0.8,
        zorder=4,
        label="Mean",
    )

    x_max = max(100.0, float(summary["max"].max()) + 8.0)
    ax.set_xlim(-1.5, x_max)
    ax.axvline(0.0, color=MUTED, linewidth=1.0, linestyle=(0, (2, 3)), zorder=1)

    for idx, policy in enumerate(ORDER):
        ax.text(
            min(x_max - 0.5, summary.loc[policy, "median"] + 2.5),
            idx - 0.28,
            f"med {summary.loc[policy, 'median']:.1f}%",
            fontsize=10,
            color=TEXT,
            ha="left",
            va="center",
        )

    ax.set_yticks(y_positions)
    ax.set_yticklabels([LABELS[p] for p in ORDER], fontsize=12, color=TEXT)
    ax.set_xlabel("Price of fairness (%)", fontsize=12, color=TEXT, labelpad=10)
    ax.set_ylabel("")
    ax.tick_params(axis="x", labelsize=11, colors=TEXT)
    ax.grid(axis="x", color=GRID, linewidth=0.9)
    ax.grid(axis="y", visible=False)
    for spine in ["top", "right", "left"]:
        ax.spines[spine].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.legend(frameon=False, loc="lower right", labelcolor=TEXT)

    ax_side.set_xlim(0, 1)
    ax_side.set_ylim(-0.5, len(ORDER) - 0.5)
    ax_side.invert_yaxis()
    ax_side.axis("off")

    ax_side.text(
        0.02,
        1.02,
        "Mean vs median",
        transform=ax_side.transAxes,
        fontsize=12,
        weight="bold",
        color=TEXT,
    )
    ax_side.text(
        0.02,
        0.97,
        "Lower is better",
        transform=ax_side.transAxes,
        fontsize=10,
        color=MUTED,
    )

    for idx, policy in enumerate(ORDER):
        color = PALETTE[policy]
        ax_side.plot([0.12, 0.82], [idx, idx], color=GRID, linewidth=8, solid_capstyle="round", zorder=1)
        scale = x_max if x_max > 0 else 1.0
        med_x = 0.12 + 0.70 * (summary.loc[policy, "median"] / scale)
        mean_x = 0.12 + 0.70 * (summary.loc[policy, "mean"] / scale)
        ax_side.scatter(med_x, idx, s=92, color=color, edgecolors="white", linewidths=1.0, zorder=3)
        ax_side.scatter(mean_x, idx, s=62, marker="D", color=MEAN, edgecolors="white", linewidths=0.9, zorder=4)
        ax_side.text(0.86, idx - 0.09, f"med {summary.loc[policy, 'median']:.1f}%", fontsize=10.5, color=TEXT, va="center")
        ax_side.text(0.86, idx + 0.12, f"avg {summary.loc[policy, 'mean']:.1f}%", fontsize=9.5, color=MUTED, va="center")

    fig.text(0.06, 0.94, "Price of Fairness Across Policies", fontsize=22, weight="bold", color=TEXT)
    fig.text(
        0.06,
        0.905,
        "Distribution of expected-cost uplift versus the NONE baseline, with raw observations and summary markers.",
        fontsize=11.5,
        color=MUTED,
    )

    fig.savefig(OUTPUT_PNG, dpi=240, bbox_inches="tight", facecolor=BG)
    fig.savefig(OUTPUT_PDF, bbox_inches="tight", facecolor=BG)
    plt.close(fig)

    print(OUTPUT_PNG.name)
    print(OUTPUT_PDF.name)


if __name__ == "__main__":
    main()
