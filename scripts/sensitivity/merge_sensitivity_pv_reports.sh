#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
OUT_CSV="${OUT_CSV:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_report.csv}"
OUT_CSV_HOUSE="${OUT_CSV_HOUSE:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_report_by_house.csv}"
SUMMARY_FILES=("${SUMMARY_NONE:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_NONE_report.csv}" "${SUMMARY_PEA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_PEA_report.csv}" "${SUMMARY_SA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_SA_report.csv}" "${SUMMARY_LEXMMFPEA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_LEXMMFPEA_report.csv}" "${SUMMARY_LEXMMFSA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_LEXMMFSA_report.csv}")
HOUSE_FILES=("${HOUSE_NONE:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_NONE_report_by_house.csv}" "${HOUSE_PEA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_PEA_report_by_house.csv}" "${HOUSE_SA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_SA_report_by_house.csv}" "${HOUSE_LEXMMFPEA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_LEXMMFPEA_report_by_house.csv}" "${HOUSE_LEXMMFSA:-$RESULTS_SENSITIVITY_DIR/fairness_sensitivity_pv_LEXMMFSA_report_by_house.csv}")
merge_csvs(){ local out_file="$1"; shift; local files=("$@"); local header_written=0; : > "$out_file"; for f in "${files[@]}"; do [[ -f "$f" && -s "$f" ]] || continue; if [[ $header_written -eq 0 ]]; then cat "$f" >> "$out_file"; header_written=1; else tail -n +2 "$f" >> "$out_file"; fi; done; [[ $header_written -eq 1 ]] || { rm -f "$out_file"; return 1; }; }
merge_csvs "$OUT_CSV" "${SUMMARY_FILES[@]}"
merge_csvs "$OUT_CSV_HOUSE" "${HOUSE_FILES[@]}"
