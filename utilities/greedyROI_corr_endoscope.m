function [Ain, Cin,  bin, fin, center, res] = greedyROI_corr_endoscope(Y, K, options, sn, debug_on, save_avi)
%% a greedy method for detecting ROIs and initializing CNMF. in each iteration,
% it searches the one with large (peak-median)/noise level and large local
% correlation. It's the same with greedyROI_corr.m, but with some features
% specialized for endoscope data
%% Input:
%   Y:  d X T matrx, imaging data
%   K:  scalar, maximum number of neurons to be detected.
%   options: struct data of paramters/options
%       d1:     number of rows
%       d2:     number of columns
%       gSiz:   maximum size of a neuron
%       nb:     number of background
%       min_corr: minimum threshold of correlation for segementing neurons
%   sn:     d X 1 vector, noise level of each pixel
%   debug_on: options for showing procedure of detecting neurons
%   save_avi: save the video of initialization procedure

%% Output:
%       Ain:  d X K' matrix, estimated spatial component
%       Cin:  K'X T matrix, estimated temporal component
%       bin:  d X nb matrix/vector, spatial components of the background
%       Cin:  nb X T matrix/vector, temporal components of the background
%       center: K' X 2, coordinate of each neuron's center
%       res:  d X T, residual after initializing Ain, Cin, bin, fin

%% Author: Pengcheng Zhou, Carnegie Mellon University.
% the method is an modification of greedyROI method used in Neuron paper of Eftychios
% Pnevmatikakis et.al. https://github.com/epnev/ca_source_extraction/blob/master/utilities/greedyROI2d.m
%% In each iteration of peeling off neurons, it searchs the one with maximum
% value of (max-median)/noise * Cn, which achieves a balance of SNR and
% local correlation.


%% use correlation to initialize NMF
%% parameters
if exist('sn', 'var')
    Y_std = sn;
else
    Y_std = std(Y, 0, ndims(Y));
end
Y_std = Y_std(:);
if ~exist('debug_on', 'var'); debug_on = false; end
if ~exist('save_avi', 'var'); save_avi = false; end

d1 = options.d1;
d2 = options.d2;
gSig = options.gSig;
gSiz = options.gSiz;
nb = options.nb; 
pSiz = 1;
bSiz = options.bSiz; 
psf = ones(gSig)/(gSig^2);
min_corr = options.min_corr;
nhood = strel('disk', bSiz);    % matrix describing neighbours.
% maxIter = 5;
sz = [1, 2];            %distance of neighbouring pixels for computing local correlation

if ~ismatrix(Y); Y = reshape(Y, d1*d2, []); end;
[~, T] = size(Y);       % number of frames
Ain = zeros(d1*d2, K);  % spatial components
Cin = zeros(K, T);      % temporal components
center = zeros(K, 2);   % center of the initialized components

%% compute correlation image and (max-median)/std ratio
ind_frame = round(linspace(1, T, min(T, 1000)));
C1 = correlation_image(full(Y(:, ind_frame)), sz, d1, d2);
Cb =  correlation_image(full(Y(:, ind_frame(1:3:end))), [gSiz, gSiz+1], d1, d2);
Cn = C1-Cb;
Y_median = median(Y(:, ind_frame), 2);
Y = bsxfun(@minus, Y, Y_median);
% Y_std = sqrt(mean(Y.*Y, 2));

%% find local maximum
k = 0;      %number of found components
min_pixel = 4; %(2*pSiz+1)^2; % minimum number of pixels to be a neuron
peak_ratio = full(max(Y, [], 2))./Y_std; %(max-median)/std
peak_ratio = reshape(peak_ratio, d1, d2); 
peak_ratio(isinf(peak_ratio)) = 0;  % avoid the case where std=0
peak_ratio(1:gSig, :) = 0; 
peak_ratio((end-gSig+1):end, :) = 0; 
peak_ratio(:, 1:gSig) = 0; 
peak_ratio(:, (end-gSig+1):end) = 0; 
peak_ratio = reshape(peak_ratio, [],1); 
if debug_on
    figure('position', [100, 100, 800, 650]); %#ok<*UNRCH>
    subplot(331);
    imagesc(Cn, [0,1]); colorbar;
    axis equal off tight; hold on;
    title('correlation image');
    if save_avi
        avi_file = VideoWriter('greedyROI_example.avi', 'FPS', 10);
        avi_file.open();
    end
end

while k<K
    %% find the pixel with the maximum ratio
    [max_v, ind_p] = max(peak_ratio.*(Cn(:)));
    
    peak_ratio(ind_p) = 0;    % no longer visit this pixel any more
    if  max_v< 3*min_corr;     break; end  % peak_ratio*local correlation, too small
    if Cn(ind_p)<min_corr; continue; end % ignore this local maximum due to small local correlation
    [r, c] = ind2sub([d1,d2], ind_p);
    
    % select its neighbours for computing correlation
    rsub = max(1, -gSiz+r):min(d1, gSiz+r);
    csub = max(1, -gSiz+c):min(d2, gSiz+c);
    [cind, rind] = meshgrid(csub, rsub);
    nr = length(rsub);  %size of the neighboring matrix
    nc = length(csub);
    ind_nhood = sub2ind([d1, d2], rind(:), cind(:));
    Y_box = Y(ind_nhood, :);
    
    % draw a small area near the peak and extract the mean activities
    r0 = rsub(1); c0 = csub(1);
    rsub = (max(1, -pSiz+r):min(d1, pSiz+r)) - r0+1;
    csub = (max(1, -pSiz+c):min(d2, pSiz+c)) -c0+1;
    [cind, rind] = meshgrid(csub, rsub);
    ind_peak = sub2ind([nr, nc], rind(:), cind(:));
    y0 = mean(Y_box(ind_peak, :), 1);
    y0(y0<0) = 0;
    
    % compute the correlation between the peak and its neighbours
    temp = reshape(corr(y0', Y_box'), nr, nc);
    active_pixel = full(temp>min_corr);
    l = bwlabel(active_pixel, 8);
    active_pixel(l~=mode(l(ind_peak))) = false;
    tmp_v = sum(active_pixel(:));    %number of pixels with above-threshold correlation
    if debug_on
        subplot(332); cla;
        imagesc(reshape(peak_ratio.*Cn(:), d1, d2), [0, max_v]); colorbar;
        title(sprintf('neuron %d', k+1));
        axis equal off tight; hold on;
        plot(c,r, 'om');
        subplot(333);
        imagesc(temp, [min_corr, 1]);
        axis equal off tight;
        title('corr. with neighbours');
        subplot(3,3,4:6); cla;
        plot(y0); title('activity in the center');
        subplot(3,3,7:9); cla;
        if ~save_avi; pause; end
    end
    if tmp_v<min_pixel;         continue;  end
    
    %% save neuron
    %  expand nonzero area
    active_pixel = imdilate(full(active_pixel), nhood);
    ind_active = ind_nhood(active_pixel(:));
    data = Y_box(active_pixel(:), :);
    peak_ratio(ind_nhood(temp>0.8)) = 0;
    
    % do a rank-1 matrix factorization in this small area
    %         [ai, ci] = finetune2d(data, y0, maxIter);
    data(data<0) = 0;
    ci = y0;  % keep the temporal component as the temporal trace in the peak
    ai = max(0, (data*y0')/(y0*y0'));
    if norm(ai)==0;        continue;   end
    k = k+1;
    Ain(ind_active, k) = ai;
    Cin(k, :) = ci;
    Y(ind_active, :) = data-ai*ci;
    center(k, :) = [r, c];
    
    if debug_on
        subplot(331);
        plot(c, r, '.r');
        subplot(332);
        plot(c,r, 'or');
        subplot(333);
        temp = zeros(nr, nc); temp(active_pixel) = ai;
        imagesc(temp);
        axis equal off tight;
        title('spatial component');
        subplot(3,3,7:9); cla;
        plot(ci); title('temporal component');
        if save_avi; avi_file.writeVideo(getframe(gcf)); else pause; end
    end
    
    if mod(k, 10)==0
        fprintf('%d/%d neurons have been detected\n', k, K);
    end
    
    if k==K;   break; end
    
    %% udpate peak_ratio and correlation image
    tmp_old = peak_ratio(ind_active);
    tmp_new = max(Y(ind_active, :), [], 2)./Y_std(ind_active);
    temp = zeros(nr, nc);
    temp(active_pixel) = max(0, tmp_old-tmp_new); % after each iteration, the peak ratio can not be increased
    peak_ratio(ind_nhood) = max(0, peak_ratio(ind_nhood) - reshape(imfilter(temp, psf), [], 1));
    Cn(ind_nhood) = correlation_image(full(Y(ind_nhood, ind_frame)), sz, nr, nc)-reshape(Cb(ind_nhood), nr, nc);
end

center = center(1:k, :);
Ain = sparse(Ain(:, 1:k));
Cin = Cin(1:k, :);
Cin(Cin<0) = 0;
if save_avi; avi_file.close(); end
res = bsxfun(@plus, Y, Y_median);
bin = zeros(d1*d2, nb);
fin = zeros(nb, T);

%% endoscope data doesn't need initialization of the background
% tsub = max(1, round(T/1000));
% [bin, f] = nnmf(max(res(:, 1:tsub:T), 0), nb);
% fin = imresize(f, [nb, T]);
% fin = HALS_temporal(max(res, 0), bin, fin, maxIter);
% bin = HALS_spatial(max(res, 0), bin, fin, [], maxIter);
end

function [ai, ci] = finetune2d(data, ci, nIter)
%do matrix factorization given the model data = ai*ci, where ai>=0
%
%Input:
%   data:   d x T matrix, small patch containing one neuron
%   ci:     initial value for trace
%   nIter  number of coordinate descent steps
%
%Output:
%   ai  M x N matrix, result of the fine-tuned neuron shape
%   ci  1 x T matrix, result of the neuron
if ~exist('nIter', 'var'), nIter = 1; end
data(data<0)= 0;
%do block coordinate descent
for iter = 1:nIter,
    %update basis
    ai = max(0, (data*ci')/(ci*ci'));
    norm_ai = norm(ai, 2);
    if norm_ai==0; break;     end
    ai = ai/norm_ai;
    ci =  (ai'*data);
    %     ci(ci<0) = 0;
end
temp = (median(ci)-2*std(ci));
ci(ci<temp) = temp;
end