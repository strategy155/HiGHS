#include "PardisoSolver.h"

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "ipm/hipo/auxiliary/Auxiliary.h"
#include "ipm/hipo/ipm/Status.h"

// NOTE: We deliberately use the Intel MKL PARDISO API directly rather than Eigen's
// built-in PardisoLU/PardisoLLT wrappers. This gives us more control over the solver
// parameters and phases. However, we may consider switching to Eigen's wrapper in the
// future if it proves sufficient for our needs.

namespace hipo {

// Control constant for dumping normal equations matrix and RHS
static constexpr bool kDumpNormalEquations = false;

// Helper function to dump Eigen sparse matrix and RHS in CSR format with 1-based
// Fortran indexing. Assumes the matrix is in RowMajor (CSR) format.
// Format specification:
//   n           - matrix size
//   nnz         - number of non-zeros
//   ia[0..n]    - row pointers (1-based)
//   ja[0..nnz-1] - column indices (1-based)
//   a[0..nnz-1]  - values (scientific notation)
//   b[0..n-1]    - RHS values
static void dumpNormalEquationsCSR(EigenSparseMatrix& matrix,
                                   const std::vector<double>& rhs,
                                   const std::string& filename) {
  std::cout << "=== Dumping Normal Equations to file: " << filename << " ===" << std::endl;

  // Ensure matrix is in compressed format
  matrix.makeCompressed();

  const Int n = matrix.rows();

  // Validate RHS size
  if (static_cast<Int>(rhs.size()) != n) {
    std::cerr << "ERROR: RHS size mismatch! Matrix size: " << n
              << ", RHS size: " << rhs.size() << std::endl;
    return;
  }

  // Extract upper triangular part using Eigen's triangular view
  EigenSparseMatrix upper_tri = matrix.triangularView<Eigen::Upper>();
  upper_tri.makeCompressed();

  const Int nnz = upper_tri.nonZeros();

  std::cout << "Matrix size: " << n << " x " << n << std::endl;
  std::cout << "Number of nonzeros (upper triangle): " << nnz << std::endl;
  std::cout << "RHS size: " << rhs.size() << std::endl;

  // Access compressed CSR arrays directly from upper triangular matrix
  const Int* row_ptr = upper_tri.outerIndexPtr();  // Row pointers (0-based)
  const Int* col_idx = upper_tri.innerIndexPtr();  // Column indices (0-based)
  const double* values = upper_tri.valuePtr();      // Values

  // Write to file
  std::ofstream file(filename);
  if (!file.is_open()) {
    std::cerr << "ERROR: Failed to open file for writing: " << filename << std::endl;
    return;
  }

  std::cout << "Writing matrix in CSR format with 1-based Fortran indexing..." << std::endl;

  file << std::scientific << std::setprecision(16);

  // Write matrix size
  file << n << "\n";

  // Write number of nonzeros
  file << nnz << "\n";

  // Write row pointers (ia) - convert to 1-based indexing
  for (Int i = 0; i <= n; ++i) {
    file << (row_ptr[i] + 1) << "\n";
  }

  // Write column indices (ja) - convert to 1-based indexing
  for (Int i = 0; i < nnz; ++i) {
    file << (col_idx[i] + 1) << "\n";
  }

  // Write values (a) in scientific notation
  for (Int i = 0; i < nnz; ++i) {
    file << values[i] << "\n";
  }

  // Write RHS (b)
  for (Int i = 0; i < n; ++i) {
    file << rhs[i] << "\n";
  }

  file.close();

  std::cout << "Successfully wrote normal equations to: " << filename << std::endl;
  std::cout << "========================================" << std::endl;
}

// PARDISO parameter constants
constexpr PardisoInt kPardisoUseDefaultParameters = 0;
constexpr PardisoInt kPardisoZeroBasedIndexing = 1;

// PARDISO parameter array positions
constexpr PardisoInt kPardisoDefaultParameterPosition = 0;
constexpr PardisoInt kPardisoIndexingParameterPosition = 34;

// PARDISO phase constants
constexpr PardisoInt kPardisoPhaseAnalysis = 11;
constexpr PardisoInt kPardisoPhaseFactorization = 22;
constexpr PardisoInt kPardisoPhaseAnalysisAndFactorization = 12;
constexpr PardisoInt kPardisoPhaseSolve = 33;
constexpr PardisoInt kPardisoPhaseReleaseMemory = -1;

// PARDISO matrix type constants
constexpr PardisoInt kPardisoMatrixTypeIndefiniteSymmetric = -2;
constexpr PardisoInt kPardisoMatrixTypePositiveDefinite = 2;

// PARDISO fixed parameters
constexpr PardisoInt kPardisoMaxfct = 1;  // Maximum number of factors
constexpr PardisoInt kPardisoMnum = 1;    // Which factorization to use
constexpr PardisoInt kPardisoNrhs = 1;    // Number of right-hand sides
constexpr PardisoInt kPardisoMsglvl = 0;  // Message level (0 = no output)

PardisoSolver::PardisoSolver(const Model& model,
                             const Regularisation& regularisation,
                             Options& options, const LogHighs& log)
    : pardiso_internal_memory_{},
      pardiso_parameters_{},
      pardiso_matrix_type_{kPardisoMatrixTypeIndefiniteSymmetric},
      system_size_{0},
      nonzero_values_{},
      row_start_indices_{},
      column_indices_{},
      eigen_pardiso_solver_{},
      model_{model},
      regularisation_{regularisation},
      options_{options},
      log_{log} {

  // Set first parameter to 0 to force PARDISO defaults
  pardiso_parameters_[kPardisoDefaultParameterPosition] = kPardisoUseDefaultParameters;

  // Set zero-based indexing for CSR format
  pardiso_parameters_[kPardisoIndexingParameterPosition] = kPardisoZeroBasedIndexing;

  // // Initialize PARDISO with default parameters
  // pardisoinit(pardiso_internal_memory_.data(), &pardiso_matrix_type_,
  //             pardiso_parameters_.data());

  valid_ = false;
}

PardisoSolver::~PardisoSolver() noexcept {
  // Eigen's PardisoLDLT destructor automatically handles PARDISO memory cleanup
  // Just ensure solver state is invalidated
  valid_ = false;
}

void PardisoSolver::clear() {
  valid_ = false;
}

Int PardisoSolver::factorAS(const HighsSparseMatrix& A,
                            const std::vector<double>& scaling) {
  // Build augmented system: [ -Θ  A^T ]
  //                         [  A   0  ]
  // where Θ is diagonal with scaling values

  // Build augmented system matrix with scaled diagonal
  EigenSparseMatrix augmented_system_matrix = buildAugmentedSystemMatrix(A, scaling);

  // Numerical factorization only (symbolic analysis already done in setup())
  eigen_pardiso_solver_.factorize(augmented_system_matrix);

  if (eigen_pardiso_solver_.info() != Eigen::Success) {
    valid_ = false;
    return kStatusErrorFactorise;
  }

  valid_ = true;
  system_size_ = A.num_col_ + A.num_row_;
  return kStatusOk;
}

Int PardisoSolver::solveAS(const std::vector<double>& rhs_x,
                           const std::vector<double>& rhs_y,
                           std::vector<double>& lhs_x,
                           std::vector<double>& lhs_y) {
  if (!valid_) {
    return kStatusErrorSolve;
  }

  const Int num_vars = rhs_x.size();
  const Int num_constraints = rhs_y.size();

  // Build concatenated right-hand side vector using Eigen comma syntax
  Eigen::VectorXd rhs_x_eigen = Eigen::Map<const Eigen::VectorXd>(rhs_x.data(), num_vars);
  Eigen::VectorXd rhs_y_eigen = Eigen::Map<const Eigen::VectorXd>(rhs_y.data(), num_constraints);

  Eigen::VectorXd eigen_rhs(num_vars + num_constraints);
  eigen_rhs << rhs_x_eigen, rhs_y_eigen;

  // Solve using Eigen PARDISO wrapper
  Eigen::VectorXd eigen_lhs = eigen_pardiso_solver_.solve(eigen_rhs);

  if (eigen_pardiso_solver_.info() != Eigen::Success) {
    return kStatusErrorSolve;
  }

  // Extract solution components
  lhs_x.resize(num_vars);
  lhs_y.resize(num_constraints);

  for (Int i = 0; i < num_vars; ++i) {
    lhs_x[i] = eigen_lhs[i];
  }

  for (Int i = 0; i < num_constraints; ++i) {
    lhs_y[i] = eigen_lhs[num_vars + i];
  }

  return kStatusOk;
}

Int PardisoSolver::factorNE(const HighsSparseMatrix& A,
                            const std::vector<double>& scaling) {
  // Build normal equations: A * Θ^{-1} * A^T
  // where Θ^{-1} = diag(1 / (scaling[i] + regularisation.primal))

  // Convert constraint matrix A to Eigen format
  EigenSparseMatrix eigen_A = convertToEigen(A);

  // Compute transpose of original (unscaled) A
  EigenSparseMatrix eigen_A_transpose = eigen_A.transpose();

  // Apply diagonal scaling with regularization: compute A * Θ
  applyDiagonalScaling(eigen_A, scaling);

  // Compute normal equations matrix: (A * Θ) * A^T
  EigenSparseMatrix normal_equations_matrix = eigen_A * eigen_A_transpose;

  // Store matrix for dumping if enabled
  if (kDumpNormalEquations) {
    ne_matrix_to_dump_ = normal_equations_matrix;
  }

  // Numerical factorization only (symbolic analysis already done in setup())
  eigen_pardiso_solver_.factorize(normal_equations_matrix);

  if (eigen_pardiso_solver_.info() != Eigen::Success) {
    valid_ = false;
    return kStatusErrorFactorise;
  }

  valid_ = true;
  system_size_ = A.num_row_;
  return kStatusOk;
}

Int PardisoSolver::solveNE(const std::vector<double>& rhs,
                           std::vector<double>& lhs) {
  if (!valid_) {
    return kStatusErrorSolve;
  }

  // Dump normal equations matrix and RHS if enabled
  if (kDumpNormalEquations) {
    // Generate filename with sequential counter (zero-padded to 4 digits)
    std::stringstream filename;
    filename << "pardiso_normal_equations_"
             << std::setfill('0') << std::setw(4) << dump_counter_
             << ".txt";

    dumpNormalEquationsCSR(ne_matrix_to_dump_, rhs, filename.str());
    dump_counter_++;  // Increment for next call
  }

  // Convert rhs to Eigen vector
  Eigen::VectorXd eigen_rhs(rhs.size());
  for (size_t i = 0; i < rhs.size(); ++i) {
    eigen_rhs[i] = rhs[i];
  }

  // Solve using Eigen PARDISO wrapper
  Eigen::VectorXd eigen_lhs = eigen_pardiso_solver_.solve(eigen_rhs);

  if (eigen_pardiso_solver_.info() != Eigen::Success) {
    return kStatusErrorSolve;
  }

  // Convert solution back to std::vector
  lhs.resize(eigen_lhs.size());
  for (Int i = 0; i < eigen_lhs.size(); ++i) {
    lhs[i] = eigen_lhs[i];
  }

  return kStatusOk;
}

Int PardisoSolver::setup() {
  return setSystemType();
}

// Convert HighsSparseMatrix to Eigen sparse matrix using triplet list
EigenSparseMatrix PardisoSolver::convertToEigen(const HighsSparseMatrix& A) {
  // Use Eigen's recommended triplet pattern for efficient sparse matrix construction
  typedef Eigen::Triplet<double> EigenTriplet;
  std::vector<EigenTriplet> triplet_list;

  // Reserve space for all nonzeros to avoid reallocation
  const Int num_nonzeros = A.numNz();
  triplet_list.reserve(num_nonzeros);

  // HighsSparseMatrix stores data in column-wise compressed format
  // For each column, start_[col] gives the starting position in index_[] and value_[]
  // The column's entries run from start_[col] to start_[col+1]-1
  for (Int col = 0; col < A.num_col_; ++col) {
    const Int column_start = A.start_[col];

    // Determine where this column's entries end
    Int column_end;
    const bool is_last_column = (col == A.num_col_ - 1);
    if (is_last_column) {
      // Last column extends to the end of the arrays
      column_end = num_nonzeros;
    } else {
      // Other columns end where the next column begins
      column_end = A.start_[col + 1];
    }

    // Extract all entries in this column
    for (Int position = column_start; position < column_end; ++position) {
      const Int row = A.index_[position];
      const double value = A.value_[position];
      triplet_list.push_back(EigenTriplet(row, col, value));
    }
  }

  // Construct Eigen sparse matrix from triplets
  EigenSparseMatrix eigen_matrix(A.num_row_, A.num_col_);
  eigen_matrix.setFromTriplets(triplet_list.begin(), triplet_list.end());

  return eigen_matrix;
}

// Apply diagonal scaling with regularization to matrix columns
// Computes A * Θ^{-1} where Θ^{-1} = diag(1 / (scaling[i] + regularisation.primal))
void PardisoSolver::applyDiagonalScaling(EigenSparseMatrix& matrix,
                                         const std::vector<double>& scaling) {
  // Build diagonal scaling vector Θ^{-1}
  Eigen::VectorXd theta_inverse(matrix.cols());

  for (Int col = 0; col < matrix.cols(); ++col) {
    if (scaling.empty()) {
      // No scaling provided, use identity
      theta_inverse[col] = 1.0;
    } else {
      // Apply scaling with primal regularization: 1 / (scaling[col] + regul.primal)
      const double denominator = scaling[col] + regularisation_.primal;
      theta_inverse[col] = 1.0 / denominator;
    }
  }

  // Use Eigen's optimized diagonal matrix multiplication: A * Θ^{-1}
  matrix = matrix * theta_inverse.asDiagonal();
}

// Build augmented system matrix: [ -Θ  A^T ]
//                                 [  A   0  ]
// where Θ is diagonal matrix with theta[i] values
// Constructs the full symmetric matrix in Eigen format
EigenSparseMatrix PardisoSolver::buildAugmentedSystemMatrix(
    const HighsSparseMatrix& A, const std::vector<double>& theta) {

  const Int num_vars = A.num_col_;
  const Int num_constraints = A.num_row_;
  const Int augmented_system_size = num_vars + num_constraints;

  // Use triplet list for efficient sparse matrix construction
  typedef Eigen::Triplet<double> EigenTriplet;
  std::vector<EigenTriplet> triplets;

  // Estimate number of nonzeros: n diagonal + 2*nnz(A)
  const Int num_nonzeros_A = A.numNz();
  const Int estimated_nonzeros = num_vars + 2 * num_nonzeros_A;
  triplets.reserve(estimated_nonzeros);

  // Block (1,1): -Θ diagonal matrix (n x n)
  for (Int i = 0; i < num_vars; ++i) {
    double theta_value;
    if (theta.empty()) {
      theta_value = 1.0;
    } else {
      theta_value = theta[i];
    }
    const double diagonal_entry = -theta_value;
    triplets.push_back(EigenTriplet(i, i, diagonal_entry));
  }

  // Blocks (1,2) and (2,1): A^T and A
  // A is stored in CSC format: A.start_[col] gives column starts
  for (Int col = 0; col < num_vars; ++col) {
    const Int column_start = A.start_[col];

    Int column_end;
    if (col == num_vars - 1) {
      column_end = num_nonzeros_A;
    } else {
      column_end = A.start_[col + 1];
    }

    for (Int position = column_start; position < column_end; ++position) {
      const Int row_in_A = A.index_[position];
      const double value = A.value_[position];

      // Block (1,2): A^T - upper right block
      const Int row_in_augmented_upper = col;
      const Int col_in_augmented_upper = row_in_A + num_vars;
      triplets.push_back(EigenTriplet(row_in_augmented_upper, col_in_augmented_upper, value));

      // Block (2,1): A - lower left block (transpose of A^T)
      const Int row_in_augmented_lower = row_in_A + num_vars;
      const Int col_in_augmented_lower = col;
      triplets.push_back(EigenTriplet(row_in_augmented_lower, col_in_augmented_lower, value));
    }
  }

  // Block (2,2) is zero matrix - no entries needed in sparse format

  // Construct the full augmented system matrix from triplets
  EigenSparseMatrix augmented_system_matrix(augmented_system_size, augmented_system_size);
  augmented_system_matrix.setFromTriplets(triplets.begin(), triplets.end());

  return augmented_system_matrix;
}

// Overload for structure-only analysis (uses identity diagonal)
EigenSparseMatrix PardisoSolver::buildAugmentedSystemMatrix(const HighsSparseMatrix& A) {
  const Int num_vars = A.num_col_;
  std::vector<double> identity_scaling(num_vars, 1.0);
  return buildAugmentedSystemMatrix(A, identity_scaling);
}

// Load upper triangle from Eigen matrix into internal CSR3 structures
void PardisoSolver::loadUpperTriangleFromEigen(const EigenSparseMatrix& matrix) {
  // Clear existing storage
  nonzero_values_.clear();
  row_start_indices_.clear();
  column_indices_.clear();

  system_size_ = matrix.rows();

  // Reserve space (upper bound estimate)
  const Int estimated_nonzeros = matrix.nonZeros();
  nonzero_values_.reserve(estimated_nonzeros);
  column_indices_.reserve(estimated_nonzeros);
  row_start_indices_.reserve(system_size_ + 1);

  // TODO: Consider using matrix.triangularView<Eigen::Upper>() instead of manual filtering
  // This might be more efficient and clearer in intent

  // Build CSR3 format row by row, extracting only upper triangle
  for (Int current_row = 0; current_row < system_size_; ++current_row) {
    // Record starting position for this row
    const Int current_row_start_position = nonzero_values_.size();
    const PardisoInt pardiso_row_start = static_cast<PardisoInt>(current_row_start_position);
    row_start_indices_.push_back(pardiso_row_start);

    // Collect entries in this row where column >= row (upper triangle)
    for (EigenSparseMatrix::InnerIterator matrix_iterator(matrix, current_row);
         matrix_iterator;
         ++matrix_iterator) {
      const Int entry_column = matrix_iterator.col();

      // Only store upper triangle entries where column >= row
      if (entry_column >= current_row) {
        const double entry_value = matrix_iterator.value();
        const PardisoInt pardiso_column_index = static_cast<PardisoInt>(entry_column);
        column_indices_.push_back(pardiso_column_index);
        nonzero_values_.push_back(entry_value);
      }
    }
  }

  // Add final row_start index pointing to end of arrays
  const Int total_nonzeros = nonzero_values_.size();
  const PardisoInt pardiso_total_nonzeros = static_cast<PardisoInt>(total_nonzeros);
  row_start_indices_.push_back(pardiso_total_nonzeros);
}

// System type selection: dispatcher based on options_.nla
Int PardisoSolver::setSystemType() {
  Int system_setter_status = kStatusOk;

  if (options_.nla == kOptionNlaAugmented) {
    system_setter_status = analyseAS();
  } else if (options_.nla == kOptionNlaNormEq) {
    system_setter_status = analyseNE();
  } else {  // kOptionNlaChoose
    system_setter_status = chooseSystemType();
  }

  return system_setter_status;
}

// Performs symbolic factorization analysis of the augmented system.
//
// Builds the augmented system matrix structure and performs symbolic factorization
// (structure analysis only). The result is cached in eigen_pardiso_solver_ for
// later numerical factorization in factorAS().
//
// Returns:
//   kStatusOk on success
//   kStatusErrorAnalyse if symbolic factorization fails
Int PardisoSolver::analyseAS() {
  const HighsSparseMatrix& A = model_.A();

  // Build augmented system structure with identity scaling
  EigenSparseMatrix augmented_system_matrix = buildAugmentedSystemMatrix(A);

  // Perform symbolic factorization (analyzePattern does not use numerical values)
  eigen_pardiso_solver_.analyzePattern(augmented_system_matrix);

  Eigen::ComputationInfo analysis_info = eigen_pardiso_solver_.info();
  if (analysis_info != Eigen::Success) {
    return kStatusErrorAnalyse;
  }

  return kStatusOk;
}

// Builds normal equations matrix for structure analysis.
//
// Computes A * A^T which forms the m x m normal equations system.
// Used for symbolic factorization analysis only.
//
// Args:
//   A: Constraint matrix in HiGHS sparse column format
//
// Returns:
//   Normal equations matrix A * A^T in Eigen sparse format
EigenSparseMatrix PardisoSolver::buildNormalEquationsMatrix(const HighsSparseMatrix& A) {
  // Convert HiGHS sparse format to Eigen
  EigenSparseMatrix eigen_A = convertToEigen(A);

  // Compute transpose
  EigenSparseMatrix eigen_A_transpose = eigen_A.transpose();

  // Form normal equations: A * A^T (m x m matrix)
  EigenSparseMatrix normal_equations_matrix = eigen_A * eigen_A_transpose;

  return normal_equations_matrix;
}

// Performs symbolic factorization analysis of the normal equations.
//
// Builds the normal equations matrix A * A^T structure and performs symbolic
// factorization (structure analysis only). The result is cached in
// eigen_pardiso_solver_ for later numerical factorization in factorNE().
//
// Returns:
//   kStatusOk on success
//   kStatusErrorAnalyse if symbolic factorization fails
Int PardisoSolver::analyseNE() {
  const HighsSparseMatrix& A = model_.A();

  // Build normal equations structure
  EigenSparseMatrix normal_equations_matrix = buildNormalEquationsMatrix(A);

  // Perform symbolic factorization (analyzePattern does not use numerical values)
  eigen_pardiso_solver_.analyzePattern(normal_equations_matrix);

  Eigen::ComputationInfo analysis_info = eigen_pardiso_solver_.info();
  if (analysis_info != Eigen::Success) {
    return kStatusErrorAnalyse;
  }

  return kStatusOk;
}

// Automatically selects system type (AS or NE) based on simple heuristics.
//
// Uses two criteria for selection:
// 1. Dense column detection: Skip NE if matrix has dense columns (poor conditioning)
// 2. Analysis failure fallback: Use whichever formulation succeeds analysis
//
// If both formulations succeed analysis, defaults to AS (more numerically stable).
//
// Returns:
//   kStatusOk on success (options_.nla is updated with selection)
//   kStatusErrorAnalyse if both formulations fail analysis
Int PardisoSolver::chooseSystemType() {
  assert(options_.nla == kOptionNlaChoose);

  // Try augmented system analysis first
  Int status_AS = analyseAS();
  bool failure_AS = (status_AS != kStatusOk);
  bool failure_NE = false;

  // Check for dense columns (indicates poor conditioning for NE)
  bool has_dense_columns = (model_.m() > kMinRowsForDensity &&
                            model_.maxColDensity() > kDenseColThresh);

  if (has_dense_columns) {
    failure_NE = true;
    log_.print( "Pardiso: Dense columns detected, using AS\n");
  } else if (!failure_AS) {
    // Try normal equations analysis
    Int status_NE = analyseNE();
    failure_NE = (status_NE != kStatusOk);
  }

  // Select system type based on analysis results
  if (failure_NE && !failure_AS) {
    options_.nla = kOptionNlaAugmented;
    log_.print("Pardiso: KKT system = AS\n");
  } else if (failure_AS && !failure_NE) {
    options_.nla = kOptionNlaNormEq;
    log_.print("Pardiso: KKT system = NE\n");
  } else if (failure_AS && failure_NE) {
    log_.print("Pardiso: Both AS and NE analysis failed\n");
    return kStatusErrorAnalyse;
  } else {
    // Both succeed - default to AS (more numerically stable)
    options_.nla = kOptionNlaAugmented;
    log_.print("Pardiso: KKT system = AS (default)\n");
  }

  return kStatusOk;
}

}  // namespace hipo
