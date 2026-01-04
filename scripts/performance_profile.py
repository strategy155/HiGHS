#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["polars", "lark"]
# ///
"""Generate Dolan-Moré performance profiles from benchmark results.

Reference:
    Dolan, E.D., Moré, J.J. (2002). Benchmarking optimization software with
    performance profiles. Mathematical Programming 91, 201-213.
    https://doi.org/10.1007/s101070100263

Usage:
    uv run performance_profile.py results.parquet --output-dir profiles/
"""

import argparse
import sys
from pathlib import Path

import polars as pl

import parse_results

# Exit codes (POSIX convention)
EXIT_SUCCESS = 0
EXIT_FAILURE = 1

# Default paths
DEFAULT_OUTPUT_DIR = Path("profiles")

# Performance profile parameters
RATIO_COLUMN = "ratio"
BEST_TIME_COLUMN = "best_time"
FRACTION_COLUMN = "fraction"

# Configuration columns that identify a unique solver setup
CONFIG_COLUMNS = [
    parse_results.FIELD_SYSTEM,
    parse_results.FIELD_SOLVER,
    parse_results.FIELD_IS_PARALLEL,
    parse_results.FIELD_THREADS,
]

# Comparison group columns (parallel × threads - each group shows all solver×system combos)
COMPARISON_GROUP_COLUMNS = [
    parse_results.FIELD_IS_PARALLEL,
    parse_results.FIELD_THREADS,
]

# Solver names for .dat file column headers
SOLVER_HIGHS = "highs"
SOLVER_PARDISO = "pardiso"

# Composite column for pivot ({solver}_{system})
SOLVER_SYSTEM_COLUMN = "solver_system"

# pgfplots .dat file column names
DAT_COLUMN_TAU = "tau"

# Cumulative distribution parameters
TAU_MIN = 1.0
TAU_MAX = 10.0
TAU_STEPS = 100


def build_config_name(system: str, solver: str, is_parallel: bool, threads: int) -> str:
    """Build a unique configuration name from components.

    Args:
        system: Linear system formulation (normaleq, augmented).
        solver: Solver name (highs, pardiso).
        is_parallel: Whether parallel mode is enabled.
        threads: Number of threads.

    Returns:
        Configuration name like 'augmented-pardiso-paron-t256'.
    """
    parallel_str = parse_results.PARALLEL_ON if is_parallel else parse_results.PARALLEL_OFF
    threads_str = f"{parse_results.THREADS_PREFIX}{threads}"

    parts = [system, solver, parallel_str, threads_str]
    name = parse_results.CONFIG_SEPARATOR.join(parts)

    return name


def build_comparison_group_name(is_parallel: bool, threads: int) -> str:
    """Build a comparison group name (parallel × threads).

    Used for naming .dat files that show all solver×system combinations.

    Args:
        is_parallel: Whether parallel mode is enabled.
        threads: Number of threads.

    Returns:
        Group name like 'paron-t256'.
    """
    parallel_str = parse_results.PARALLEL_ON if is_parallel else parse_results.PARALLEL_OFF
    threads_str = f"{parse_results.THREADS_PREFIX}{threads}"

    parts = [parallel_str, threads_str]
    name = parse_results.CONFIG_SEPARATOR.join(parts)

    return name


def compute_performance_ratios(
    df: pl.DataFrame,
    time_column: str,
) -> pl.DataFrame:
    """Compute performance ratios τ = t_solver / t_best for each problem.

    For each problem, finds the best (minimum) time across all configurations,
    then computes the ratio of each configuration's time to that best time.

    Reference:
        Dolan & Moré (2002), Eq. 2.1: r_{p,s} = t_{p,s} / min{t_{p,s} : s ∈ S}

    Args:
        df: DataFrame with benchmark results.
        time_column: Column containing runtime values.

    Returns:
        DataFrame with added 'ratio' column, filtered to valid times only.
    """
    time_col = pl.col(time_column)
    problem_col = parse_results.FIELD_PROBLEM

    # Filter to rows with valid time values
    has_valid_time = time_col.is_not_null()
    df_valid = df.filter(has_valid_time)

    # Compute best time per problem: t_p^* = min_s t_{p,s}
    best_time_expr = time_col.min().over(problem_col).alias(BEST_TIME_COLUMN)
    df_with_best = df_valid.with_columns(best_time_expr)

    # Compute ratio: r_{p,s} = t_{p,s} / t_p^*
    best_time_col = pl.col(BEST_TIME_COLUMN)
    ratio_expr = (time_col / best_time_col).alias(RATIO_COLUMN)
    df_with_ratio = df_with_best.with_columns(ratio_expr)

    # Drop intermediate column
    result = df_with_ratio.drop(BEST_TIME_COLUMN)

    return result


def generate_tau_values(tau_min: float, tau_max: float, n_steps: int) -> list[float]:
    """Generate evenly spaced τ values for performance profile x-axis.

    Args:
        tau_min: Minimum τ value (typically 1.0).
        tau_max: Maximum τ value for x-axis cutoff.
        n_steps: Number of points to generate.

    Returns:
        List of τ values from tau_min to tau_max.
    """
    step_size = (tau_max - tau_min) / n_steps
    tau_values = [tau_min + i * step_size for i in range(n_steps + 1)]
    return tau_values


def compute_cumulative_fraction(
    ratios: pl.Series,
    tau: float,
    total_problems: int,
) -> float:
    """Compute P(τ) = fraction of problems with ratio ≤ τ.

    Reference:
        Dolan & Moré (2002), Eq. 2.3: ρ_s(τ) = |{p : r_{p,s} ≤ τ}| / n_p

    Args:
        ratios: Series of performance ratios for one configuration.
        tau: Threshold value.
        total_problems: Total number of problems in benchmark set.

    Returns:
        Fraction of problems solved within factor τ of best.
    """
    n_solved = ratios.filter(ratios <= tau).len()
    fraction = n_solved / total_problems
    return fraction


def compute_profile_for_config(
    df_config: pl.DataFrame,
    tau_values: list[float],
    total_problems: int,
    system: str,
    solver: str,
    is_parallel: bool,
    threads: int,
) -> pl.DataFrame:
    """Compute performance profile curve for a single configuration.

    Args:
        df_config: DataFrame filtered to one configuration.
        tau_values: List of τ values for x-axis.
        total_problems: Total number of problems in benchmark set.
        system: Linear system formulation.
        solver: Solver name.
        is_parallel: Whether parallel mode is enabled.
        threads: Number of threads.

    Returns:
        DataFrame with columns [system, solver, is_parallel, threads, tau, fraction].
    """
    ratios = df_config[RATIO_COLUMN]

    fractions = [
        compute_cumulative_fraction(ratios, tau, total_problems)
        for tau in tau_values
    ]

    n_points = len(tau_values)

    profile_df = pl.DataFrame({
        parse_results.FIELD_SYSTEM: [system] * n_points,
        parse_results.FIELD_SOLVER: [solver] * n_points,
        parse_results.FIELD_IS_PARALLEL: [is_parallel] * n_points,
        parse_results.FIELD_THREADS: [threads] * n_points,
        DAT_COLUMN_TAU: tau_values,
        FRACTION_COLUMN: fractions,
    })

    return profile_df


def build_config_filter(config_row: dict[str, object]) -> pl.Expr:
    """Build a Polars filter expression for a specific configuration.

    Creates a conjunction (AND) of equality conditions for each configuration
    column. This allows filtering a DataFrame to rows matching exactly one
    solver configuration.

    Args:
        config_row: Dictionary with column names as keys and config values.
                    Expected keys: system, solver, is_parallel, threads.

    Returns:
        Polars expression that evaluates to True for matching rows.

    Example:
        config_row = {'system': 'augmented', 'solver': 'pardiso', ...}
        filter_expr = build_config_filter(config_row)
        df_filtered = df.filter(filter_expr)
    """
    # Start with always-true expression, then AND each column condition
    filter_expr = pl.lit(True)

    for col in CONFIG_COLUMNS:
        col_value = config_row[col]
        col_condition = pl.col(col) == col_value
        filter_expr = filter_expr & col_condition

    return filter_expr


def compute_all_profiles(
    df_ratios: pl.DataFrame,
    tau_values: list[float],
    total_problems: int,
) -> pl.DataFrame:
    """Compute performance profiles for all configurations.

    Args:
        df_ratios: DataFrame with computed performance ratios.
        tau_values: List of τ values for x-axis.
        total_problems: Total number of problems in benchmark set.

    Returns:
        Single DataFrame with columns [system, solver, is_parallel, threads, tau, fraction].
    """
    unique_configs = df_ratios.select(CONFIG_COLUMNS).unique()
    profile_dfs: list[pl.DataFrame] = []

    for config_row in unique_configs.iter_rows(named=True):
        system = config_row[parse_results.FIELD_SYSTEM]
        solver = config_row[parse_results.FIELD_SOLVER]
        is_parallel = config_row[parse_results.FIELD_IS_PARALLEL]
        threads = config_row[parse_results.FIELD_THREADS]

        # Filter to this configuration
        config_filter = build_config_filter(config_row)
        df_config = df_ratios.filter(config_filter)

        # Compute profile curve
        profile = compute_profile_for_config(
            df_config, tau_values, total_problems,
            system, solver, is_parallel, threads,
        )

        profile_dfs.append(profile)

    # Concatenate all profiles into single DataFrame
    all_profiles = pl.concat(profile_dfs)

    return all_profiles


# TSV separator for pgfplots compatibility
TSV_SEPARATOR = "\t"


def export_profiles_to_dat(
    all_profiles: pl.DataFrame,
    output_dir: Path,
) -> None:
    """Export performance profiles to .dat files for pgfplots.

    Groups by (parallel, threads) and pivots on {solver}_{system}.
    Each file contains 4 curves: highs_augmented, highs_normaleq, etc.

    Args:
        all_profiles: DataFrame with columns [system, solver, is_parallel, threads, tau, fraction].
        output_dir: Directory to write .dat files.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # Create composite column: "highs_augmented", "pardiso_normaleq", etc.
    solver_col = pl.col(parse_results.FIELD_SOLVER)
    system_col = pl.col(parse_results.FIELD_SYSTEM)
    composite_format = pl.format("{}_{}", solver_col, system_col)
    solver_system_expr = composite_format.alias(SOLVER_SYSTEM_COLUMN)

    df_with_composite = all_profiles.with_columns(solver_system_expr)

    # Partition by (parallel, threads)
    partitions = df_with_composite.partition_by(COMPARISON_GROUP_COLUMNS, as_dict=True)

    for group_key, group_df in partitions.items():
        is_parallel, threads = group_key

        group_name = build_comparison_group_name(is_parallel, threads)
        output_file = output_dir / f"{group_name}.dat"

        # Pivot: rows=tau, columns=solver_system, values=fraction
        pivoted = group_df.pivot(
            on=SOLVER_SYSTEM_COLUMN,
            index=DAT_COLUMN_TAU,
            values=FRACTION_COLUMN,
        )

        # Write tab-separated .dat file
        pivoted.write_csv(output_file, separator=TSV_SEPARATOR)

        print(f"Wrote {output_file}")


def main() -> int:
    """Generate performance profiles from benchmark results."""
    parser = argparse.ArgumentParser(
        description="Generate Dolan-Moré performance profiles"
    )
    parser.add_argument(
        "input_file",
        type=Path,
        help="Parquet file with benchmark results",
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Output directory for .dat files (default: {DEFAULT_OUTPUT_DIR})",
    )

    args = parser.parse_args()
    input_file: Path = args.input_file

    if not input_file.exists():
        print(f"Error: {input_file} does not exist", file=sys.stderr)
        return EXIT_FAILURE

    df = pl.read_parquet(input_file)
    record_count = len(df)

    print(f"Loaded {record_count} records")

    # Compute performance ratios using HiGHS runtime
    time_column = parse_results.FIELD_HIGHS_RUNTIME
    df_ratios = compute_performance_ratios(df, time_column)
    valid_count = len(df_ratios)

    print(f"Computed ratios for {valid_count} records with valid {time_column}")

    # Get unique problems count (for P(τ) denominator)
    unique_problems = df[parse_results.FIELD_PROBLEM].unique()
    total_problems = len(unique_problems)
    print(f"Total problems in benchmark set: {total_problems}")

    # Generate τ values and compute all profiles
    tau_values = generate_tau_values(TAU_MIN, TAU_MAX, TAU_STEPS)
    all_profiles = compute_all_profiles(df_ratios, tau_values, total_problems)

    n_configs = len(all_profiles.select(CONFIG_COLUMNS).unique())
    print(f"Generated profiles for {n_configs} configurations")

    # Export to .dat files
    output_dir: Path = args.output_dir
    export_profiles_to_dat(all_profiles, output_dir)

    return EXIT_SUCCESS


if __name__ == "__main__":
    sys.exit(main())
