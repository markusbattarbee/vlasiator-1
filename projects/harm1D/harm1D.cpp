/*
This file is part of Vlasiator.

Copyright 2011, 2012 Finnish Meteorological Institute

Vlasiator is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License version 3
as published by the Free Software Foundation.

Vlasiator is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Vlasiator. If not, see <http://www.gnu.org/licenses/>.
*/

#include <cstdlib>
#include <iostream>
#include <cmath>
#include <limits>

#include "spatial_cell.hpp"
#include "common.h"
#include "project.h"
#include "parameters.h"
#include "readparameters.h"

using namespace std;

bool initializeProject(void) {return true;}
bool addProjectParameters(){return true;}
bool getProjectParameters(){return true;}

bool cellParametersChanged(creal& t) {return false;}

Real calcPhaseSpaceDensity(creal& x,creal& y,creal& z,creal& dx,creal& dy,creal& dz,
			   creal& vx,creal& vy,creal& vz,creal& dvx,creal& dvy,creal& dvz) {
   /*
    creal VX0 = 0.5;
    creal VY0 = 0.0;
    creal VZ0 = 0.0;
    creal SIGMA = 0.4714;
    creal INVSIG2 = 1.0/(SIGMA*SIGMA);
    return 1.5*exp(-INVSIG2*(vx-VX0)*(vx-VX0))*exp(-INVSIG2*(vy-VY0)*(vy-VY0))*exp(-INVSIG2*(vz-VZ0)*(vz-VZ0));
    */
   creal X0 = 1.0/14.0;
   creal Y0 = 1.0/14.0;
   
   creal VX0 = -0.4;
   creal VY0 = -0.4;
   creal VZ0 = 0.0;
   creal DVX = 0.1;
   creal DVY = 0.1;
   creal DVZ = 0.1;
   creal VSIGMA = 0.2;
   creal INVVSIG2 = 1.0/(VSIGMA*VSIGMA);

   if (fabs(x + 0.6) > dx) return 1e-10;
   if (fabs(vx) > 0.051) return 1e-10;
   if (fabs(vy) > 0.8) return 1e-10;
   if (fabs(vz) > 0.8) return 1e-10;
   //if (fabs(x) > X0 || fabs(y) > Y0) return 0.0;
   //if (fabs(vy-VY0) > DVY) return 0.0;
   //if (fabs(vz-VZ0) > DVZ) return 0.0;
   //return 5.0*exp(-INVVSIG2*(vx-VX0)*(vx-VX0))*exp(-INVVSIG2*(vy-VY0)*(vy-VY0))*exp(-INVVSIG2*(vz-VZ0)*(vz-VZ0));
   return 1.0;
}

void calcBlockParameters(Real* blockParams) {
   //blockParams[BlockParams::Q_PER_M] = 1.0;
}

void calcCellParameters(Real* cellParams,creal& t) {
   creal x = cellParams[CellParams::XCRD];
   creal dx = cellParams[CellParams::DX];

   // Setting these is not needed for correct propagation, 
   // but may be a good idea for visualization:
   cellParams[CellParams::EX   ] = -1.0*(x+0.5*dx);
   cellParams[CellParams::EY   ] = 0.0;
   cellParams[CellParams::EZ   ] = 0.0;
   cellParams[CellParams::BX   ] = 0.0;
   cellParams[CellParams::BY   ] = 0.0;
   cellParams[CellParams::BZ   ] = 0.0;
   
   // Volume-averaged fields need to be set:
   cellParams[CellParams::EXVOL] = -1.0*(x+0.5*dx);
   cellParams[CellParams::EYVOL] = 0.0;
   cellParams[CellParams::EZVOL] = 0.0;
   cellParams[CellParams::BXVOL] = 0.0;
   cellParams[CellParams::BYVOL] = 0.0;
   cellParams[CellParams::BZVOL] = 0.0;
}

// TODO use this instead: template <class Grid, class CellData> void calcSimParameters(Grid<CellData>& mpiGrid...

void calcSimParameters(dccrg::Dccrg<SpatialCell>& mpiGrid, creal& t, Real& /*dt*/) {
   std::vector<uint64_t> cells = mpiGrid.get_cells();
   for (uint i = 0; i < cells.size(); ++i) {
      calcCellParameters(mpiGrid[cells[i]]->parameters, t);
   }
}


