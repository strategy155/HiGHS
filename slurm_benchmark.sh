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
#SBATCH --uenv=prgenv-gnu/24.11:v1
#SBATCH --view=spack

# ============================================================================
# Configuration
# ============================================================================

# Work directory selection:
# - On CSCS: $SCRATCH = /capstor/scratch/cscs/$USER (30-day retention)
# - Locally: ./hipo-build in current directory
# See: https://docs.cscs.ch/platforms/hpcp/#scratch
if [[ -n "${SCRATCH:-}" ]]; then
  WORK_DIR="${SCRATCH}/hipo-benchmark"
else
  WORK_DIR="$(pwd)/hipo-build"
fi

readonly INSTALL_DIR="${WORK_DIR}/installs"
readonly SRC_DIR="${WORK_DIR}/src"

# HiGHS repository and branch
readonly HIGHS_REPO="https://github.com/strategy155/HiGHS.git"
readonly HIGHS_BRANCH="hipo-solvers"

# ============================================================================
# Setup
# ============================================================================

echo "=========================================="
echo "HiPO Benchmark Build & Run Script"
echo "=========================================="
echo "Start time: $(date)"
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

cd "${SRC_DIR}"

if [[ ! -f "${INSTALL_DIR}/lib/libmetis.so" ]]; then
  if [[ ! -d "METIS" ]]; then
    echo "Cloning METIS 510-ts..."
    git clone --branch 510-ts https://github.com/galabovaa/METIS.git
  fi

  echo "Configuring METIS..."
  cmake -S METIS -B metis-build \
    -DGKLIB_PATH="${SRC_DIR}/METIS/GKlib" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release

  echo "Building METIS..."
  cmake --build metis-build --parallel

  echo "Installing METIS..."
  cmake --install metis-build
else
  echo "METIS already installed at ${INSTALL_DIR}"
fi

# ============================================================================
# Phase 3: Clone and Build HiGHS
# ============================================================================

echo ""
echo "Phase 3: Building HiGHS with HiPO"
echo "=========================================="

HIGHS_DIR="${SRC_DIR}/HiGHS"

if [[ ! -d "${HIGHS_DIR}" ]]; then
  echo "Cloning HiGHS from ${HIGHS_REPO}..."
  cd "${SRC_DIR}"
  git clone "${HIGHS_REPO}"
fi

cd "${HIGHS_DIR}"

echo "Checking out ${HIGHS_BRANCH}..."
git fetch origin
git checkout "${HIGHS_BRANCH}"
git pull origin "${HIGHS_BRANCH}"

echo "Configuring HiGHS..."
cmake -S . -B build \
  -DHIPO=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DMETIS_ROOT="${INSTALL_DIR}"

echo "Building HiGHS..."
cmake --build build --parallel

# ============================================================================
# Phase 4: Run Benchmarks
# ============================================================================

echo ""
echo "Phase 4: Running Benchmarks"
echo "=========================================="

# Verify the binary works
echo "Verifying HiGHS binary..."
./build/bin/highs --version

# Run benchmarks on built-in test instances
echo "Starting benchmark suite..."
./benchmark_hipo.sh check/instances

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
echo "Benchmarking Complete"
echo "=========================================="
echo "End time: $(date)"
echo "Results directory: ${HIGHS_DIR}/outputs/"