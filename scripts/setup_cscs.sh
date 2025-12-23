#!/bin/bash
#
# CSCS Eiger One-Time Setup Script
#
# Sets up the build environment with Intel MKL for HiPO benchmarks.
# Run this ONCE before submitting benchmark jobs.
#
# Usage:
#   ./setup_cscs.sh
#
# Prerequisites:
#   uenv repo create
#   uenv image pull prgenv-gnu/25.11:v1
#
# Reference: https://docs.cscs.ch/build-install/uenv/

readonly UENV_IMAGE="prgenv-gnu/25.11:v1"
readonly UENV_ARCH="zen2"  # Eiger uses AMD EPYC Rome (zen2)
readonly MKL_ENV_NAME="hipo-mkl"

# Verify SCRATCH is set (required on CSCS)
if [[ -z "${SCRATCH:-}" ]]; then
  echo "ERROR: SCRATCH not set. Run this on CSCS systems." >&2
  exit 1
fi

readonly MKL_ENV_DIR="${SCRATCH}/${MKL_ENV_NAME}"
readonly UENV_SPACK_DIR="${SCRATCH}/uenv-spack"
readonly ACTIVATE_SCRIPT="${MKL_ENV_DIR}/view/activate.sh"

echo "=========================================="
echo "CSCS HiPO Setup Script"
echo "=========================================="
echo "MKL environment: ${MKL_ENV_DIR}"
echo ""

# Check if already set up
if [[ -f "${ACTIVATE_SCRIPT}" ]]; then
  echo "MKL environment already exists."
  echo "To rebuild: rm -rf ${MKL_ENV_DIR}"
  exit 0
fi

# Step 1: Clone uenv-spack (requires uv - see docs.cscs.ch/build-install/uenv/)
echo "Step 1: Setting up uenv-spack"
echo "=========================================="

if [[ ! -d "${UENV_SPACK_DIR}" ]]; then
  git clone https://github.com/eth-cscs/uenv-spack.git "${UENV_SPACK_DIR}"
else
  echo "uenv-spack already exists at ${UENV_SPACK_DIR}"
fi

export PATH="${UENV_SPACK_DIR}:${PATH}"

# Step 2: Create MKL build environment
echo ""
echo "Step 2: Creating MKL build environment"
echo "=========================================="

uenv-spack "${MKL_ENV_DIR}" --uarch="${UENV_ARCH}" --name="${MKL_ENV_NAME}"

# Step 3: Copy our spack.yaml with MKL spec
echo ""
echo "Step 3: Configuring spack.yaml"
echo "=========================================="

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
cp "${SCRIPT_DIR}/cscs_spack.yaml" "${MKL_ENV_DIR}/env/spack.yaml"
echo "Copied cscs_spack.yaml to ${MKL_ENV_DIR}/env/"

# Step 4: Build the environment
echo ""
echo "Step 4: Building (this may take a while)"
echo "=========================================="

uenv run "${UENV_IMAGE}" --view=spack -- "${MKL_ENV_DIR}/build"

echo ""
echo "=========================================="
echo "Setup Complete"
echo "=========================================="
echo "Activate with: source ${ACTIVATE_SCRIPT}"
