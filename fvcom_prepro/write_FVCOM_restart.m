function write_FVCOM_restart(fv_restart, out_restart, data)
% Duplicate an FVCOM restart file, replacing variable values with those
% specified in the struct data. 
% 
% function write_FVCOM_restart(fv_restart, out_restart, data)
% 
% DESCRIPTION:
%   Use an existing FVCOM restart file as a template, export all existing
%   data except for variables whose names match the data in the struct
%   'data'. 
% 
% INPUT:
%   fv_restart  = full path to an existing FVCOM restart file.
%   out_restart = full path to the restart file to be created.
%   data        = struct whose field names are the variable names to be
%   replaced.
% 
% OUTPUT:
%   FVCOM restart file.
% 
% EXAMPLE USAGE:
%   data.temp = interpolated_temp;
%   data.salinity = interpolated_salinity;
%   write_FVCOM_restart('/tmp/fvcom_restart.nc', data)
% 
% Author(s):
%   Pierre Cazenave (Plymouth Marine Laboratory)
% 
% Revision history:
%   2013-02-08 First version.
% 
%==========================================================================

subname = 'write_FVCOM_tsobc';

global ftbverbose
if ftbverbose
    fprintf('\n')
    fprintf(['begin : ' subname '\n'])
end

% Get the fieldnames which must match the variable names to be replaced
% (case sensitive).
fnames = fieldnames(data);
nf = length(fnames);

nc = netcdf.open(fv_restart, 'NOWRITE');
ncout = netcdf.create(out_restart, 'clobber');

[numdims, numvars, numglobatts, unlimdimID] = netcdf.inq(nc);

% Define the dimensions for all variables.
dimid = nan(numdims, 1);
dimnames = cell(numdims, 1);
dimlengths = nan(numdims, 1);
for ii = 1:numdims
    [dimname, dimlen] = netcdf.inqDim(nc, ii - 1);
    if ii ~= unlimdimID + 1 % NetCDF indices start at zero
        dimid(ii) = netcdf.defDim(ncout, dimname, dimlen);
    else
        dimid(ii) = netcdf.defDim(ncout, dimname, netcdf.getConstant('NC_UNLIMITED'));
    end
    dimnames{ii} = dimname;
    dimlengths(ii) = dimlen;
end

% Now define the variables and attributes.
for ii = 1:numvars

    % Find name of the current variable.
    [varname, xtype, varDimIDs, varAtts] = netcdf.inqVar(nc, ii - 1);

    % Create the variables.
    varid = netcdf.defVar(ncout, varname, xtype, varDimIDs);

    % Get each attribute and add it to the current variable.
    for j = 1:varAtts

        attname = netcdf.inqAttName(nc, varid, j - 1);
        attval = netcdf.getAtt(nc, varid, attname);

        netcdf.putAtt(ncout, varid, attname, attval);
    end
end

% Do the global attributes
for ii = 1:numglobatts
    
    % Find the current global attribute's name and value.
    gattname = netcdf.inqAttName(nc, netcdf.getConstant('NC_GLOBAL'), ii - 1);
    gattval = netcdf.getAtt(nc, netcdf.getConstant('NC_GLOBAL'), gattname);
    
    % Put that back into the output NetCDF file.
    netcdf.putAtt(ncout, netcdf.getConstant('NC_GLOBAL'), gattname, gattval);
end

netcdf.endDef(ncout);

% Get the existing data and output to the new NetCDF file, except for
% variables which match the fieldnames in the data struct.
for ii = 1:numvars

    [varname, ~, varDimIDs, ~] = netcdf.inqVar(nc, ii - 1);
    varid = netcdf.inqVarID(nc, varname);

    if ftbverbose
        fprintf('\tvariable %s... ', varname)
    end

    % We need the data irrespective of whether we're replacing it or not,
    % so grab it outside the if statement below.
    data = netcdf.getVar(nc, varid);

    % Get the size of the data and the dimension names.
    currDimsNames = dimnames(varDimIDs + 1);
    currDimsLengths = dimlengths(varDimIDs + 1);

    % Find whether we've got an unlimited dimension in this data.
    wasUnlimited = -1;
    for jj = varDimIDs
        if numel(unlimdimID) > 1
            error('Do not currently support multiple unlimited dimensions.')
        end
        if strcmpi(dimnames(jj + 1), dimnames(unlimdimID + 1))
            wasUnlimited = jj;
        end
    end

    % Since the restart file has a number of time values, we'll ramp up the
    % replacement data from the existing start condition to the actual
    % value over the time steps. So, we need to know how many time steps we
    % actually have.

    % Get the dimension data ready for the replacement arrays.
    tIdx = strncmp(dimnames(unlimdimID + 1), currDimsNames, length(dimnames{unlimdimID + 1}));
    % Not sure about the hardcoded strings below...
    sIdx = strncmp('siglay', currDimsNames, length(dimnames{unlimdimID + 1}));
    nIdx = strncmp('node', currDimsNames, length(dimnames{unlimdimID + 1}));
    nt = currDimsLengths(tIdx);
    ns = currDimsLengths(sIdx);
    nd = currDimsLengths(nIdx);
    
    % Iterate through the field names to see if we're on one of the
    % variables to be replaced.
    for vv = 1:nf
        if strcmp(varname, fnames{vv})
            % To make the scaling go from the initial value to the POLCOMS
            % value, we need to take the scale the difference between the end
            % members by the scaling factor at each time and add to the current
            % time's value.
            sfvdata = nan(nd, ns, nt);
            ss = 0:1 / (nt - 1):1; % scale from 0 to 1.
            startdata = squeeze(data(:, :, 1)); % use the first modelled time step
            for tt = 1:nt;
                if tt == 1
                    sfvdata(:, :, 1) = startdata;
                else
                    td = data.(fnames{vv}) - startdata;
                    sfvdata(:, :, tt) = startdata + (ss(tt) .* td);
                end
            end
            % Replace the values with the scaled interpolated values.
            netcdf.putVar(ncout, varid, sfvdata)
        else
            % We need to check if the dimension is unlimited, and use a start
            % and end with netcdf.putVar if it is. This is largely because
            % MATLAB can't handle unlimited dimensions in the same way as it
            % does finite dimensions.
            if wasUnlimited < 0
                % We can just dump the entire data without specifying over what
                % indices.
                netcdf.putVar(ncout, varid, data);
            else
                % Use the dimension length we extracted above to output the
                % data with the valid unlimited dimension format.
                netcdf.putVar(ncout, varid, zeros(length(currDimsLengths), 1), currDimsLengths, data);
            end
        end
    end

    if ftbverbose
        fprintf('done.\n')
    end
end

netcdf.close(nc)
netcdf.close(ncout)

if ftbverbose
    fprintf(['end   : ' subname '\n'])
end
