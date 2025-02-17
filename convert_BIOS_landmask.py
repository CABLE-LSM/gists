import xarray
import numpy

def read_header(HeaderFile):
    """Read the header file and return a dictionary of its attributes."""

    Attrs = {}
    for line in open(HeaderFile, 'r').readlines():
        Attr, Value = line.split()
        Attrs[Attr] = Value

    return Attrs

def convert_landmask(HeaderFile, FltFile, OutFile):
    """Convert a given header, flt landmask into NetCDF format."""

    HeaderContents = read_header(HeaderFile)

    # Inspect the contents of the header to set up the array to write to
    nCols = int(HeaderContents['ncols'])
    nRows = int(HeaderContents['nrows'])
    MissingVal = int(HeaderContents['NODATA_value'])

    # Read the data from the binary file
    SourceData = numpy.fromfile(FltFile, dtype=numpy.float32)
    
    # Reshape to the desired shape, and convert values to Int8
    SourceData = SourceData.reshape(nRows, nCols)
    SourceData = numpy.where(SourceData == MissingVal, 0, 1).astype(numpy.int8)
    print(SourceData.sum())

    # The landmask is defined in descending latitude order, we want it
    # ascending (once we move to NetCDF gridinfo)
    # SourceData = numpy.flip(SourceData, axis=0)

    # Construct the latitude and longitude dimensions
    LonStart = float(HeaderContents['xllcorner'])
    LatStart = float(HeaderContents['yllcorner'])
    Resolution = float(HeaderContents['cellsize'])

    Longitudes = numpy.linspace(
            LonStart + 0.5 * Resolution,    # Convert to cell centre
            LonStart + (nCols - 0.5) * Resolution,
            nCols,
            dtype=numpy.float32
            )

    Latitudes = numpy.linspace(
            LatStart + 0.5 * Resolution,    # Convert to cell centre
            LatStart + (nRows - 0.5) * Resolution,
            nRows,
            dtype=numpy.float32
            )
    
    # Create the xarray dataset to write to file
    Landmask = xarray.Dataset(
            data_vars={
                'land': (('latitude', 'longitude'), SourceData)
                },
            coords={
                'longitude': ('longitude', Longitudes),
                'latitude': ('latitude', Latitudes)
                },
            attrs={
                'description': f'Landmask created from the {HeaderFile} and' +\
                        f' {FltFile}. Land=1, sea=0'
                }
            )

    # Despite MaskedData being of dtype int8, xarray decides to write it as
    # float32 unless we tell it specifically not to
    Landmask.to_netcdf(OutFile)

if __name__ == '__main__':
    # Specify the hdr, flt and output file here
    convert_landmask(
            '/g/data/rp23/experiments/2024-04-17_BIOS3-merge/BIOS3_forcing/australia_0.05/Australia_op_maskv2ctr05.hdr',
            '/g/data/rp23/experiments/2024-04-17_BIOS3-merge/BIOS3_forcing/australia_0.05/Australia_op_maskv2ctr05.flt',
            'Australia_BIOS_0p05_resolution_landmask.nc'
            )
