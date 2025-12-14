#ifndef HIPO_PARDISO_SOLVER_H
#define HIPO_PARDISO_SOLVER_H

#include <array>
#include <vector>

#include <Eigen/Sparse>
#include <Eigen/PardisoSupport>

#include "ipm/hipo/ipm/LinearSolver.h"
#include "ipm/hipo/ipm/LogHighs.h"
#include "ipm/hipo/ipm/Model.h"
#include "ipm/hipo/ipm/Options.h"
#include "ipm/hipo/ipm/Parameters.h"
#include "mkl.h"

namespace hipo {

// Type alias for PARDISO API requirement
using PardisoInt = long long int;

// Eigen sparse matrix type alias (RowMajor for CSR format)
using EigenSparseMatrix = Eigen::SparseMatrix<double, Eigen::RowMajor, Int>;

class PardisoSolver : public LinearSolver {
 private:
  // PARDISO internal data structures
  std::array<void*, 64> pardiso_internal_memory_;      // PARDISO internal memory handle (pt array)
  std::array<PardisoInt, 64> pardiso_parameters_;      // PARDISO configuration parameters (iparm array)
  PardisoInt pardiso_matrix_type_;                     // Matrix type (-2: indefinite, 2: positive definite)
  PardisoInt system_size_;                             // Dimension of linear system

  // CSR3 matrix storage (0-based indexing, upper triangle only for symmetric)
  std::vector<double> nonzero_values_;                     // All non-zero matrix values
  std::vector<PardisoInt> row_start_indices_;              // Index of first non-zero in each row
  std::vector<PardisoInt> column_indices_;                 // Column indices ordered per row

  // Eigen PARDISO wrapper for symmetric indefinite systems
  Eigen::PardisoLDLT<EigenSparseMatrix> eigen_pardiso_solver_;

  // References to HiPO structures
  const Model& model_;
  const Regularisation& regularisation_;
  Options& options_;
  const LogHighs& log_;

  // Storage for dumping normal equations matrix and RHS
  EigenSparseMatrix ne_matrix_to_dump_;
  int dump_counter_ = 0;  // Sequential counter for dump filenames

  // Load upper triangle from Eigen matrix into internal CSR3 structures
  void loadUpperTriangleFromEigen(const EigenSparseMatrix& matrix);

  // Apply diagonal scaling with regularization to matrix columns
  void applyDiagonalScaling(EigenSparseMatrix& matrix,
                            const std::vector<double>& scaling);

  // Build augmented system matrix: [ -Θ  A^T ]
  //                                 [  A   0  ]
  // where Θ is diagonal matrix with theta[i] values
  // Returns full matrix in Eigen format
  EigenSparseMatrix buildAugmentedSystemMatrix(const HighsSparseMatrix& A,
                                                const std::vector<double>& theta);

  // Overload for structure-only analysis (uses identity diagonal)
  EigenSparseMatrix buildAugmentedSystemMatrix(const HighsSparseMatrix& A);

  // Build normal equations matrix: A * A^T (for structure analysis)
  EigenSparseMatrix buildNormalEquationsMatrix(const HighsSparseMatrix& A);

  // System type selection methods (AS vs NE)
  Int setSystemType();      // Dispatcher based on options_.nla
  Int chooseSystemType();   // Automatic selection using dense column check + fallback
  Int analyseAS();          // Symbolic analysis of augmented system
  Int analyseNE();          // Symbolic analysis of normal equations

  // // Helper functions for building normal equations
  // Int buildNEstructure(const HighsSparseMatrix& A);
  // Int buildNEvalues(const HighsSparseMatrix& A, const std::vector<double>& scaling);

 public:
  // Convert HighsSparseMatrix (column-wise) to Eigen sparse matrix format
  static EigenSparseMatrix convertToEigen(const HighsSparseMatrix& A);
  PardisoSolver(const Model& model, const Regularisation& regularisation,
                Options& options, const LogHighs& log);
  ~PardisoSolver() noexcept override;

  Int factorAS(const HighsSparseMatrix& A,
               const std::vector<double>& scaling) override;

  Int solveAS(const std::vector<double>& rhs_x,
              const std::vector<double>& rhs_y,
              std::vector<double>& lhs_x,
              std::vector<double>& lhs_y) override;

  Int factorNE(const HighsSparseMatrix& A,
               const std::vector<double>& scaling) override;

  Int solveNE(const std::vector<double>& rhs,
              std::vector<double>& lhs) override;

  void clear() override;

  Int setup() override;
};

}  // namespace hipo

#endif