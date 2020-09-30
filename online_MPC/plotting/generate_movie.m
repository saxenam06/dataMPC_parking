close all
clear all

% Plot and save movie

name = 'FP_StratOBCA_Exp4_2020-09-29_17-39';
fname = sprintf('../data/%s.mat', name);

plt_params.visible = 'on'; % or 'off' to shut down real time display
plt_params.plt_hyp = false;
plt_params.plt_ref = true;
plt_params.plt_sol = false;
plt_params.plt_preds = true;
plt_params.plt_tv_preds = true;
plt_params.plt_col_buf = false;
plt_params.mv_save = true;
plt_params.mv_name = name;

F = plotExp(fname, plt_params);