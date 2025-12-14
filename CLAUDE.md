# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HiGHS is a high-performance serial and parallel solver for large-scale sparse linear optimization problems including:
- Linear Programming (LP)
- Convex Quadratic Programming (QP)
- Mixed Integer Programming (MIP)

The project is mainly written in C++ (with C++11 standard) with minimal third-party dependencies.

## Build Commands

### Standard Build
```bash
# Configure and build
cmake -S. -B build
cmake --build build --parallel

# Run tests
cd build && ctest
```

### Build Options
Important CMake options (set with `-DOPTION=VALUE`):
- `CMAKE_BUILD_TYPE`: Release (default) or Debug
- `BUILD_SHARED_LIBS`: ON (default on Unix), OFF (default on Windows)
- `FAST_BUILD`: ON (default) - streamlined build system
- `BUILD_TESTING`: ON (default) - build test suite
- `ALL_TESTS`: OFF (default) - build extended test set
- `HIPO`: OFF (default) - build HiPO interior point solver (requires METIS, GKlib, BLAS)
- `CUPDLP_GPU`: OFF (default) - build PDLP with GPU support
- `FORTRAN`: OFF (default) - build Fortran interface
- `CSHARP`: OFF (default) - build C# wrapper
- `ZLIB`: ON (default) - use ZLIB for compressed input

### Building with HiPO
HiPO is a new interior point solver. To build with HiPO enabled:
```bash
# Install dependencies first (see readme-hipo-deps.md)
cmake -S. -B build -DHIPO=ON -DMETIS_ROOT=/path/to/installs -DGKLIB_ROOT=/path/to/installs
cmake --build build --parallel
```

### Development Builds
```bash
# Debug build
cmake -S. -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build

# Coverage analysis (Linux only, Debug mode)
cmake -S. -B build -DCMAKE_BUILD_TYPE=Debug -DHIGHS_COVERAGE=ON
cmake --build build
cd build && ctest
make coverage  # or make ci_cov for CI
```

### Running a Single Test
```bash
cd build
ctest -R TestName  # Run specific test by name regex
ctest -V -R TestName  # Verbose output
```

## Architecture

### Core Components

**Main Solver Class** (`highs/Highs.h`, `highs/lp_data/Highs.cpp`):
- Central interface for all solver operations
- Handles model loading, solving, and result extraction
- Coordinates between different solver implementations

**Solver Implementations**:
1. **Simplex** (`highs/simplex/`): Primal and dual revised simplex solvers (HEkk)
2. **IPM** (`highs/ipm/`): Interior point methods
   - `ipx/`: IPX interior point solver
   - `hipo/`: HiPO interior point solver (new, optional)
   - `basiclu/`: Basic LU factorization
3. **PDLP** (`highs/pdlp/cupdlp/`): First-order primal-dual hybrid gradient method (can use GPU)
4. **QP** (`highs/qpsolver/`): Active set solver for quadratic programming
5. **MIP** (`highs/mip/`): Branch-and-cut MIP solver

**Data Structures**:
- `highs/lp_data/`: Core LP data structures (HighsLp, HighsOptions, HighsStatus, HighsSolution)
- `highs/model/`: Model representation (HighsModel includes LP + Hessian)
- `highs/presolve/`: Presolve and postsolve routines

**Utilities**:
- `highs/util/`: Common utilities (sparse matrices, hash tables, timers)
- `highs/io/`: File I/O (MPS, LP format readers/writers)
- `highs/parallel/`: Parallel simplex implementation

### Solver Selection Logic

The `solver` option determines which LP solver is used:
- `"choose"` (default): HiGHS selects the best solver for the problem
- `"simplex"`: Use simplex method (primal or dual)
- `"ipm"`: Use best available IPM (HiPO if built, otherwise IPX)
- `"hipo"`: Use HiPO IPM (if built with `-DHIPO=ON`)
- `"ipx"`: Use IPX IPM
- `"pdlp"`: Use PDLP first-order method

For MIP problems, the MIP solver uses:
- `mip_lp_solver` option: LP solver for nodes without a basis (typically root node)
- `mip_ipm_solver` option: IPM solver when IPM is mandatory (e.g., analytic center)

### Interfaces

Located in `highs/interfaces/`:
- **C API**: `highs_c_api.h/cpp` - Main C interface
- **C#**: `highs_csharp_api.cs` - C# wrapper
- **Fortran**: `highs_fortran_api.f90` - Fortran interface (requires `FORTRAN=ON`)
- **Python**: Via `highspy` package (see `highs/highspy/`)

### Test Structure

Tests are in `check/`:
- Unit tests use Catch2 framework
- Each major component has dedicated test files (e.g., `TestLpSolvers.cpp`, `TestMipSolver.cpp`)
- Tests are registered via `CMakeLists.txt` in `check/`
- Test instances are in `check/instances/`

## Code Style

- C++11 standard
- Use `HighsInt` for integer indices (can be 32-bit or 64-bit based on `HIGHSINT64` option)
- Status returns use `HighsStatus` enum (kOk, kWarning, kError)
- Logging via `HighsLogOptions` system
- Options stored in `HighsOptions` structure

## C++ Guidelines and References

**IMPORTANT**: When making design decisions, choosing language features, or implementing code patterns, you MUST support your choices by referencing authoritative C++ sources:

**Reference Books** (located in `docs/guidelines/`):
1. **A Tour of C++ (Bjarne Stroustrup, 2022)** - Modern C++ overview and best practices
2. **Discovering Modern C++ (Peter Gottschling, 2021)** - Modern C++ techniques and patterns
3. **Modern C++ Design (Andrei Alexandrescu, 2011)** - Generic programming and design patterns
4. **C++ Coding Standards (Sutter & Alexandrescu, 2004/2011)** - 101 rules, guidelines, and best practices

**Online Reference**:
- **cppreference.com** - Comprehensive C++ standard library reference

When suggesting code changes or new implementations:
- Cite specific sections, rules, or examples from these sources in your explanations to the user
- Explain which guideline or principle supports your decision
- Use the terminology and patterns recommended by these authoritative sources
- **Do NOT clutter source code with book references** - keep code clean and readable
- Prioritize modern C++11 idioms as described in these references

## Important Notes

### Contributing
- HiGHS is primarily open source for distribution, not contribution
- Core solver code changes require discussion with maintainers
- Interface and documentation contributions are welcome
- Pull requests must target the `latest` branch (not `master`)
- Contact: highsopt@gmail.com or GitHub issues

### Building on Windows
- Use `--config Release` for release builds
- Default calling convention is `cdecl`; use `-DSTDCALL=ON` for `stdcall`
- Can specify Visual Studio version: `cmake -G "Visual Studio 17 2022" -S. -B build`

### Current Branch
You are working on the `hipo-solvers` branch, which contains work-in-progress on the HiPO interior point solver integration. Recent commits focus on optimizing the normal equation structure using linked lists and partial row-wise copies of the constraint matrix.