#!/usr/bin/env bash
# download_cscs_results.sh - Download HIPO benchmark results from CSCS Eiger

set -euo pipefail

CSCS_HOST="${CSCS_HOST:?Set CSCS_HOST}"
SCRATCH_DIR="${CSCS_SCRATCH:?Set CSCS_SCRATCH}"
HIGHS_DIR="${CSCS_HIGHS:?Set CSCS_HIGHS}"
LOCAL_DIR="${LOCAL_DIR:?Set LOCAL_DIR}"

mkdir -p "${LOCAL_DIR}/slurm_logs"

rsync -avz --progress \
    "${CSCS_HOST}:${SCRATCH_DIR}/outputs" \
    "${CSCS_HOST}:${SCRATCH_DIR}/results" \
    "${LOCAL_DIR}/"

rsync -avz --progress \
    "${CSCS_HOST}:${HIGHS_DIR}/{setup_*.out,bench_*.out,aggregate_*.out}" \
    "${LOCAL_DIR}/slurm_logs/"
