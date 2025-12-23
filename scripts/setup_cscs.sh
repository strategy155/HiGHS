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

# Step 1: Set up architecture-aware paths
# CSCS clusters use different architectures (x86 on Eiger, ARM on Santis).
# This pattern allows same home directory across clusters.
# Reference: https://docs.cscs.ch/guides/terminal/#managing-x86-and-arm
echo "Step 1: Setting up architecture-aware paths"
echo "=========================================="

xdgbase="${HOME}/.local/$(uname -m)"
export XDG_DATA_HOME="${xdgbase}/share"
export XDG_CONFIG_HOME="${xdgbase}/config"
export XDG_STATE_HOME="${xdgbase}/state"
export PATH="${xdgbase}/bin:${PATH}"

arch=$(uname -m)
echo "Architecture: ${arch}"
echo "XDG base: ${xdgbase}"

# Step 2: Install uv (required by uenv-spack)
# Reference: https://docs.astral.sh/uv/getting-started/installation/
echo ""
echo "Step 2: Checking uv installation"
echo "=========================================="

if command -v uv > /dev/null 2>&1; then
  uv_version=$(uv --version)
  echo "uv already installed: ${uv_version}"
else
  echo "Installing uv to ${xdgbase}..."
  mkdir -p "${xdgbase}/bin"
  export UV_INSTALL_DIR="${xdgbase}"

  uv_installer="${SCRATCH}/uv-install.sh"
  curl -L https://astral.sh/uv/install.sh -o "${uv_installer}"
  sh "${uv_installer}"
  rm "${uv_installer}"
fi

# Step 3: Clone uenv-spack
echo ""
echo "Step 3: Setting up uenv-spack"
echo "=========================================="

if [[ ! -d "${UENV_SPACK_DIR}" ]]; then
  git clone https://github.com/eth-cscs/uenv-spack.git "${UENV_SPACK_DIR}"
else
  echo "uenv-spack already exists at ${UENV_SPACK_DIR}"
fi

export PATH="${UENV_SPACK_DIR}:${PATH}"

# Step 4: Create MKL build environment
echo ""
echo "Step 4: Creating MKL build environment"
echo "=========================================="

uenv-spack "${MKL_ENV_DIR}" --uarch="${UENV_ARCH}" --name="${MKL_ENV_NAME}"

# Step 5: Copy our spack.yaml with MKL spec
echo ""
echo "Step 5: Configuring spack.yaml"
echo "=========================================="

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
cp "${SCRIPT_DIR}/cscs_spack.yaml" "${MKL_ENV_DIR}/env/spack.yaml"
echo "Copied cscs_spack.yaml to ${MKL_ENV_DIR}/env/"

# Step 6: Build the environment
echo ""
echo "Step 6: Building (this may take a while)"
echo "=========================================="

uenv run "${UENV_IMAGE}" --view=spack -- "${MKL_ENV_DIR}/build"

echo ""
echo "=========================================="
echo "Setup Complete"
echo "=========================================="
echo "Activate with: source ${ACTIVATE_SCRIPT}"
