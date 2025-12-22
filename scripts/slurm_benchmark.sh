#!/bin/bash
#
# HiGHS HiPO Benchmarking Script for CSCS Eiger
#
# This script works both:
# - Locally: bash slurm_benchmark.sh (ignores #SBATCH directives)
# - Cluster: sbatch slurm_benchmark.sh (uses SLURM)
#
# Builds all dependencies (MKL, METIS) and HiGHS with HiPO enabled,
# then runs the benchmark suite.
#
# Usage:
#   ./slurm_benchmark.sh [--test]
#
# Options:
#   --test  Run in test mode: download only ex10.mps.bz2, run 1 config
#
# First-time setup on CSCS (run once before sbatch):
#   uenv repo create
#   uenv image pull prgenv-gnu/25.11:v1

#SBATCH --job-name=hipo-benchmark
#SBATCH --partition=normal
#SBATCH --time=24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --hint=nomultithread
#SBATCH --output=benchmark_%j.out
#SBATCH --error=benchmark_%j.err

# Load uenv environment (provides compilers, spack)
# See: https://docs.cscs.ch/software/uenv/using/
# Note: Before first use, run: uenv repo create && uenv image pull prgenv-gnu/25.11:v1
#SBATCH --uenv=prgenv-gnu/25.11:v1
#SBATCH --view=spack

# ============================================================================
# Script Location (must be first, before any operations)
# ============================================================================

# Get absolute path of script's parent directory (potential HiGHS repo)
SCRIPT_RELATIVE_DIR="$(dirname "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(realpath "${SCRIPT_RELATIVE_DIR}")"
SCRIPT_PARENT="$(realpath "${SCRIPT_DIR}/..")"

# ============================================================================
# Command Line Arguments
# ============================================================================

TEST_MODE=false
if [[ "${1:-}" == "--test" ]]; then
  TEST_MODE=true
  echo "Running in TEST MODE"
fi

# ============================================================================
# Configuration
# ============================================================================

# Work directory for building dependencies and HiGHS:
# - On CSCS cluster: use $SCRATCH (fast storage with 30-day retention)
# - Locally: create hipo-build/ in current directory
# See: https://docs.cscs.ch/platforms/hpcp/#scratch
if [[ -n "${SCRATCH:-}" ]]; then
  WORK_DIR="${SCRATCH}/hipo-benchmark"
else
  WORK_DIR="$(pwd)/hipo-build"
fi

readonly INSTALL_DIR="${WORK_DIR}/installs"
readonly SRC_DIR="${WORK_DIR}/src"
readonly BENCHMARK_DIR="${WORK_DIR}/benchmarks"

# HiGHS repository configuration
readonly HIGHS_REPO="https://github.com/strategy155/HiGHS.git"
readonly HIGHS_BRANCH="hipo-solvers"

# Mittelmann LP benchmark URL (https required)
readonly MITTELMANN_URL="https://plato.asu.edu/ftp/lptestset"

# Use half of available CPU cores for parallel builds
TOTAL_CPUS="$(nproc)"
BUILD_JOBS="$(( TOTAL_CPUS / 2 ))"
readonly BUILD_JOBS

# ============================================================================
# Setup
# ============================================================================

start_time=$(date)

echo "=========================================="
echo "HiPO Benchmark Build & Run Script"
echo "=========================================="
echo "Start time: ${start_time}"
echo "Work directory: ${WORK_DIR}"
echo ""

mkdir -p "${INSTALL_DIR}"
mkdir -p "${SRC_DIR}"

# ============================================================================
# Phase 1: Intel oneAPI MKL
# ============================================================================

echo ""
echo "Phase 1: Intel oneAPI MKL"
echo "=========================================="

# MKL detection: MKLROOT is set by setvars.sh/oneapi-vars.sh
# See: https://www.intel.com/content/www/us/en/docs/onemkl/developer-guide-linux/2025-2/cmake-config-for-onemkl.html

if [[ -n "${MKLROOT:-}" ]]; then
  echo "MKL found via MKLROOT: ${MKLROOT}"
elif command -v spack > /dev/null 2>&1; then
  echo "Installing MKL via Spack..."
  spack install intel-oneapi-mkl
  spack load intel-oneapi-mkl
else
  echo "ERROR: MKL not found (MKLROOT not set) and Spack not available." >&2
  echo "Either source Intel's setvars.sh, or use CSCS uenv with spack." >&2
  exit 1
fi

# ============================================================================
# Phase 2: Build METIS 510-ts
# ============================================================================

echo ""
echo "Phase 2: Building METIS 510-ts"
echo "=========================================="

if [[ ! -f "${INSTALL_DIR}/lib/libmetis.a" ]]; then
  if [[ ! -d "${SRC_DIR}/METIS" ]]; then
    echo "Cloning METIS 510-ts..."
    git clone --branch 510-ts https://github.com/galabovaa/METIS.git "${SRC_DIR}/METIS"
  fi

  echo "Configuring METIS..."
  cmake -S "${SRC_DIR}/METIS" -B "${SRC_DIR}/metis-build" \
    -DGKLIB_PATH="${SRC_DIR}/METIS/GKlib" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release

  echo "Building METIS with ${BUILD_JOBS} jobs..."
  cmake --build "${SRC_DIR}/metis-build" --parallel "${BUILD_JOBS}"

  echo "Installing METIS..."
  cmake --install "${SRC_DIR}/metis-build"
else
  echo "METIS already installed at ${INSTALL_DIR}"
fi

# ============================================================================
# Phase 3: Clone and Build HiGHS
# ============================================================================

echo ""
echo "Phase 3: Building HiGHS with HiPO"
echo "=========================================="

# Check if script is inside a HiGHS repo (look for pyproject.toml in parent)
if [[ -f "${SCRIPT_PARENT}/pyproject.toml" ]]; then
  echo "Using local HiGHS repo: ${SCRIPT_PARENT}"
  HIGHS_DIR="${SCRIPT_PARENT}"
else
  echo "Cloning HiGHS from ${HIGHS_REPO}..."
  HIGHS_DIR="${SRC_DIR}/HiGHS"

  if [[ ! -d "${HIGHS_DIR}" ]]; then
    git clone "${HIGHS_REPO}" "${HIGHS_DIR}"
  fi

  git -C "${HIGHS_DIR}" fetch origin
  git -C "${HIGHS_DIR}" checkout "${HIGHS_BRANCH}"
  git -C "${HIGHS_DIR}" pull origin "${HIGHS_BRANCH}"
fi

echo "Configuring HiGHS..."
cmake -S "${HIGHS_DIR}" -B "${HIGHS_DIR}/build" \
  -DHIPO=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DMETIS_ROOT="${INSTALL_DIR}"

echo "Building HiGHS with ${BUILD_JOBS} jobs..."
cmake --build "${HIGHS_DIR}/build" --parallel "${BUILD_JOBS}"

# ============================================================================
# Phase 4: Download Mittelmann LP Benchmarks
# ============================================================================

echo ""
echo "Phase 4: Downloading Mittelmann LP Benchmarks"
echo "=========================================="

mkdir -p "${BENCHMARK_DIR}"

if [[ "${TEST_MODE}" == true ]]; then
  # Test mode: download only ex10.mps.bz2 (smallest at ~4MB)
  if [[ ! -f "${BENCHMARK_DIR}/ex10.mps.bz2" ]]; then
    echo "Downloading ex10.mps.bz2 (test mode, ~4MB)..."
    curl -sL "${MITTELMANN_URL}/ex10.mps.bz2" -o "${BENCHMARK_DIR}/ex10.mps.bz2"
  fi
  echo "Test file ready: ex10.mps.bz2"
elif [[ ! -f "${BENCHMARK_DIR}/.download_complete" ]]; then
  echo "Downloading all .mps.bz2 files from ${MITTELMANN_URL}..."

  # Patterns for extracting file links from HTML directory listing
  readonly HREF_PATTERN='href="[^"]+\.mps\.bz2"'
  readonly HREF_CLEANUP='s/href="//;s/"//'

  # Download and parse directory listing
  curl -sL "${MITTELMANN_URL}/" -o "${BENCHMARK_DIR}/index.html"

  # Extract .mps.bz2 filenames from href attributes
  href_matches=$(grep -oE "${HREF_PATTERN}" "${BENCHMARK_DIR}/index.html")
  clean_filenames=$(echo "${href_matches}" | sed "${HREF_CLEANUP}")
  sorted_filenames=$(echo "${clean_filenames}" | sort -u)
  echo "${sorted_filenames}" > "${BENCHMARK_DIR}/file_list.txt"

  file_count=$(wc -l < "${BENCHMARK_DIR}/file_list.txt")
  echo "Found ${file_count} benchmark files"

  current=0
  while IFS= read -r file; do
    current=$((current + 1))
    if [[ ! -f "${BENCHMARK_DIR}/${file}" ]]; then
      echo "[${current}/${file_count}] Downloading ${file}..."
      curl -sL "${MITTELMANN_URL}/${file}" -o "${BENCHMARK_DIR}/${file}"
    fi
  done < "${BENCHMARK_DIR}/file_list.txt"

  rm -f "${BENCHMARK_DIR}/index.html" "${BENCHMARK_DIR}/file_list.txt"
  touch "${BENCHMARK_DIR}/.download_complete"
  downloaded_files=$(find "${BENCHMARK_DIR}" -name "*.mps.bz2" -type f)
  downloaded_count=$(echo "${downloaded_files}" | wc -l)
  echo "Download complete: ${downloaded_count} files"
else
  echo "Benchmarks already downloaded"
fi

# ============================================================================
# Phase 5: Run Benchmarks
# ============================================================================

echo ""
echo "Phase 5: Running Benchmarks"
echo "=========================================="

# Verify the binary works
echo "Verifying HiGHS binary..."
"${HIGHS_DIR}/build/bin/highs" --version

# Run benchmarks (script handles .mps.bz2 decompression dynamically)
echo "Starting benchmark suite..."
if [[ "${TEST_MODE}" == true ]]; then
  "${HIGHS_DIR}/scripts/benchmark_hipo.sh" --test "${BENCHMARK_DIR}"
else
  "${HIGHS_DIR}/scripts/benchmark_hipo.sh" "${BENCHMARK_DIR}"
fi

# ============================================================================
# Summary
# ============================================================================

end_time=$(date)

echo ""
echo "=========================================="
echo "Benchmarking Complete"
echo "=========================================="
echo "End time: ${end_time}"
echo "Results directory: ${HIGHS_DIR}/outputs/"