function Mobj = get_EHYPE_rivers(Mobj, dist_thresh)
% Extract river discharges from the supplied river positions for the FVCOM
% grid in Mobj.
%
% get_EHYPE_rivers(Mobj, dist_thresh)
%
% DESCRIPTION:
%   For the positioins in fvcom_xy, find the nearest unstructured grid node
%   and extract the river discharge from polcoms_flow. If dist_thresh is
%   specified, the river positions must fall within the specified distance.
%   If multiple rivers are assigned to the same node, their discharges are
%   summed. The resulting river name is generated from the contributing
%   rives, separated by a hyphen.
%
% INPUT:
%   Mobj - MATLAB mesh object containing:
%       * have_lonlat - boolean to check for spherical coordinates.
%       * lon, lat - positions for the unstructured grid.
%       * tri - triangulation table for the unstructured grid.
%       * nVerts - number of nodes in the grid.
%       * read_obc_nodes - open boundary node IDs.
%       * rivers - river data struct with the following fields:
%           - positions - river positions in lon, lat.
%           - names - list of river names
%   dist_thresh - [optional] maximum distance away from a river node beyond
%       which the search for an FVCOM node is abandoned. Units in degrees.
%
% OUTPUT:
%   Mobj.river_flux - volume flux at the nodes within the model domain.
%   Mobj.river_nodes - node IDs for the rivers. At the moment, these are
%       point sources only. Eventually, some rivers may have to be split
%       over several nodes.
%   Mobj.river_names - river names which fall within the model domain. For
%       rivers where the discharge has been summed, the name is compoud,
%       with each contributing name separated by a hyphen (-).
%   Mobj.river_time - time series for the river discharge data
%
% EXAMPLE USAGE:
%   Mobj = get_EHYPE_rivers(Mobj, 0.025)
%
% Author(s):
%   Pierre Cazenave (Plymouth Marine Laboratory)
%
% Revision history:
%   2013-10-15 - First version based on get_FVCOM_rivers.m.
%
%==========================================================================

subname = 'get_EHYPE_rivers';

global ftbverbose;
if ftbverbose
    fprintf(['\nbegin : ' subname '\n'])
end

% Check inputs
if ~Mobj.have_lonlat
    error('Require unstructured grid positions in lon/lat format to compare against supplied river positions.')
end

% Separate the inputs into separate arrays.
ehype_name = Mobj.rivers.names;
ehype_xy = Mobj.rivers.positions;
ehype_flow = Mobj.rivers.river_flux;

fv_nr = length(ehype_name);

% Check each location in the EHYPE positions against the grid in Mobj and
% for the indices within the dist_thresh, load and extract the relevant
% time series data.

vc = 0; % valid FVCOM boundary node counter

% We need to find the unstructured grid boundary nodes and exclude the open
% boundary nodes from them. This will be our list of potential candidates
% for the river nodes (i.e. the land coastline).
[~, ~, ~, bnd] = connectivity([Mobj.lon, Mobj.lat], Mobj.tri);
boundary_nodes = 1:Mobj.nVerts;
boundary_nodes = boundary_nodes(bnd);
coast_nodes = boundary_nodes(~ismember(boundary_nodes, [Mobj.read_obc_nodes{:}]));
tlon = Mobj.lon(coast_nodes);
tlat = Mobj.lat(coast_nodes);

fv_obc = nan;
fvcom_names = cell(0);
fv_riv_idx = nan;

for ff = 1:fv_nr
    % Find the open boundary node closest to this river.
    fv_dist = sqrt( ...
        (ehype_xy(ff, 1) - tlon).^2 + ...
        (ehype_xy(ff, 2) - tlat).^2);
    [c, idx] = min(fv_dist);
    if c > dist_thresh && dist_thresh ~= -1 % -1 is for no distance check
        if ftbverbose
            fprintf('\tskipping river %07d (%f, %f [%f])\n', ehype_name(ff), ehype_xy(ff, 1), ehype_xy(ff, 2), c)
        end
        continue
    else
        if ftbverbose
            fprintf('candidate river %07d found (%f, %f)... ', ehype_name(ff), ehype_xy(ff, 1), ehype_xy(ff, 2))
        end
    end

    vc = vc + 1;

    % We need to make sure the element in which this node occurs does not
    % have two land boundaries (otherwise the model sometimes just fills up
    % that element without releasing the water into the adjacent element).
    
    % Find the other nodes which are joined to the node we've just found.
    % We don't need the column to get the other nodes in the element, only
    % the row is required.
    [row, ~] = find(Mobj.tri == coast_nodes(idx));
    
    if length(row) == 1
        % This is a bad node because it is a part of only one element. The
        % rivers need two adjacent elements to work reliably (?). So, we
        % need to repeat the process above until we find a node that's
        % connected to two elements. We'll try the other nodes in the
        % current element before searching the rest of the coastline (which
        % is computationally expensive).
        
        % Remove the current node index from the list of candidates (i.e.
        % leave only the two other nodes in the element).
        mask = Mobj.tri(row, :) ~= coast_nodes(idx);
        n_tri = Mobj.tri(row, mask);
        
        % Remove values which aren't coastline values (we don't want to set
        % the river node to an open water node).
        n_tri = intersect(n_tri, coast_nodes);

        % Of the remaining nodes in the element, find the closest one to
        % the original river location (in fvcom_xy).
        [~, n_idx] = sort(sqrt( ...
            (ehype_xy(ff, 1) - Mobj.lon(n_tri)).^2 ...
            + (ehype_xy(ff, 2) - Mobj.lon(n_tri)).^2));

        [row_2, ~] = find(Mobj.tri == n_tri(n_idx(1)));
        if length(n_idx) > 1
            [row_3, ~] = find(Mobj.tri == n_tri(n_idx(2)));
        end
        % Closest first
        if length(row_2) > 1
            idx = find(coast_nodes == n_tri(n_idx(1)));
        % The other one (only if we have more than one node to consider).
        elseif length(n_idx) > 1 && length(row_3) > 1
            idx = find(coast_nodes == n_tri(n_idx(2)));
        % OK, we need to search across all the other coastline nodes.
        else
            % TODO: Implement a search of all the other coastline nodes.
            % My testing indicates that we never get here (at least for the
            % grids I've tested). I'd be interested to see the mesh which
            % does get here...
            continue
        end
        fprintf('alternate node ')
    end

    % Add it to the list of valid rivers
    fv_obc(vc) = coast_nodes(idx);

    % We are assuming that the river discharge data array y-dimension is
    % ordered the same as the positions in fvcom_xy. If they are not, then
    % the discharges for the rivers will be incorrect (i.e. you might put
    % the Severn discharge somewhere in the Baltic).
    fvcom_names{vc} = sprintf('%07d', ehype_name(ff));
    fv_riv_idx(vc) = ff;
    fid = fopen(fullfile(ehype_flow, [fvcom_names{vc}, '.txt']));
    assert(fid >= 0, 'Failed to open EHYPE river flow data.')
    eflow = textscan(fid, '%s %f %f %f %f %f %f %f %f %f', 'delimiter', '\t', 'HeaderLines', 2, 'MultipleDelimsAsOne', 1);
    fclose(fid);
%     fv_flow(:, vc) = ehype_flow(:, ff);
    if ftbverbose
        fprintf('added (%f, %f).\n', Mobj.lon(fv_obc(vc)), Mobj.lat(fv_obc(vc)))
    end
end

% Now we've got a list and some of the nodes will be duplicates. Sum the
% discharge values assigned to those nodes.
fv_uniq_obc = unique(fv_obc);

fv_uniq_flow = nan(pc_nt, length(fv_uniq_obc));
fv_uniq_names = cell(length(fv_uniq_obc), 1);

fv_idx = 1:length(fvcom_names);
for nn = 1:length(fv_uniq_obc)
    
    dn = fv_idx(fv_obc == fv_uniq_obc(nn));
    
    fv_uniq_flow(:, nn) = sum(fv_flow(:, dn), 2);
    % Concatenate the river names so we know at least which rivers'
    % discharges have been summed.
    s = fvcom_names(dn);
    s = [sprintf('%s-', s{1:end-1}, s{end})];
    fv_uniq_names{nn} = s(1:end-1); % lose the trailing -.

end

% Assign the relevant arrays to the Mobj.
Mobj.river_nodes = fv_uniq_obc;
Mobj.river_flux = fv_uniq_flow;
Mobj.river_names = fv_uniq_names;

% Create a Modified Julian Day time series starting at January 1st for the
% year in Mobj.rivers.year.
rtimes = datevec( ...
    datenum([Mobj.rivers.year, 1, 1, 0, 0, 0]): ...
    datenum([Mobj.rivers.year, 1, 1, 0, 0, 0]) + pc_nt - 1 ...
    );
Mobj.river_time = nan(pc_nt, 1);
for tt = 1:pc_nt
    Mobj.river_time(tt) = greg2mjulian( ...
        rtimes(tt, 1), rtimes(tt, 2), rtimes(tt, 3), ...
        rtimes(tt, 4), rtimes(tt, 5), rtimes(tt, 6) ...
        );
end

if ftbverbose
    fprintf('end   : %s \n', subname)
end

% Figure to check what's going on with identifying river nodes
% figure
% plot(fvcom_xy(:, 1), fvcom_xy(:, 2), 'o', 'MarkerFaceColor', 'b')
% hold on
% plot(Mobj.lon(bnd), Mobj.lat(bnd), 'go', 'MarkerFaceColor', 'g')
% axis('equal', 'tight')
% plot(Mobj.lon(coast_nodes), Mobj.lat(coast_nodes), 'ro')
% plot(Mobj.lon(Mobj.river_nodes), Mobj.lat(Mobj.river_nodes), 'ko', 'MarkerFaceColor', 'k')
% text(Mobj.lon(Mobj.river_nodes) + 0.025, Mobj.lat(Mobj.river_nodes) + 0.025, Mobj.river_names)
% axis([min(Mobj.lon), max(Mobj.lon), min(Mobj.lat), max(Mobj.lat)])
% legend('POLCOMS nodes', 'Grid boundary', 'Land nodes', 'Selected nodes', 'Location', 'NorthOutside', 'Orientation', 'Horizontal')
% legend('BoxOff')