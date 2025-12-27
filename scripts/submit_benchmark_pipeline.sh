#!/bin/bash
#
# HiPO Benchmark Pipeline Orchestrator
#
# Submits all three phases of the benchmark pipeline with proper dependencies.
# One command to run everything.
#
# Usage:
#   ./submit_benchmark_pipeline.sh [--test] [--skip-setup] [--dry-run]
#
# Options:
#   --test        Run minimal subset (4 tasks) to validate pipeline
#   --skip-setup  Skip Phase 1 if already completed
#   --dry-run     Print commands without executing
#
# Reference:
#   SLURM Dependencies: https://slurm.schedmd.com/job_array.html

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
readonly SCRIPT_DIR

readonly SETUP_SCRIPT="${SCRIPT_DIR}/slurm_setup.sh"
readonly ARRAY_SCRIPT="${SCRIPT_DIR}/slurm_array.sh"
readonly AGGREGATE_SCRIPT="${SCRIPT_DIR}/slurm_aggregate.sh"

DRY_RUN=false
TEST_MODE=false
SKIP_SETUP=false

# Test mode overrides (smaller subset, shorter times)
readonly TEST_ARRAY_RANGE="0-3"
readonly TEST_ARRAY_TIME="00:15:00"
readonly TEST_SETUP_TIME="01:00:00"

# ============================================================================
# Parse Arguments
# ============================================================================

for arg in "$@"; do
  case "${arg}" in
    --test)
      TEST_MODE=true
      ;;
    --skip-setup)
      SKIP_SETUP=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      echo "Usage: $0 [--test] [--skip-setup] [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --test        Run minimal subset (4 tasks) to validate pipeline"
      echo "  --skip-setup  Skip Phase 1 if already completed"
      echo "  --dry-run     Print commands without executing"
      echo "  --help        Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 1
      ;;
  esac
done

# ============================================================================
# Verify Scripts Exist
# ============================================================================

echo "=========================================="
if [[ "${TEST_MODE}" == true ]]; then
  echo "HiPO Benchmark Pipeline (TEST MODE)"
else
  echo "HiPO Benchmark Pipeline"
fi
echo "=========================================="
echo ""

if [[ "${TEST_MODE}" == true ]]; then
  echo "Test configuration:"
  echo "  Array range: ${TEST_ARRAY_RANGE} (4 tasks)"
  echo "  Array time:  ${TEST_ARRAY_TIME}"
  echo ""
fi

for script in "${SETUP_SCRIPT}" "${ARRAY_SCRIPT}" "${AGGREGATE_SCRIPT}"; do
  if [[ ! -f "${script}" ]]; then
    echo "ERROR: Missing script: ${script}" >&2
    exit 1
  fi
done

echo "Scripts verified:"
echo "  Phase 1: ${SETUP_SCRIPT}"
echo "  Phase 2: ${ARRAY_SCRIPT}"
echo "  Phase 3: ${AGGREGATE_SCRIPT}"
echo ""

# ============================================================================
# Submit Pipeline
# ============================================================================

# Build sbatch options for test mode
ARRAY_OPTS=()
if [[ "${TEST_MODE}" == true ]]; then
  ARRAY_OPTS+=(--array="${TEST_ARRAY_RANGE}" --time="${TEST_ARRAY_TIME}")
fi

SETUP_OPTS=()
if [[ "${TEST_MODE}" == true ]]; then
  SETUP_OPTS+=(--time="${TEST_SETUP_TIME}")
fi

if [[ "${DRY_RUN}" == true ]]; then
  echo "[DRY RUN] Would execute:"
  if [[ "${SKIP_SETUP}" == false ]]; then
    echo "  sbatch --parsable ${SETUP_OPTS[*]:-} ${SETUP_SCRIPT}"
    echo "  sbatch --parsable --dependency=afterok:<setup_id> ${ARRAY_OPTS[*]:-} ${ARRAY_SCRIPT}"
  else
    echo "  (skipping setup)"
    echo "  sbatch --parsable ${ARRAY_OPTS[*]:-} ${ARRAY_SCRIPT}"
  fi
  echo "  sbatch --parsable --dependency=afterany:<array_id> ${AGGREGATE_SCRIPT}"
  exit 0
fi

setup_id=""
if [[ "${SKIP_SETUP}" == false ]]; then
  echo "Submitting Phase 1 (Setup)..."
  setup_id=$(sbatch --parsable "${SETUP_OPTS[@]}" "${SETUP_SCRIPT}")
  echo "  Job ID: ${setup_id}"

  echo "Submitting Phase 2 (Array Job)..."
  echo "  Dependency: afterok:${setup_id}"
  array_id=$(sbatch --parsable --dependency="afterok:${setup_id}" "${ARRAY_OPTS[@]}" "${ARRAY_SCRIPT}")
  echo "  Job ID: ${array_id}"
else
  echo "Skipping Phase 1 (--skip-setup)"
  echo ""
  echo "Submitting Phase 2 (Array Job)..."
  array_id=$(sbatch --parsable "${ARRAY_OPTS[@]}" "${ARRAY_SCRIPT}")
  echo "  Job ID: ${array_id}"
fi

echo "Submitting Phase 3 (Aggregate)..."
echo "  Dependency: afterany:${array_id}"
aggregate_id=$(sbatch --parsable --dependency="afterany:${array_id}" "${AGGREGATE_SCRIPT}")
echo "  Job ID: ${aggregate_id}"

echo ""
echo "=========================================="
echo "Pipeline Submitted"
echo "=========================================="
echo ""

if [[ "${TEST_MODE}" == true ]]; then
  echo "This is a TEST run with only 4 tasks."
  echo "After validation, run the full pipeline without --test"
  echo ""
fi

echo "Job IDs:"
if [[ -n "${setup_id}" ]]; then
  echo "  Setup:     ${setup_id}"
fi
echo "  Array:     ${array_id}"
echo "  Aggregate: ${aggregate_id}"
echo ""
echo "Monitor with: squeue -u \$USER"
if [[ -n "${setup_id}" ]]; then
  echo "Cancel all:   scancel ${setup_id} ${array_id} ${aggregate_id}"
else
  echo "Cancel all:   scancel ${array_id} ${aggregate_id}"
fi
