#!/bin/bash
#
# HiPO Benchmark Setup (Phase 1 of 3)
#
# Builds dependencies, downloads benchmarks, generates task list.
# Submit array job after this completes.
#
# Usage:
#   sbatch slurm_setup.sh
#
# Reference:
#   CSCS: https://docs.cscs.ch/clusters/eiger/
#   SLURM: https://slurm.schedmd.com/job_array.html

#SBATCH --job-name=hipo-setup
#SBATCH --partition=normal
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --hint=nomultithread
#SBATCH --output=setup_%j.out
#SBATCH --error=setup_%j.err
#SBATCH --uenv=prgenv-gnu/25.11:v1
#SBATCH --view=spack

# ============================================================================
# Script Location
# ============================================================================

SCRIPT_RELATIVE_DIR="$(dirname "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(realpath "${SCRIPT_RELATIVE_DIR}")"
SCRIPT_PARENT="$(realpath "${SCRIPT_DIR}/..")"

# ============================================================================
# Configuration
# ============================================================================

if [[ -n "${SCRATCH:-}" ]]; then
  WORK_DIR="${SCRATCH}/hipo-benchmark"
else
  WORK_DIR="$(pwd)/hipo-build"
fi

readonly INSTALL_DIR="${WORK_DIR}/installs"
readonly SRC_DIR="${WORK_DIR}/src"
readonly BENCHMARK_DIR="${WORK_DIR}/benchmarks"
readonly TASK_LIST="${WORK_DIR}/tasks.txt"

readonly HIGHS_REPO="https://github.com/strategy155/HiGHS.git"
readonly HIGHS_BRANCH="hipo-solvers"
readonly MITTELMANN_URL="https://plato.asu.edu/ftp/lptestset"

TOTAL_CPUS="$(nproc)"
BUILD_JOBS="$(( TOTAL_CPUS / 2 ))"
readonly BUILD_JOBS

start_time=$(date)

echo "=========================================="
echo "HiPO Setup (Phase 1 of 3)"
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

CSCS_MKL_ACTIVATE="${SCRATCH:-}/hipo-mkl/view/activate.sh"

if [[ -n "${MKLROOT:-}" ]]; then
  echo "MKL found via MKLROOT: ${MKLROOT}"
elif [[ -f "${CSCS_MKL_ACTIVATE}" ]]; then
  echo "Loading MKL from CSCS environment..."
  # shellcheck source=/dev/null
  source "${CSCS_MKL_ACTIVATE}"
  echo "MKLROOT: ${MKLROOT:-not set}"
else
  echo "ERROR: MKL not found. Run setup_cscs.sh first." >&2
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
# Phase 4: Download Benchmarks
# ============================================================================

echo ""
echo "Phase 4: Downloading Benchmarks"
echo "=========================================="

mkdir -p "${BENCHMARK_DIR}"

if [[ ! -f "${BENCHMARK_DIR}/.download_complete" ]]; then
  curl -sL "${MITTELMANN_URL}/" -o "${BENCHMARK_DIR}/index.html"
  grep -oE 'href="[^"]+\.mps\.bz2"' "${BENCHMARK_DIR}/index.html" | \
    sed 's/href="//;s/"//' | sort -u > "${BENCHMARK_DIR}/file_list.txt"

  file_count=$(wc -l < "${BENCHMARK_DIR}/file_list.txt")
  current=0
  while IFS= read -r file; do
    current=$((current + 1))
    if [[ ! -f "${BENCHMARK_DIR}/${file}" ]]; then
      echo "[${current}/${file_count}] ${file}"
      curl -sL "${MITTELMANN_URL}/${file}" -o "${BENCHMARK_DIR}/${file}"
    fi
  done < "${BENCHMARK_DIR}/file_list.txt"

  rm -f "${BENCHMARK_DIR}/index.html" "${BENCHMARK_DIR}/file_list.txt"
  touch "${BENCHMARK_DIR}/.download_complete"
else
  echo "Already downloaded"
fi

# ============================================================================
# Phase 5: Generate Task List
# ============================================================================

echo ""
echo "Phase 5: Generating Task List"
echo "=========================================="

"${HIGHS_DIR}/scripts/benchmark_hipo.sh" --generate-tasks="${TASK_LIST}" "${BENCHMARK_DIR}"

task_count=$(wc -l < "${TASK_LIST}")
echo "Generated ${task_count} tasks: ${TASK_LIST}"

echo ""
echo "Phase 6: Decompressing Benchmark Files"
echo "=========================================="

"${HIGHS_DIR}/scripts/benchmark_hipo.sh" --decompress-all "${BENCHMARK_DIR}"

echo ""
echo "Next: sbatch --array=0-$((task_count - 1))%64 slurm_array.sh"
