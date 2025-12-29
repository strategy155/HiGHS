#!/bin/bash
#
# HiPO Benchmark Array Job (Phase 2 of 3)
#
# Runs benchmark tasks in parallel via SLURM job array.
# Each task runs ONE (problem, config) pair.
#
# Usage:
#   sbatch --dependency=afterok:<setup_job_id> slurm_array.sh
#
# Reference:
#   SLURM Job Arrays: https://slurm.schedmd.com/job_array.html
#   CSCS Eiger: https://docs.cscs.ch/clusters/eiger/

#SBATCH --job-name=hipo-bench
#SBATCH --partition=normal
#SBATCH --time=24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --hint=nomultithread
#SBATCH --output=bench_%A_%a.out
#SBATCH --error=bench_%A_%a.err
#SBATCH --array=0-527%64
#SBATCH --uenv=prgenv-gnu/25.11:v1
#SBATCH --view=spack

# Disable core dumps (can be 30-100GB each on crashes)
ulimit -c 0

# ============================================================================
# Configuration
# ============================================================================

if [[ -n "${SCRATCH:-}" ]]; then
  WORK_DIR="${SCRATCH}/hipo-benchmark"
else
  WORK_DIR="$(pwd)/hipo-build"
fi

readonly TASK_LIST="${WORK_DIR}/tasks.txt"
readonly BENCHMARK_DIR="${WORK_DIR}/benchmarks"

# Determine HIGHS_DIR (same logic as slurm_setup.sh)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
SCRIPT_PARENT="$(realpath "${SCRIPT_DIR}/..")"

if [[ -f "${SCRIPT_PARENT}/pyproject.toml" ]]; then
  HIGHS_DIR="${SCRIPT_PARENT}"
else
  HIGHS_DIR="${WORK_DIR}/src/HiGHS"
fi

# Load MKL
CSCS_MKL_ACTIVATE="${SCRATCH:-}/hipo-mkl/view/activate.sh"
if [[ -f "${CSCS_MKL_ACTIVATE}" ]]; then
  # shellcheck source=/dev/null
  source "${CSCS_MKL_ACTIVATE}"
fi

# ============================================================================
# Run Task
# ============================================================================

# Guarded references for SLURM variables (silences SC2154, adds validation)
readonly ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:?Not running as SLURM array job}"
readonly ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID not set}"

echo "Array Job ${ARRAY_JOB_ID}, Task ${ARRAY_TASK_ID}"
echo "Task list: ${TASK_LIST}"

"${HIGHS_DIR}/scripts/benchmark_hipo.sh" \
  --task-list="${TASK_LIST}" \
  "${BENCHMARK_DIR}"
