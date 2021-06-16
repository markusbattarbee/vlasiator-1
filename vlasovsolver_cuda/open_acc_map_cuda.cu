#include "cuda_header.cuh"
#include "open_acc_map_h.cuh"
#include "../vlasovsolver/vec.h"
#include "../definitions.h"

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "cuda.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NPP_MAXABS_32F ( 3.402823466e+38f )
#define NPP_MINABS_32F ( 1.175494351e-38f )

#define NPP_MAXABS_64F ( 1.7976931348623158e+308 )
#define NPP_MINABS_64F ( 2.2250738585072014e-308 )

#define HANDLE_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ));

__constant__ int acc_semilag_flag;
//__constant__ int WID_DEVICE = WID;

/*
#if VECTORCLASS_H >= 20000
  __constant__ int VECTORCLASS_H_DEVICE = 20102;
#else
  __constant__ int VECTORCLASS_H_DEVICE = 0;
#endif
*/

#define HANDLE_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ));
static void HandleError( cudaError_t err, const char *file, int line )
{
    if (err != cudaSuccess)
    {
        printf( "%s in %s at line %d\n", cudaGetErrorString( err ), file, line );
        exit( EXIT_FAILURE );
    }
}

__device__ Vec minmod(const Vec slope1, const Vec slope2)
{
  Vec zero(0.0);
  Vec slope = select(abs(slope1) < abs(slope2), slope1, slope2);
  return select(slope1 * slope2 <= 0, zero, slope);
}
__device__ Vec maxmod(const Vec slope1, const Vec slope2)
{
  Vec zero(0.0);
  Vec slope=select(abs(slope1) > abs(slope2), slope1, slope2);
  //check for extrema
  return select(slope1 * slope2 <= 0, zero, slope);
}
__device__ Vec slope_limiter_sb(Vec& l, Vec& m, Vec& r)
{
  Vec a = r-m;
  Vec b = m-l;
  Vec slope1 = minmod(a, 2*b);
  Vec slope2 = minmod(2*a, b);
  return maxmod(slope1, slope2);
}
__device__ Vec slope_limiter(Vec& l,Vec& m,Vec& r)
{
   return slope_limiter_sb(l,m,r);
}
__device__ void compute_plm_coeff(Vec *values, uint k, Vec *a, Realv threshold)
{
  // scale values closer to 1 for more accurate slope limiter calculation
  Realv scale = 1./threshold;
  Vec v_1 = values[k - 1] * scale;
  Vec v_2 = values[k] * scale;
  Vec v_3 = values[k + 1] * scale;
  Vec d_cv = slope_limiter(v_1, v_2, v_3) * threshold;
  a[0] = values[k] - d_cv * 0.5;
  a[1] = d_cv * 0.5;
}

__device__ int i_pcolumnv(int j, int k, int k_block, int num_k_blocks, int WID_device)
{
  return ((j) / ( VECL / WID_device)) * WID_device * ( num_k_blocks + 2) + (k) + ( k_block + 1 ) * WID_device;
}

__global__ void acceleration_1
(
  Realf *dev_blockData,
  int totalColumns,
  Column *dev_columns,
  Vec *values,
  int *dev_cell_indices_to_id,
  int WID_device,
  Realv intersection,
  Realv intersection_di,
  Realv intersection_dj,
  Realv intersection_dk,
  Realv minValue,
  Realv dv,
  Realv v_min
)
{
  //printf("CUDA 1\n");
  for( uint column=0; column < totalColumns; column++)
  {
    //printf("CUDA 2\n");
     // i,j,k are relative to the order in which we copied data to the values array.
     // After this point in the k,j,i loops there should be no branches based on dimensions
     // Note that the i dimension is vectorized, and thus there are no loops over i
     // Iterate through the perpendicular directions of the column
     for (uint j = 0; j < WID_device; j += VECL/WID_device)
     {
       //printf("CUDA 3\n");
        const vmesh::LocalID nblocks = dev_columns[column].nblocks;
        // create vectors with the i and j indices in the vector position on the plane.
        #if VECL == 4
          const Veci i_indices = Veci(0, 1, 2, 3);
          const Veci j_indices = Veci(j, j, j, j);
        #elif VECL == 8
          const Veci i_indices = Veci(0, 1, 2, 3, 0, 1, 2, 3);
          const Veci j_indices = Veci(j, j, j, j, j + 1, j + 1, j + 1, j + 1);
        #elif VECL == 16
          const Veci i_indices = Veci(0, 1, 2, 3,
                                      0, 1, 2, 3,
                                      0, 1, 2, 3,
                                      0, 1, 2, 3);
          const Veci j_indices = Veci(j, j, j, j,
                                      j + 1, j + 1, j + 1, j + 1,
                                      j + 2, j + 2, j + 2, j + 2,
                                      j + 3, j + 3, j + 3, j + 3);
        #endif
        const Veci  target_cell_index_common =
           i_indices * dev_cell_indices_to_id[0] +
           j_indices * dev_cell_indices_to_id[1];

        // intersection_min is the intersection z coordinate (z after
        // swaps that is) of the lowest possible z plane for each i,j
        // index (i in vector)
        const Vec intersection_min =
           intersection +
           (dev_columns[column].i * WID_device + to_realv(i_indices)) * intersection_di +
           (dev_columns[column].j * WID_device + to_realv(j_indices)) * intersection_dj;

        /*compute some initial values, that are used to set up the
         * shifting of values as we go through all blocks in
         * order. See comments where they are shifted for
         * explanations of their meaning*/
        Vec v_r0( (WID_device * dev_columns[column].kBegin) * dv + v_min);
        Vec lagrangian_v_r0((v_r0-intersection_min)/intersection_dk);

        /* compute location of min and max, this does not change for one
        column (or even for this set of intersections, and can be used
        to quickly compute max and min later on*/
        //TODO, these can be computed much earlier, since they are
        //identiacal for each set of intersections
        int minGkIndex=0, maxGkIndex=0; // 0 for compiler
        {
            #if defined (VEC4D_FALLBACK) || defined (VEC8D_FALLBACK)
            Realv maxV = NPP_MAXABS_64F;
            Realv minV = NPP_MINABS_64F;
            #endif
            #if defined (VEC4F_FALLBACK) || defined (VEC8F_FALLBACK)
            Realv maxV = NPP_MAXABS_32F;
            Realv minV = NPP_MINABS_32F;
            #endif
           //Realv maxV = std::numeric_limits<Realv>::min();
           //Realv minV = std::numeric_limits<Realv>::max();
           for(int i = 0; i < VECL; i++)
           {
              if ( lagrangian_v_r0[i] > maxV)
              {
                 maxV = lagrangian_v_r0[i];
                 maxGkIndex = i;
              }
              if ( lagrangian_v_r0[i] < minV)
              {
                 minV = lagrangian_v_r0[i];
                 minGkIndex = i;
              }
           }
        }
        // loop through all blocks in column and compute the mapping as integrals.
        for (uint k=0; k < WID_device * nblocks; ++k )
        {
          //printf("CUDA 4\n");
           // Compute reconstructions
           // values + i_pcolumnv(n_cblocks, -1, j, 0) is the starting point of the column data for fixed j
           // k + WID is the index where we have stored k index, WID amount of padding.
            //if(acc_semilag_flag==0)
            //{
              //Vec a[2];
              Vec *a = new Vec[2];
              compute_plm_coeff(values + dev_columns[column].valuesOffset + i_pcolumnv(j, 0, -1, nblocks, WID_device), k + WID_device, a, minValue);
            //}
            /*
            if(acc_semilag_flag==1)
            {
              Vec a[3];
              compute_ppm_coeff(values + columns[column].valuesOffset  + i_pcolumnv(j, 0, -1, nblocks), h4, k + WID, a, minValue);
            }
            if(acc_semilag_flag==2)
            {
              Vec a[5];
              compute_pqm_coeff(values + columns[column].valuesOffset  + i_pcolumnv(j, 0, -1, nblocks), h8, k + WID, a, minValue);
            }
            */
           // set the initial value for the integrand at the boundary at v = 0
           // (in reduced cell units), this will be shifted to target_density_1, see below.
           Vec target_density_r(0.0);
           // v_l, v_r are the left and right velocity coordinates of source cell.
           Vec v_r = v_r0  + (k+1)* dv;
           Vec v_l = v_r0  + k* dv;
           // left(l) and right(r) k values (global index) in the target
           // Lagrangian grid, the intersecting cells. Again old right is new left.
           Veci lagrangian_gk_l,lagrangian_gk_r;
           /*
           if(VECTORCLASS_H_DEVICE >= 20000)
            {
              lagrangian_gk_r = truncatei((v_l-intersection_min)/intersection_dk);
              lagrangian_gk_r = truncatei((v_r-intersection_min)/intersection_dk);
            }
            else
            {
              lagrangian_gk_l = truncate_to_int((v_l-intersection_min)/intersection_dk);
              lagrangian_gk_r = truncate_to_int((v_r-intersection_min)/intersection_dk);
            }
            */
            // I keep only this version with Fallback, because the version with Agner requires another call to CPU
            lagrangian_gk_l = truncate_to_int((v_l-intersection_min)/intersection_dk);
            lagrangian_gk_r = truncate_to_int((v_r-intersection_min)/intersection_dk);
           //limits in lagrangian k for target column. Also take into
           //account limits of target column
           int minGk = max(int(lagrangian_gk_l[minGkIndex]), int(dev_columns[column].minBlockK * WID_device));
           int maxGk = min(int(lagrangian_gk_r[maxGkIndex]), int((dev_columns[column].maxBlockK + 1) * WID_device - 1));
           // Run along the column and perform the polynomial reconstruction
           //for(int gk = minGk; gk <= maxGk; gk++){
           for(int gk = dev_columns[column].minBlockK * WID_device; gk <= dev_columns[column].maxBlockK * WID_device; gk++)
           {
             //printf("CUDA 5\n");
              if(gk < minGk || gk > maxGk)
              {
                 continue;
              }
              const int blockK = gk/WID_device;
              const int gk_mod_WID = (gk - blockK * VECL);
              //the block of the Lagrangian cell to which we map
              //const int target_block(target_block_index_common + blockK * block_indices_to_id[2]);
              //cell indices in the target block  (TODO: to be replaced by
              //compile time generated scatter write operation)
              const Veci target_cell(target_cell_index_common + gk_mod_WID * dev_cell_indices_to_id[2]);
              //the velocity between which we will integrate to put mass
              //in the targe cell. If both v_r and v_l are in same cell
              //then v_1,v_2 should be between v_l and v_r.
              //v_1 and v_2 normalized to be between 0 and 1 in the cell.
              //For vector elements where gk is already larger than needed (lagrangian_gk_r), v_2=v_1=v_r and thus the value is zero.
              const Vec v_norm_r = (  min(  max( (gk + 1) * intersection_dk + intersection_min, v_l), v_r) - v_l) * (1.0/dv);
              /*shift, old right is new left*/
              const Vec target_density_l = target_density_r;
              // compute right integrand
              if(acc_semilag_flag==0)
                target_density_r = v_norm_r * ( a[0] + v_norm_r * a[1] );
              if(acc_semilag_flag==1)
                target_density_r = v_norm_r * ( a[0] + v_norm_r * ( a[1] + v_norm_r * a[2] ) );
              if(acc_semilag_flag==2)
                target_density_r =
                  v_norm_r * ( a[0] + v_norm_r * ( a[1] + v_norm_r * ( a[2] + v_norm_r * ( a[3] + v_norm_r * a[4] ) ) ) );
              //store values, one element at a time. All blocks have been created by now.
              //TODO replace by vector version & scatter & gather operation
              const Vec target_density = target_density_r - target_density_l;
              for (int target_i=0; target_i < VECL; ++target_i)
              {
                // do the conversion from Realv to Realf here, faster than doing it in accumulation
                const Realf tval = target_density[target_i];
                const uint tcell = target_cell[target_i];
                (&dev_blockData[dev_columns[column].targetBlockOffsets[blockK]])[tcell] += tval;
              }  // for-loop over vector elements
           } // for loop over target k-indices of current source block
        } // for-loop over source blocks
     } //for loop over j index
  } //for loop over columns
}

Realf* acceleration_1_wrapper
(
  int bdsw3,
  Realf *blockData,
  int totalColumns,
  Column *columns,
  int valuesSizeRequired,
  Vec *values,
  uint cell_indices_to_id[],
  Realv intersection,
  Realv intersection_di,
  Realv intersection_dj,
  Realv intersection_dk,
  Realv v_min,
  Realv dv,
  Realv minValue
)
{
  printf("STAGE 3\n");

//    cudaMemcpyToSymbol("WID_DEVICE", &WID_DEVICE, sizeof(int));
//  cudaMemcpyToSymbol("VECTORCLASS_H_DEVICE", &VECTORCLASS_H_DEVICE, sizeof(int));

  int acc_semilag_flag = 0;
  #ifdef ACC_SEMILAG_PLM
    acc_semilag_flag = 0;
  #endif
  #ifdef ACC_SEMILAG_PPM
    acc_semilag_flag = 1;
  #endif
  #ifdef ACC_SEMILAG_PQM
    acc_semilag_flag = 2;
  #endif
  cudaMemcpyToSymbol("acc_semilag_flag", &acc_semilag_flag, sizeof(int));

  Realf *dev_blockData;
  HANDLE_ERROR( cudaMalloc((void**)&dev_blockData, bdsw3*sizeof(Realf)));
  HANDLE_ERROR( cudaMemcpy(dev_blockData, blockData, bdsw3*sizeof(Realf), cudaMemcpyHostToDevice));

  Column *dev_columns;
  HANDLE_ERROR( cudaMalloc((void**)&dev_columns, totalColumns*sizeof(Column)));
  HANDLE_ERROR( cudaMemcpy(dev_columns, columns, totalColumns*sizeof(Column), cudaMemcpyHostToDevice));

  Vec *dev_values;
  HANDLE_ERROR( cudaMalloc((void**)&dev_values, valuesSizeRequired*sizeof(Vec)));
  HANDLE_ERROR( cudaMemcpy(dev_values, values, valuesSizeRequired*sizeof(Vec), cudaMemcpyHostToDevice));

  int *dev_cell_indices_to_id;
  HANDLE_ERROR( cudaMalloc((void**)&dev_cell_indices_to_id, 3*sizeof(int)));
  HANDLE_ERROR( cudaMemcpy(dev_cell_indices_to_id, cell_indices_to_id, 3*sizeof(int), cudaMemcpyHostToDevice));

  int WID_device = WID;
  printf("WID_device = %d\n", WID_device);
  acceleration_1<<<BLOCKS, THREADS>>>
  (
    dev_blockData,
    totalColumns,
    dev_columns,
    dev_values,
    dev_cell_indices_to_id,
    WID_device,
    intersection,
    intersection_di,
    intersection_dj,
    intersection_dk,
    minValue,
    dv,
    v_min
  );

  HANDLE_ERROR( cudaMemcpy(blockData, dev_blockData, bdsw3*sizeof(Realf), cudaMemcpyDeviceToHost));

  HANDLE_ERROR( cudaFree(dev_blockData) );
  HANDLE_ERROR( cudaFree(dev_cell_indices_to_id) );
  HANDLE_ERROR( cudaFree(dev_columns) );
  HANDLE_ERROR( cudaFree(dev_values) );

  return blockData;
}
