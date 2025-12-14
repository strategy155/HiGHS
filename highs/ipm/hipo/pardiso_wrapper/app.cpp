//
// Created by parf on 10/10/2025.
//


#include <cstdio>
#include "mkl.h"

 constexpr long long int DEFAULT_MTYPE = 1;

int main()
{
  MKLVersion mkl_version;
  mkl_get_version(&mkl_version);

  long long int pardiso_handle[64];
  long long int pardiso_control[64];

  pardisoinit(pardiso_handle, &DEFAULT_MTYPE, pardiso_control);
  


  printf("You are using oneMKL %d.%d\n", mkl_version.MajorVersion, mkl_version.UpdateVersion);

  return 0;
}
