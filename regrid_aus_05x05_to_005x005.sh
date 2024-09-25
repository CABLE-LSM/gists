#!/bin/bash
set -e

script_name="${0}"

if [ $# -lt 2 ]; then
    echo "${script_name}: need at least two arguments"
    echo "Usage: ${script_name} [--append-bios] <input_file> <output_file>"
    exit 1
fi

append_bios=false
if [ "${1}" = "--append-bios" ]; then
    shift
    append_bios=true
fi

input_file=${1}
output_file=${2}
echo "input: ${input_file}"
echo "output: ${output_file}"

if [ ${input_file} = ${output_file} ]; then
    echo "${script_name}: output_file must differ from input_file"
    exit 1
fi

module load conda_concept/analysis3-24.01

echo "Copy input file to output file"
ncks --overwrite --no-alphabetize ${input_file} ${output_file}

date=$(date '+%d.%m.%Y')
modification_attr="${script_name}: Clip to Australian region and subsample from 0.5 degrees resolution to 0.05 degrees using nearest neighbour interpolation. ${date}\n"

echo "Add modification note to global attributes"
ncatted -h -a modification,global,p,c,"${modification_attr}" ${output_file}

aus_lon_min=112.0
aus_lon_max=154.0
aus_lat_min=-44.0
aus_lat_max=-10.0

echo "Select grid points over Australia"
ncks --overwrite --no-alphabetize \
    -d longitude,${aus_lon_min},${aus_lon_max} \
    -d latitude,${aus_lat_min},${aus_lat_max} \
    ${output_file} ${output_file}

aus_lon_dim_05x05=84 # abs(aus_lon_max - aus_lon_min) / 0.5
aus_lat_dim_05x05=68 # abs(aus_lat_max - aus_lat_min) / 0.5

echo "Generate grid file at 0.5 deg resolution"
ncks --overwrite \
    --rgr grd_ttl='Regional 05x05 degree grid (Australia)' \
    --rgr latlon=${aus_lat_dim_05x05},${aus_lon_dim_05x05} \
    --rgr lat_sth=${aus_lat_max} --rgr lat_nrt=${aus_lat_min} \
    --rgr lon_wst=${aus_lon_min} --rgr lon_est=${aus_lon_max} \
    --rgr grid=grd_05x05.nc \
    ${input_file} $(mktemp --suffix=.nc)

aus_lon_dim_005x005=840 # abs(aus_lon_max - aus_lon_min) / 0.05
aus_lat_dim_005x005=680 # abs(aus_lat_max - aus_lat_min) / 0.05

echo "Generate grid file at 0.05 deg resolution"
ncks --overwrite \
    --rgr grd_ttl='Regional 005x005 degree grid (Australia)' \
    --rgr latlon=${aus_lat_dim_005x005},${aus_lon_dim_005x005} \
    --rgr lat_nrt=${aus_lat_min} --rgr lat_sth=${aus_lat_max} \
    --rgr lon_wst=${aus_lon_min} --rgr lon_est=${aus_lon_max} \
    --rgr grid=grd_005x005.nc \
    ${input_file} $(mktemp --suffix=.nc)

echo "Generate map file with nearest neighbour interpolation"
ncremap -a neareststod \
    -s grd_05x05.nc \
    -g grd_005x005.nc \
    -m map_05x05_to_005x005_neareststod.nc

echo "Regrid output file"
ncks --overwrite --no-alphabetize \
    --map map_05x05_to_005x005_neareststod.nc \
    ${output_file} ${output_file}

# Note: the direction in which to offset the lat and lon coordinates was chosen
# such that we retain bitwise reproducibility in existing BIOS configurations
# which use the 0.5 degree gridinfo file.
echo "Offset by half a grid cell (0.025 deg) in lat-lon coordinates to align
with BIOS ancillary inputs."
ncap2 --overwrite \
    -s "lat_bnds-=0.025;lon_bnds+=0.025" \
    ${output_file} ${output_file}
ncap2 --overwrite \
    -s "latitude-=0.025;longitude+=0.025" \
    ${output_file} ${output_file}

bios_lon_min=112.925
bios_lon_max=153.575
bios_lat_min=-43.575
bios_lat_max=-10.075

echo "Select grid points according to BIOS ancillary inputs"
ncks --overwrite --no-alphabetize \
    -d longitude,${bios_lon_min},${bios_lon_max} \
    -d latitude,${bios_lat_min},${bios_lat_max} \
    ${output_file} ${output_file}

echo "Clean up"
rm grd_05x05.nc grd_005x005.nc map_05x05_to_005x005_neareststod.nc

if [ "${append_bios}" = false ]; then
    exit
fi

: ${BIOS_PARAM_DIR=./bios_params}

date=$(date '+%d.%m.%Y')
modification_attr="${script_name}: Update soil parameter values with fields as used in the BIOS model framework. Limits are applied onto new soil parameters in line with the code in cable_bios_met_obs_params.F90. ${date}\n"

echo "Add modification note to global attributes"
ncatted -h -a modification,global,p,c,"${modification_attr}" ${output_file}

# TODO(Sean): check unit, standard name, long name attributes for appended variables

silt_file=${BIOS_PARAM_DIR}/siltfrac1.nc
echo "silt_file: ${silt_file}"

echo "Rename variable siltfrac1 to silt"
ncrename --overwrite -v siltfrac1,silt ${silt_file} silt.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    silt.nc silt.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude silt.nc silt.nc

echo "Remove silt variable from output file"
ncks --overwrite --no-alphabetize -x -v silt \
    ${output_file} ${output_file}

echo "Append silt variable to output file"
ncks -A -v silt silt.nc ${output_file}

clay_file=${BIOS_PARAM_DIR}/clayfrac1.nc
echo "clay_file: ${clay_file}"

echo "Rename variable clayfrac1 to clay"
ncrename --overwrite -v clayfrac1,clay ${clay_file} clay.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    clay.nc clay.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude clay.nc clay.nc

echo "Remove clay variable from output file"
ncks --overwrite --no-alphabetize -x -v clay \
    ${output_file} ${output_file}

echo "Append clay variable to output file"
ncks -A -v clay clay.nc ${output_file}

echo "Create sand file"
ncks --overwrite --no-alphabetize silt.nc sand.nc
ncks -A -v clay clay.nc sand.nc
ncap2 --overwrite \
    -s "sand=float(1.0-silt-clay)" \
    sand.nc sand.nc
ncks --overwrite -v sand sand.nc sand.nc

echo "Remove sand variable from output file"
ncks --overwrite --no-alphabetize -x -v sand \
    ${output_file} ${output_file}

echo "Append sand variable to output file"
ncks -A -v sand sand.nc ${output_file}

css_file=${BIOS_PARAM_DIR}/csoil1.nc
echo "css_file: ${css_file}"

echo "Rename variable csoil1 to css"
ncrename --overwrite -v csoil1,css ${css_file} css.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    css.nc css.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude css.nc css.nc

echo "Remove css variable from output file"
ncks --overwrite --no-alphabetize -x -v css \
    ${output_file} ${output_file}

echo "Append css variable to output file"
ncks -A -v css css.nc ${output_file}

sfc_file=${BIOS_PARAM_DIR}/wvol1fc_m3m3.nc
echo "sfc_file: ${sfc_file}"

echo "Rename variable wvol1fc_m3m3 to sfc"
ncrename --overwrite -v wvol1fc_m3m3,sfc ${sfc_file} sfc.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    sfc.nc sfc.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude sfc.nc sfc.nc

echo "Remove sfc variable from output file"
ncks --overwrite --no-alphabetize -x -v sfc \
    ${output_file} ${output_file}

echo "Append sfc variable to output file"
ncks -A -v sfc sfc.nc ${output_file}

rhosoil_file=${BIOS_PARAM_DIR}/bulkdens1_kgm3.nc
echo "rhosoil_file: ${rhosoil_file}"

echo "Rename variable bulkdens1_kgm3 to rhosoil"
ncrename --overwrite -v bulkdens1_kgm3,rhosoil ${rhosoil_file} rhosoil.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    rhosoil.nc rhosoil.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude rhosoil.nc rhosoil.nc

echo "Remove rhosoil variable from output file"
ncks --overwrite --no-alphabetize -x -v rhosoil \
    ${output_file} ${output_file}

echo "Append rhosoil variable to output file"
ncks -A -v rhosoil rhosoil.nc ${output_file}

bch_file=${BIOS_PARAM_DIR}/b1.nc
echo "bch_file: ${bch_file}"

echo "Rename variable b1 to bch"
ncrename --overwrite -v b1,bch ${bch_file} bch.nc

echo "Apply bch limits"
ncap2 --overwrite \
    -s "where(bch > 16.0) bch = 16.0" \
    bch.nc bch.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    bch.nc bch.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude bch.nc bch.nc

echo "Remove bch variable from output file"
ncks --overwrite --no-alphabetize -x -v bch \
    ${output_file} ${output_file}

echo "Append bch variable to output file"
ncks -A -v bch bch.nc ${output_file}

hyds_file=${BIOS_PARAM_DIR}/hyk1sat_ms.nc
echo "hyds_file: ${hyds_file}"

echo "Rename variable hyk1sat_ms to hyds"
ncrename --overwrite -v hyk1sat_ms,hyds ${hyds_file} hyds.nc

echo "Apply hyds limits"
ncap2 --overwrite \
    -s "where(hyds < 1.0e-8) hyds = 1.0e-8" \
    hyds.nc hyds.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    hyds.nc hyds.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude hyds.nc hyds.nc

echo "Remove hyds variable from output file"
ncks --overwrite --no-alphabetize -x -v hyds \
    ${output_file} ${output_file}

echo "Append hyds variable to output file"
ncks -A -v hyds hyds.nc ${output_file}

ssat_file=${BIOS_PARAM_DIR}/wvol1sat_m3m3.nc
echo "ssat_file: ${ssat_file}"

echo "Rename variable wvol1sat_m3m3 to ssat"
ncrename --overwrite -v wvol1sat_m3m3,ssat ${ssat_file} ssat.nc

echo "Apply ssat limits"
ncap2 --overwrite \
    -s "where(ssat < 0.4) ssat = 0.4" \
    ssat.nc ssat.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    ssat.nc ssat.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude ssat.nc ssat.nc

echo "Remove ssat variable from output file"
ncks --overwrite --no-alphabetize -x -v ssat \
    ${output_file} ${output_file}

echo "Append ssat variable to output file"
ncks -A -v ssat ssat.nc ${output_file}

swilt_file=${BIOS_PARAM_DIR}/wvol1w_m3m3.nc
echo "swilt_file: ${swilt_file}"

echo "Rename variable wvol1w_m3m3 to swilt"
ncrename --overwrite -v wvol1w_m3m3,swilt ${swilt_file} swilt.nc

echo "Apply swilt limits"
ncap2 --overwrite \
    -s "where(swilt > 0.2) swilt = 0.2" \
    swilt.nc swilt.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    swilt.nc swilt.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude swilt.nc swilt.nc

echo "Remove swilt variable from output file"
ncks --overwrite --no-alphabetize -x -v swilt \
    ${output_file} ${output_file}

echo "Append swilt variable to output file"
ncks -A -v swilt swilt.nc ${output_file}

sucs_file=${BIOS_PARAM_DIR}/psie1_m.nc
echo "sucs_file: ${sucs_file}"

echo "Rename variable psie1_m to sucs"
ncrename --overwrite -v psie1_m,sucs ${sucs_file} sucs.nc

echo "Apply sucs limits"
ncap2 --overwrite \
    -s "where(sucs < -2.0) sucs = -2.0" \
    sucs.nc sucs.nc

echo "Apply sucs sign convention"
ncap2 --overwrite \
    -s "sucs *= -1.0" \
    sucs.nc sucs.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    sucs.nc sucs.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude sucs.nc sucs.nc

echo "Remove sucs variable from output file"
ncks --overwrite --no-alphabetize -x -v sucs \
    ${output_file} ${output_file}

echo "Append sucs variable to output file"
ncks -A -v sucs sucs.nc ${output_file}

mvg_file=${BIOS_PARAM_DIR}/nvis5pre1750grp.nc
echo "mvg_file: ${mvg_file}"

echo "Rename variable nvis5pre1750grp to mvg"
ncrename --overwrite -v nvis5pre1750grp,mvg ${mvg_file} mvg.nc

echo "Cast mvg values to int"
ncap2 --overwrite -s "mvg=int(mvg)" mvg.nc mvg.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    mvg.nc mvg.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude mvg.nc mvg.nc

echo "Remove mvg variable from output file"
ncks --overwrite --no-alphabetize -x -v mvg \
    ${output_file} ${output_file}

echo "Append mvg variable to output file"
ncks -A -v mvg mvg.nc ${output_file}

c4frac_file=${BIOS_PARAM_DIR}/c4_grass_frac_cov.nc
echo "c4frac_file: ${c4frac_file}"

echo "Rename variable c4_grass_frac_cov to c4frac"
ncrename --overwrite -v c4_grass_frac_cov,c4frac ${c4frac_file} c4frac.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    c4frac.nc c4frac.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude c4frac.nc c4frac.nc

echo "Remove c4frac variable from output file"
ncks --overwrite --no-alphabetize -x -v c4frac \
    ${output_file} ${output_file}

echo "Append c4frac variable to output file"
ncks -A -v c4frac c4frac.nc ${output_file}

modis_igbp_file=${BIOS_PARAM_DIR}/vegtypeigbp_ctr05.nc
echo "modis_igbp_file: ${modis_igbp_file}"

echo "Rename variable vegtypeigbp_ctr05 to modis_igbp"
ncrename --overwrite -v vegtypeigbp_ctr05,modis_igbp \
    ${modis_igbp_file} modis_igbp.nc

echo "Cast modis_igbp values to int"
ncap2 --overwrite -s "modis_igbp=int(modis_igbp)" modis_igbp.nc modis_igbp.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    modis_igbp.nc modis_igbp.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude modis_igbp.nc modis_igbp.nc

echo "Remove modis_igbp variable from output file"
ncks --overwrite --no-alphabetize -x -v modis_igbp \
    ${output_file} ${output_file}

echo "Append modis_igbp variable to output file"
ncks -A -v modis_igbp modis_igbp.nc ${output_file}

avgannmax_fapar_file=${BIOS_PARAM_DIR}/avgannmaxdata1998-2005_ctr05.nc
echo "avgannmax_fapar_file: ${avgannmax_fapar_file}"

echo "Rename variable avgannmaxdata1998-2005_ctr05 to avgannmax_fapar"
ncrename --overwrite -v avgannmaxdata1998-2005_ctr05,avgannmax_fapar \
    ${avgannmax_fapar_file} avgannmax_fapar.nc

echo "Rename lat-lon coordinate variables and dimensions to latitude-longitude"
ncrename --overwrite \
    -d lat,latitude -v lat,latitude \
    -d lon,longitude -v lon,longitude \
    avgannmax_fapar.nc avgannmax_fapar.nc

echo "Re-order data so that latitude values decrease monotonically from North
to South"
ncpdq --overwrite -a -latitude avgannmax_fapar.nc avgannmax_fapar.nc

echo "Remove avgannmax_fapar variable from output file"
ncks --overwrite --no-alphabetize -x -v avgannmax_fapar \
    ${output_file} ${output_file}

echo "Append avgannmax_fapar variable to output file"
ncks -A -v avgannmax_fapar avgannmax_fapar.nc ${output_file}

echo "Clean up"
rm avgannmax_fapar.nc clay.nc modis_igbp.nc sand.nc ssat.nc bch.nc css.nc hyds.nc mvg.nc sfc.nc sucs.nc c4frac.nc rhosoil.nc silt.nc swilt.nc

