"""Tests for HiPO interior point solver.

These tests validate HIPO functionality when built with HIPO=ON.
Tests are skipped if HIPO is not available in the build.

HiPO (HiGHS Interior Point Optimizer) is an optional interior point solver
that requires Intel MKL and Eigen3 at build time. When available, it provides
an alternative to the default simplex and IPX solvers.

Reference:
    https://google.github.io/styleguide/pyguide.html
"""

import pytest
import numpy as np
import highspy


# Solver configuration constants
# These match the option names used in HiGHS C++ API
SOLVER_HIPO = "hipo"
OUTPUT_FLAG_OPTION = "output_flag"
SOLVER_OPTION = "solver"
OUTPUT_DISABLED = False

# Variable bounds for the test LP
# Both variables are non-negative (standard LP form)
VAR_LOWER_BOUND = 0.0

# Problem dimensions
# Simple 2-variable LP for basic functionality verification
NUM_VARIABLES = 2
NUM_CONSTRAINT_NONZEROS = 2

# Variable indices (0-based indexing as used by HiGHS API)
VAR_INDEX_X = 0
VAR_INDEX_Y = 1

# Objective function: minimize x + y
# Equal coefficients test symmetric treatment of variables
COST_X = 1.0
COST_Y = 1.0

# Constraint: x + y >= 1
# This creates a half-space with optimal vertex at (1,0) or (0,1)
CONSTRAINT_COEFF_X = 1.0
CONSTRAINT_COEFF_Y = 1.0
CONSTRAINT_LOWER_BOUND = 1.0

# Expected results
# Optimal value is 1.0 (achieved at x=1,y=0 or x=0,y=1)
EXPECTED_OBJECTIVE_VALUE = 1.0
# Interior point methods may have slight numerical tolerance differences
OBJECTIVE_TOLERANCE_PLACES = 5


def _is_hipo_available() -> bool:
    """Check if HiPO solver is available in the build.

    HiPO requires HIPO=ON at CMake configure time, which in turn requires
    Intel MKL and Eigen3. When not available, attempting to set the solver
    option to "hipo" raises a RuntimeError.

    Returns:
        True if HiPO solver can be selected, False otherwise.
    """
    h = highspy.Highs()
    # Suppress output during availability check
    h.setOptionValue(OUTPUT_FLAG_OPTION, OUTPUT_DISABLED)
    try:
        # Attempting to select HiPO will fail if not compiled in
        h.setOptionValue(SOLVER_OPTION, SOLVER_HIPO)
        return True
    except RuntimeError:
        # HiPO not available in this build
        return False


# Module-level skip marker
# All tests in this file are skipped if HiPO is not available,
# avoiding false failures in standard (non-HiPO) builds
pytestmark = pytest.mark.skipif(
    not _is_hipo_available(),
    reason="HiPO not available in this build"
)


class TestHipoSolver:
    """Test suite for HiPO interior point solver.

    These tests verify basic HiPO functionality using simple LP problems.
    More comprehensive solver tests are in the main HiGHS test suite.
    """

    def test_simple_lp_minimize(self) -> None:
        """Test HiPO on simple LP: minimize x + y s.t. x + y >= 1.

        This is a minimal LP that exercises the core HiPO solve path:
        - 2 non-negative variables
        - 1 linear constraint (inequality)
        - Linear objective (minimization)

        Expected solution: objective = 1.0 at vertex (1,0) or (0,1).
        """
        # Initialize solver with HiPO selected
        h = highspy.Highs()
        h.setOptionValue(OUTPUT_FLAG_OPTION, OUTPUT_DISABLED)
        h.setOptionValue(SOLVER_OPTION, SOLVER_HIPO)

        # Define variable bounds: 0 <= x,y <= inf
        # Using kHighsInf for unbounded upper limits
        inf = highspy.kHighsInf
        lower_bounds = np.array([VAR_LOWER_BOUND, VAR_LOWER_BOUND])
        upper_bounds = np.array([inf, inf])
        h.addVars(NUM_VARIABLES, lower_bounds, upper_bounds)

        # Set objective coefficients: minimize x + y
        cost_indices = np.array([VAR_INDEX_X, VAR_INDEX_Y])
        cost_values = np.array([COST_X, COST_Y])
        h.changeColsCost(NUM_VARIABLES, cost_indices, cost_values)

        # Add constraint: x + y >= 1
        # Stored as: 1 <= x + y <= inf (lower bounded row)
        constraint_indices = np.array([VAR_INDEX_X, VAR_INDEX_Y])
        constraint_values = np.array([CONSTRAINT_COEFF_X, CONSTRAINT_COEFF_Y])
        h.addRow(CONSTRAINT_LOWER_BOUND, inf, NUM_CONSTRAINT_NONZEROS,
                 constraint_indices, constraint_values)

        # Solve the LP using HiPO interior point method
        status = h.solve()

        # Verify solve succeeded
        assert status == highspy.HighsStatus.kOk

        # Verify optimal objective value
        # Interior point methods converge to optimal within tolerance
        info = h.getInfo()
        assert info.objective_function_value == pytest.approx(
            EXPECTED_OBJECTIVE_VALUE, abs=10**-OBJECTIVE_TOLERANCE_PLACES
        )
