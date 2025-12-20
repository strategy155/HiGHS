#!/bin/bash
#
# HiGHS HiPO Benchmarking Script
#
# Collects performance data for Dolan-Moré performance profiles.
# Tests 16 configurations: {augmented,normaleq} × {highs,pardiso} ×
# {parallel off,on} × {1,max threads}
#
# Usage:
#   ./benchmark_hipo.sh [options] [benchmark_dir]
#
# Arguments:
#   benchmark_dir  Directory containing .mps files (default: benchmarks/)
#
# Options:
#   --test              Run in test mode: 1 problem, 1 configuration only
#   --time-limit SECS   Stop gracefully when SECS seconds have elapsed
#                       (default: no limit for local, 24h for SLURM)

# ============================================================================
# Command Line Arguments
# ============================================================================
# Pattern: for-loop with case statement for self-documenting argument parsing.
# Reference: https://www.baeldung.com/linux/bash-parse-command-line-arguments
# ============================================================================

show_usage() {
  echo "Usage: $(basename "$0") [OPTIONS] [benchmark_dir]"
  echo ""
  echo "Options:"
  echo "  --test              Run in test mode (1 problem, 1 config)"
  echo "  --time-limit=SECS   Stop gracefully after SECS seconds"
  echo "  --help              Show this help message"
}

# Default values
TEST_MODE=false
TIME_LIMIT=0
BENCHMARK_DIR_ARG=""

# Parse each argument
for arg in "$@"; do
  case "${arg}" in

    --test)
      TEST_MODE=true
      ;;

    --time-limit=*)
      # Extract value after '=' using parameter expansion
      # ${arg#*=} removes everything up to and including first '='
      TIME_LIMIT="${arg#*=}"
      ;;

    --help)
      show_usage
      exit 0
      ;;

    --*)
      echo "Unknown option: ${arg}" >&2
      show_usage >&2
      exit 1
      ;;

    *)
      # Positional argument: benchmark directory
      BENCHMARK_DIR_ARG="${arg}"
      ;;

  esac
done

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR
PROJECT_ROOT="${SCRIPT_DIR}/.."
readonly PROJECT_ROOT
HIGHS_BIN="${PROJECT_ROOT}/build/bin/highs"
readonly HIGHS_BIN

# Use parsed argument or default to benchmarks/
if [[ -z "${BENCHMARK_DIR_ARG}" ]]; then
  BENCHMARK_DIR="${PROJECT_ROOT}/benchmarks"
else
  BENCHMARK_DIR="${BENCHMARK_DIR_ARG}"
fi
readonly BENCHMARK_DIR
readonly LOG_FILE="${PROJECT_ROOT}/benchmark.log"
readonly CONFIG_DIR="${PROJECT_ROOT}/configs"
readonly OUTPUT_DIR="${PROJECT_ROOT}/outputs"
readonly TEMP_DIR="${PROJECT_ROOT}/temp"

# Detect maximum available threads using nproc (part of GNU coreutils).
# The 'command -v' builtin returns 0 if the command exists, non-zero otherwise.
# We redirect output to /dev/null since we only care about the exit status.
if ! command -v nproc > /dev/null 2>&1; then
  echo "ERROR: nproc command not found. Please install GNU coreutils." >&2
  exit 1
fi
MAX_THREADS=$(nproc)
readonly MAX_THREADS

# Thread counts to test
readonly THREAD_COUNTS=(1 "${MAX_THREADS}")

# Configuration options
readonly SYSTEMS=("augmented" "normaleq")
readonly SOLVERS=("highs" "pardiso")
readonly PARALLEL_MODES=("off" "on")

# ============================================================================
# Time Tracking
# ============================================================================
# Record start time for graceful timeout (using seconds since epoch).
# Reference: https://www.gnu.org/software/bash/manual/bash.html#index-date

JOB_START_SECONDS=$(date +%s)
readonly JOB_START_SECONDS

# Safety margin: stop 5 minutes before the limit to allow cleanup
readonly SAFETY_MARGIN_SECONDS=300

# Check if we should stop due to time limit.
#
# Returns:
#   0 if we should stop, 1 if we can continue
should_stop_for_time_limit() {
  # No limit set (0 means unlimited)
  if [[ "${TIME_LIMIT}" -eq 0 ]]; then
    return 1
  fi

  local current_seconds
  current_seconds=$(date +%s)

  local elapsed_seconds
  elapsed_seconds=$((current_seconds - JOB_START_SECONDS))

  local remaining_seconds
  remaining_seconds=$((TIME_LIMIT - elapsed_seconds))

  # Stop if remaining time is less than safety margin
  if [[ "${remaining_seconds}" -lt "${SAFETY_MARGIN_SECONDS}" ]]; then
    echo ""
    echo "TIME LIMIT: Approaching limit (${remaining_seconds}s remaining)"
    echo "Stopping gracefully to allow cleanup..."
    return 0
  fi

  return 1
}

# ============================================================================
# Helper Functions
# ============================================================================

# Check if a file is bz2 compressed.
#
# Arguments:
#   $1 - file path
#
# Returns:
#   0 if compressed, 1 otherwise
is_bz2_compressed() {
  local file="$1"
  [[ "${file}" == *.bz2 ]]
}

# Decompress a .bz2 file to TEMP_DIR and return the path.
# The decompressed file should be cleaned up after use.
#
# Arguments:
#   $1 - compressed file path
#
# Outputs:
#   Path to decompressed file in TEMP_DIR
decompress_bz2() {
  local compressed_file="$1"
  local name
  name=$(basename "${compressed_file}" .bz2)
  local temp_file="${TEMP_DIR}/${name}"

  bunzip2 -k -c "${compressed_file}" > "${temp_file}"
  echo "${temp_file}"
}

# Remove a temporary file if it exists.
#
# Arguments:
#   $1 - file path
cleanup_temp_file() {
  local file="$1"
  rm -f "${file}"
}

# Get the problem name from a file path, stripping .bz2 if present.
#
# Arguments:
#   $1 - file path
#
# Outputs:
#   Problem name (basename without .bz2)
get_problem_name() {
  local file="$1"
  local name
  name=$(basename "${file}")
  # Remove .bz2 suffix if present
  echo "${name%.bz2}"
}

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

    # Check time limit before starting a new problem
    if should_stop_for_time_limit; then
      return 0  # Exit gracefully (not an error)
    fi

    local problem_name
    problem_name=$(get_problem_name "${problem_path}")

    local output_file="${OUTPUT_DIR}/${config_name}_${problem_name}.out"

    if is_run_completed "${output_file}"; then
      echo "[${current_run_ref}/${total_runs}] SKIP: ${problem_name} (${config_name})"
      skipped_ref=$((skipped_ref + 1))
      continue
    fi

    echo "[${current_run_ref}/${total_runs}] Running: ${problem_name} (${config_name})"

    # Handle compressed files: decompress to temp location
    local model_file="${problem_path}"
    local temp_file=""

    if is_bz2_compressed "${problem_path}"; then
      temp_file=$(decompress_bz2 "${problem_path}")
      model_file="${temp_file}"
    fi

    # Set thread count explicitly via environment variable
    export OMP_NUM_THREADS="${threads}"

    # Run solver and capture output
    if "${HIGHS_BIN}" --solver hipo \
        --parallel "${parallel}" \
        --model_file "${model_file}" \
        --options_file "${config_file}" \
        > "${output_file}" 2>&1; then
      echo "  Completed successfully"
    else
      echo "  Solver returned non-zero exit code"
    fi

    # Clean up temporary decompressed file
    if [[ -n "${temp_file}" ]]; then
      cleanup_temp_file "${temp_file}"
    fi

    # Log to file
    echo "${problem_name} ${config_name}" >> "${LOG_FILE}"
  done
}

# ============================================================================
# Setup and Validation
# ============================================================================

main() {
  local start_time
  start_time=$(date)

  echo "=========================================="
  echo "HiGHS HiPO Benchmarking Script"
  echo "=========================================="
  echo "Start time: ${start_time}"
  echo "Max threads detected: ${MAX_THREADS}"
  if [[ "${TIME_LIMIT}" -gt 0 ]]; then
    echo "Time limit: ${TIME_LIMIT}s (safety margin: ${SAFETY_MARGIN_SECONDS}s)"
  else
    echo "Time limit: none"
  fi
  echo ""

  # Create necessary directories
  mkdir -p "${CONFIG_DIR}" "${OUTPUT_DIR}" "${TEMP_DIR}"

  # Initialize log file
  local log_start_time
  log_start_time=$(date)
  {
    echo "========================================="
    echo "Benchmark started: ${log_start_time}"
    echo "========================================="
  } >> "${LOG_FILE}"

  # Validate that HiGHS binary exists and is executable
  if [[ ! -x "${HIGHS_BIN}" ]]; then
    echo "ERROR: HiGHS binary not found or not executable at ${HIGHS_BIN}" >&2
    exit 1
  fi

  # Find all benchmark files (.mps or .mps.bz2)
  echo "Searching for benchmark problems in ${BENCHMARK_DIR}..."

  # Find uncompressed .mps files
  local mps_files
  mps_files=$(find "${BENCHMARK_DIR}" -name "*.mps" -type f)

  # Find compressed .mps.bz2 files
  local bz2_files
  bz2_files=$(find "${BENCHMARK_DIR}" -name "*.mps.bz2" -type f)

  # Combine results into single string
  local combined_files
  combined_files=$(printf '%s\n%s' "${mps_files}" "${bz2_files}")

  # Filter out empty lines
  local filtered_files
  filtered_files=$(grep -v '^$' <<< "${combined_files}")

  # Sort alphabetically
  local sorted_files
  sorted_files=$(sort <<< "${filtered_files}")

  # Load sorted file paths into array
  local -a problems
  mapfile -t problems <<< "${sorted_files}"

  local num_problems="${#problems[@]}"

  if [[ "${num_problems}" -eq 0 ]]; then
    echo "ERROR: No .mps or .mps.bz2 files found in ${BENCHMARK_DIR}" >&2
    exit 1
  fi

  # Test mode: limit to first problem only
  if [[ "${TEST_MODE}" == true ]]; then
    echo "TEST MODE: Using only first problem"
    problems=("${problems[0]}")
    num_problems=1
  fi

  echo "Found ${num_problems} problems"
  echo ""

  # Test mode: use single configuration
  local systems_to_test=("${SYSTEMS[@]}")
  local solvers_to_test=("${SOLVERS[@]}")
  local parallel_modes_to_test=("${PARALLEL_MODES[@]}")
  local thread_counts_to_test=("${THREAD_COUNTS[@]}")

  if [[ "${TEST_MODE}" == true ]]; then
    echo "TEST MODE: Using single configuration"
    systems_to_test=("${SYSTEMS[0]}")
    solvers_to_test=("${SOLVERS[0]}")
    parallel_modes_to_test=("${PARALLEL_MODES[0]}")
    thread_counts_to_test=("${THREAD_COUNTS[0]}")
  fi

  # Calculate total number of runs
  local num_configs
  num_configs=$((${#systems_to_test[@]} * ${#solvers_to_test[@]} * ${#parallel_modes_to_test[@]} * ${#thread_counts_to_test[@]}))
  local total_runs=$((num_problems * num_configs))

  echo "Configuration matrix:"
  echo "  Systems: ${systems_to_test[*]}"
  echo "  Solvers: ${solvers_to_test[*]}"
  echo "  Parallel modes: ${parallel_modes_to_test[*]}"
  echo "  Thread counts: ${thread_counts_to_test[*]}"
  echo "  Total configurations: ${num_configs}"
  echo "  Total runs: ${total_runs}"
  echo ""

  # Counters for progress tracking
  local current_run=0
  local skipped_runs=0

  # Build flat list of configurations and iterate
  for system in "${systems_to_test[@]}"; do
    for solver in "${solvers_to_test[@]}"; do
      for parallel in "${parallel_modes_to_test[@]}"; do
        for threads in "${thread_counts_to_test[@]}"; do
          run_configuration "${system}" "${solver}" "${parallel}" "${threads}" \
            problems current_run skipped_runs "${total_runs}"
        done
      done
    done
  done

  # Print summary
  local completed_runs=$((current_run - skipped_runs))
  local end_time
  end_time=$(date)

  echo ""
  echo "=========================================="
  echo "Benchmarking Complete"
  echo "=========================================="
  echo "Total runs: ${total_runs}"
  echo "Completed: ${completed_runs}"
  echo "Skipped: ${skipped_runs}"
  echo "End time: ${end_time}"
  echo "Output directory: ${OUTPUT_DIR}"

  # Log summary
  {
    echo "========================================="
    echo "Benchmark finished: ${end_time}"
    echo "Completed: ${completed_runs}, Skipped: ${skipped_runs}"
    echo "========================================="
  } >> "${LOG_FILE}"
}

main "$@"