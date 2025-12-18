#!/bin/bash
#
# HiGHS HiPO Benchmarking Script
#
# Collects performance data for Dolan-Moré performance profiles.
# Tests 16 configurations: {augmented,normaleq} × {highs,pardiso} ×
# {parallel off,on} × {1,max threads}
#
# Usage:
#   ./benchmark_hipo.sh [benchmark_dir]
#
# Arguments:
#   benchmark_dir  Directory containing .mps files (default: benchmarks/)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly PROJECT_ROOT="${SCRIPT_DIR}/.."
readonly HIGHS_BIN="${PROJECT_ROOT}/build/bin/highs"

# Use first argument as benchmark directory, or default to benchmarks/
readonly BENCHMARK_DIR="${1:-${PROJECT_ROOT}/benchmarks}"
readonly LOG_FILE="${PROJECT_ROOT}/benchmark.log"
readonly CONFIG_DIR="${PROJECT_ROOT}/configs"
readonly OUTPUT_DIR="${PROJECT_ROOT}/outputs"

# Detect maximum available threads using nproc (part of GNU coreutils).
# The 'command -v' builtin returns 0 if the command exists, non-zero otherwise.
# We redirect output to /dev/null since we only care about the exit status.
if ! command -v nproc > /dev/null 2>&1; then
  echo "ERROR: nproc command not found. Please install GNU coreutils." >&2
  exit 1
fi
readonly MAX_THREADS=$(nproc)

# Thread counts to test
readonly THREAD_COUNTS=(1 "${MAX_THREADS}")

# Configuration options
readonly SYSTEMS=("augmented" "normaleq")
readonly SOLVERS=("highs" "pardiso")
readonly PARALLEL_MODES=("off" "on")

# ============================================================================
# Helper Functions
# ============================================================================

# Generate an options file for a specific configuration.
#
# Arguments:
#   $1 - system type (augmented or normaleq)
#   $2 - solver type (highs or pardiso)
#   $3 - output file path
generate_options_file() {
  local system="$1"
  local solver="$2"
  local config_file="$3"

  # Write options to file using indented heredoc (<<- allows leading tabs)
  cat > "${config_file}" <<-EOF
	hipo_system = ${system}
	hipo_system_solver = ${solver}
	EOF
}

# Check if a benchmark run has already been completed.
# Uses output file existence as completion marker.
#
# Arguments:
#   $1 - output file path
#
# Returns:
#   0 if completed (file exists), 1 otherwise
is_run_completed() {
  local output_file="$1"
  [[ -f "${output_file}" ]]
}

# Run all benchmark problems for a single configuration.
#
# Arguments:
#   $1 - system type
#   $2 - solver type
#   $3 - parallel mode
#   $4 - thread count
#   $5 - problems array (passed by name)
#   $6 - current run counter (passed by name)
#   $7 - skipped counter (passed by name)
#   $8 - total runs
run_configuration() {
  local system="$1"
  local solver="$2"
  local parallel="$3"
  local threads="$4"
  local -n problems_ref="$5"
  local -n current_run_ref="$6"
  local -n skipped_ref="$7"
  local total_runs="$8"

  local config_name="${system}-${solver}-par${parallel}-t${threads}"
  local config_file="${CONFIG_DIR}/${config_name}.txt"

  # Generate options file
  generate_options_file "${system}" "${solver}" "${config_file}"

  for problem_path in "${problems_ref[@]}"; do
    current_run_ref=$((current_run_ref + 1))

    local problem_name
    problem_name=$(basename "${problem_path}")

    local output_file="${OUTPUT_DIR}/${config_name}_${problem_name}.out"

    if is_run_completed "${output_file}"; then
      echo "[${current_run_ref}/${total_runs}] SKIP: ${problem_name} (${config_name})"
      skipped_ref=$((skipped_ref + 1))
      continue
    fi

    echo "[${current_run_ref}/${total_runs}] Running: ${problem_name} (${config_name})"

    # Set thread count explicitly via environment variable
    export OMP_NUM_THREADS="${threads}"

    # Run solver and capture output
    # Use || true to prevent script exit on solver failure
    if "${HIGHS_BIN}" --solver hipo \
        --parallel "${parallel}" \
        --model_file "${problem_path}" \
        --options_file "${config_file}" \
        > "${output_file}" 2>&1; then
      echo "  Completed successfully"
    else
      echo "  Solver returned non-zero exit code"
    fi

    # Log to file
    echo "${problem_name} ${config_name}" >> "${LOG_FILE}"
  done
}

# ============================================================================
# Setup and Validation
# ============================================================================

main() {
  echo "=========================================="
  echo "HiGHS HiPO Benchmarking Script"
  echo "=========================================="
  echo "Start time: $(date)"
  echo "Max threads detected: ${MAX_THREADS}"
  echo ""

  # Create necessary directories
  mkdir -p "${CONFIG_DIR}" "${OUTPUT_DIR}"

  # Initialize log file
  {
    echo "========================================="
    echo "Benchmark started: $(date)"
    echo "========================================="
  } >> "${LOG_FILE}"

  # Validate that HiGHS binary exists and is executable
  if [[ ! -x "${HIGHS_BIN}" ]]; then
    echo "ERROR: HiGHS binary not found or not executable at ${HIGHS_BIN}" >&2
    exit 1
  fi

  # Find all .mps benchmark files
  echo "Searching for benchmark problems in ${BENCHMARK_DIR}..."

  # Recursively find all .mps files in benchmark directory
  local found_files
  found_files=$(find "${BENCHMARK_DIR}" -name "*.mps" -type f)

  # Sort file paths alphabetically for consistent ordering
  local sorted_files
  sorted_files=$(sort <<< "${found_files}")

  # Load sorted file paths into array using here string
  local -a problems
  mapfile -t problems <<< "${sorted_files}"

  local num_problems="${#problems[@]}"

  if [[ "${num_problems}" -eq 0 ]]; then
    echo "ERROR: No .mps files found in ${BENCHMARK_DIR}" >&2
    exit 1
  fi

  echo "Found ${num_problems} problems"
  echo ""

  # Calculate total number of runs
  local num_configs
  num_configs=$((${#SYSTEMS[@]} * ${#SOLVERS[@]} * ${#PARALLEL_MODES[@]} * ${#THREAD_COUNTS[@]}))
  local total_runs=$((num_problems * num_configs))

  echo "Configuration matrix:"
  echo "  Systems: ${SYSTEMS[*]}"
  echo "  Solvers: ${SOLVERS[*]}"
  echo "  Parallel modes: ${PARALLEL_MODES[*]}"
  echo "  Thread counts: ${THREAD_COUNTS[*]}"
  echo "  Total configurations: ${num_configs}"
  echo "  Total runs: ${total_runs}"
  echo ""

  # Counters for progress tracking
  local current_run=0
  local skipped_runs=0

  # Build flat list of configurations and iterate
  for system in "${SYSTEMS[@]}"; do
    for solver in "${SOLVERS[@]}"; do
      for parallel in "${PARALLEL_MODES[@]}"; do
        for threads in "${THREAD_COUNTS[@]}"; do
          run_configuration "${system}" "${solver}" "${parallel}" "${threads}" \
            problems current_run skipped_runs "${total_runs}"
        done
      done
    done
  done

  # Print summary
  local completed_runs=$((current_run - skipped_runs))
  echo ""
  echo "=========================================="
  echo "Benchmarking Complete"
  echo "=========================================="
  echo "Total runs: ${total_runs}"
  echo "Completed: ${completed_runs}"
  echo "Skipped: ${skipped_runs}"
  echo "End time: $(date)"
  echo "Output directory: ${OUTPUT_DIR}"

  # Log summary
  {
    echo "========================================="
    echo "Benchmark finished: $(date)"
    echo "Completed: ${completed_runs}, Skipped: ${skipped_runs}"
    echo "========================================="
  } >> "${LOG_FILE}"
}

main "$@"