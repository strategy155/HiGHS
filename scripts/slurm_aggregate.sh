#!/bin/bash
#
# HiPO Benchmark Aggregation (Phase 3 of 3)
#
# Collects results from array job and generates summary.
# Runs after all array tasks complete (success or failure).
#
# Usage:
#   sbatch --dependency=afterany:<array_job_id> slurm_aggregate.sh
#
# Reference:
#   SLURM Dependencies: https://slurm.schedmd.com/job_array.html

#SBATCH --job-name=hipo-aggregate
#SBATCH --partition=normal
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --output=aggregate_%j.out
#SBATCH --error=aggregate_%j.err
#SBATCH --uenv=prgenv-gnu/25.11:v1
#SBATCH --view=spack

# ============================================================================
# Configuration
# ============================================================================

# Work directory (same as setup and array jobs)
if [[ -n "${SCRATCH:-}" ]]; then
  WORK_DIR="${SCRATCH}/hipo-benchmark"
else
  WORK_DIR="$(pwd)/hipo-build"
fi

# Locate HiGHS directory
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
SCRIPT_PARENT="$(realpath "${SCRIPT_DIR}/..")"

if [[ -f "${SCRIPT_PARENT}/pyproject.toml" ]]; then
  HIGHS_DIR="${SCRIPT_PARENT}"
else
  HIGHS_DIR="${WORK_DIR}/src/HiGHS"
fi

readonly OUTPUT_DIR="${HIGHS_DIR}/outputs"
readonly TASK_LIST="${WORK_DIR}/tasks.txt"
readonly RESULTS_DIR="${WORK_DIR}/results"
readonly SUMMARY_FILE="${RESULTS_DIR}/summary.csv"

# ============================================================================
# Collect Outputs
# ============================================================================

echo "=========================================="
echo "HiPO Aggregation (Phase 3 of 3)"
echo "=========================================="
echo ""

# Copy all outputs to results directory for easy access
echo "Collecting outputs to ${RESULTS_DIR}..."
mkdir -p "${RESULTS_DIR}"
cp "${OUTPUT_DIR}"/*.out "${RESULTS_DIR}/" 2>/dev/null || true

task_count=$(wc -l < "${TASK_LIST}")
completed_count=$(find "${RESULTS_DIR}" -name "*.out" -type f 2>/dev/null | wc -l)

echo "Total tasks: ${task_count}"
echo "Completed: ${completed_count}"
echo "Missing: $((task_count - completed_count))"
echo ""

# ============================================================================
# Generate Summary CSV
# ============================================================================

echo "Generating summary: ${SUMMARY_FILE}"

# CSV header
echo "problem,system,solver,parallel,threads,status,output_file" > "${SUMMARY_FILE}"

# Process each task from the task list
while IFS='|' read -r problem_path system solver parallel threads; do
  problem_name=$(basename "${problem_path}" .mps.bz2)
  config_name="${system}-${solver}-par${parallel}-t${threads}"
  output_file="${config_name}_${problem_name}.out"

  if [[ -f "${RESULTS_DIR}/${output_file}" ]]; then
    status="completed"
  else
    status="missing"
  fi

  echo "${problem_name},${system},${solver},${parallel},${threads},${status},${output_file}"
done < "${TASK_LIST}" >> "${SUMMARY_FILE}"

echo ""

# ============================================================================
# Final Report
# ============================================================================

echo "=========================================="
echo "Aggregation Complete"
echo "=========================================="
echo ""
echo "Results directory: ${RESULTS_DIR}"
echo "Summary file: ${SUMMARY_FILE}"
echo ""

# Count by status
completed_in_csv=$(grep -c ",completed," "${SUMMARY_FILE}" || true)
missing_in_csv=$(grep -c ",missing," "${SUMMARY_FILE}" || true)

echo "Status breakdown:"
echo "  Completed: ${completed_in_csv}"
echo "  Missing:   ${missing_in_csv}"
echo ""

if [[ "${missing_in_csv}" -gt 0 ]]; then
  echo "Missing tasks:"
  grep ",missing," "${SUMMARY_FILE}" | cut -d',' -f1,2,3 | head -20
  if [[ "${missing_in_csv}" -gt 20 ]]; then
    echo "  ... and $((missing_in_csv - 20)) more"
  fi
fi

echo ""
echo "Done: $(date)"
