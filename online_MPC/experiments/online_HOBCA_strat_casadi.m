clear all
close all
clc

pathsetup();

%% Load testing data
% uiopen('load')
exp_num = 1;
exp_file = strcat('../../data/exp_num_', num2str(exp_num), '.mat');
load(exp_file)

%% Load strategy prediction model
model_name = 'nn_strategy_TF-trainscg_h-40_AC-tansig_ep2000_CE0.17453_2020-08-04_15-42';
model_file = strcat('../../models/', model_name, '.mat');
load(model_file)

% Console output saving
if ~isfolder('../data/')
    mkdir('../data')
end

time = datestr(now,'yyyy-mm-dd_HH-MM');
filename = sprintf('casadi_HppOBCA_Exp%d_%s', exp_num, time);
diary(sprintf('../data/%s.txt', filename))

%%
N = 20; % Prediction horizon
dt = EV.dt; % Time step
T = length(TV.t); % Length of data
v_ref = EV.ref_v; % Reference velocity
y_ref = EV.ref_y; % Reference y
r = sqrt(EV.width^2 + EV.length^2)/2; % Collision buffer radius

n_z = 4;
n_u = 2;

% Instantiate ego vehicle car dynamics
L_r = EV.L/2;
L_f = EV.L/2;
M = 10; % RK4 steps
EV_dynamics = bike_dynamics_rk4(L_r, L_f, dt, M);

% Instantiate obca controller
Q = diag([10 1 1 5]);
R = diag([1 1]);

% d_min = 0.01;
d_min = 0.001;
u_u = [0.5; 1.5];
u_l = [-0.5; -1.5];
du_u = [0.6; 5];
du_l = [-0.6; -5];

% n_obs = 1;
% n_ineq = [4];
n_obs = 3;
n_ineq = [4,1,1];
d_ineq = 2;

tv_obs = cell(n_obs, N+1);
lane_width = 8;
for i = 1:N+1
    tv_obs{2,i}.A = [0, -1];
    tv_obs{2,i}.b = -lane_width/2;
    tv_obs{3,i}.A = [0, 1];
    tv_obs{3,i}.b = -lane_width/2;
end

opt_params.name = 'casadi_opt_solver_strat';
opt_params.N = N;
opt_params.n_x = n_z;
opt_params.n_u = n_u;
opt_params.n_obs = n_obs;
opt_params.n_ineq = n_ineq;
opt_params.d_ineq = d_ineq;
opt_params.G = EV.G;
opt_params.g = EV.g;
opt_params.d_min = d_min;
opt_params.Q = Q;
opt_params.R = R;
opt_params.u_u = u_u;
opt_params.u_l = u_l;
opt_params.du_u = du_u;
opt_params.du_l = du_l;
opt_params.dynamics = EV_dynamics;
opt_params.dt = dt;

obca_controller = hpp_obca_controller_casadi(opt_params);

% Instantiate safety controller
d_lim = [u_l(1), u_u(1)];
a_lim = [u_l(2), u_u(2)];
safety_control = safety_controller(dt, d_lim, a_lim, du_u);
ebrake_control = ebrake_controller(dt, d_lim, a_lim);

% ==== Filter Setup
V = 0.01 * eye(3);
W = 0.5 * eye(3);
Pm = 0.2 * eye(3);
score = ones(3, 1) / 3;

% Make a copy of EV as the optimal EV, and naive EV
OEV = EV;

obca_mpc_safety = false;

% Data to save
z_traj = zeros(n_z, T-N+1);
z_traj(:,1) = EV.traj(:,1);
u_traj = zeros(n_u, T-N);

z_preds = zeros(n_z, N+1, T-N);
u_preds = zeros(n_u, N, T-N);
z_refs = zeros(n_z, N+1, T-N);

ws_stats = cell(T-N, 1);
sol_stats = cell(T-N, 1);

collide = zeros(T-N, 1);
safety = zeros(T-N, 1);
ebrake = zeros(T-N, 1);
scores = zeros(3, T-N);
strategy_idxs = zeros(T-N);
strategy_locks = zeros(T-N);
hyps = cell(T-N, 1);

exp_params.exp_num = exp_num;
exp_params.name = 'casadi Strategy OBCA MPC';
exp_params.T = T;
exp_params.lane_width = lane_width;
exp_params.model = model_name;
exp_params.controller.N = N;
exp_params.controller.Q = Q;
exp_params.controller.R = R;
exp_params.controller.d_min = d_min;
exp_params.controller.d_lim = d_lim;
exp_params.controller.a_lim = a_lim;
exp_params.dynamics.dt = dt;
exp_params.dynamics.M = M;
exp_params.dynamics.L_r = L_r;
exp_params.dynamics.L_f = L_f;
exp_params.dynamics.n_z = n_z;
exp_params.dynamics.n_u = n_u;
exp_params.filter.V = V;
exp_params.filter.W = W;
exp_params.filter.Pm = Pm;

ws_solve_times = zeros(T-N, 1);
opt_solve_times = zeros(T-N, 1);
total_times = zeros(T-N, 1);

strategy_lock = false;
for i = 1:T-N
    tic
    fprintf('\n=================== Iteration: %i ==================\n', i)
    
    % Get x, y, heading, and velocity from ego vehicle at current timestep
    EV_x  = z_traj(1,i);
    EV_y  = z_traj(2,i);
    EV_th = z_traj(3,i);
    EV_v  = z_traj(4,i);

    EV_curr = [EV_x; EV_y; EV_th; EV_v*cos(EV_th); EV_v*sin(EV_th)];
%     EV_curr = [EV_x; EV_y; 0; EV_v*cos(EV_th); EV_v*sin(EV_th)];
    
    % Get x, y, heading, and velocity from target vehicle over prediction
    % horizon
    TV_x = TV.x(i:i+N);
    TV_y = TV.y(i:i+N);
    TV_th = TV.heading(i:i+N);
    TV_v = TV.v(i:i+N);
    
    TV_pred = [TV_x, TV_y, TV_th, TV_v.*cos(TV_th), TV_v.*sin(TV_th)]';

    % Get target vehicle trajectory relative to ego vehicle state
    if ~obca_mpc_safety && EV_v*cos(EV_th) > 0
        rel_state = TV_pred - EV_curr;
    else
        tmp = [EV_x; EV_y; EV_th; 0; EV_v*sin(EV_th)];
        rel_state = TV_pred - tmp;
    end
    
    % Predict strategy to use based on relative prediction of target
    % vehicle
    X = reshape(rel_state, [], 1);
    score_z = net(X);

    % Filter
    [score, Pm] = score_KF(score, score_z, V, W, Pm);
    [~, max_idx] = max(score);
    
    % Generate reference trajectory
    yield = false;
%     if all( abs(rel_state(1, :)) > 10 )
    if all( abs(rel_state(1, :)) > 20 ) || rel_state(1,1) < -r
        % If it is still far away
        EV_x_ref = EV_x + [0:N]*dt*v_ref;
        EV_v_ref = v_ref*ones(1, N+1);
        obca_mpc_safety = false;
        if all( abs(rel_state(1, :)) > 20 )
            fprintf('Cars are far away, tracking nominal reference velocity\n')
        end
        if rel_state(1,1) < -r
            fprintf('EV has passed TV, tracking nominal reference velocity\n')
        end
    elseif max(score) > 0.55 && max_idx < 3 || strategy_lock
        % If strategy is not yield discount reference velocity based on max
        % likelihood
        % EV_x_ref = EV_x + [0:N]*dt*v_ref*max(score);
        EV_x_ref = EV_x + [0:N]*dt*v_ref;
        EV_v_ref = max(score)*v_ref*ones(1, N+1);
%         EV_v_ref = v_ref*ones(1, N+1);
        obca_mpc_safety = false;
        fprintf('Confidence: %g, threshold met, tracking score discounted reference velocity\n', max(score))
    else
        % If yield or not clear to left or right
        yield = true;
        EV_x_ref = EV_x + [0:N]*dt*v_ref;
        EV_v_ref = v_ref*ones(1, N+1);
        fprintf('Confidence: %g, threshold not met, setting yield to true\n', max(score))
    end
    
    EV_y_ref = zeros(1, length(EV_x_ref));
    EV_h_ref = zeros(1, length(EV_x_ref));
    z_ref = [EV_x_ref; EV_y_ref; EV_h_ref; EV_v_ref];
    
    % Check which points along the reference trajectory would result in
    % collision. Collision is defined as the reference point at step k 
    % being contained in O_TV(k) + B(r), where O_TV(k) is the region
    % occupied by the target vehicle at step k along the prediction horizon
    % and B(r) is the 2D ball with radius equal to the collision buffer
    % radius of the ego vehicle
    
    % ======= Use the ref traj to detect collision
    z_detect = z_ref; % Use the ref to construct hpp
    horizon_collision = [];
    for j = 1:N+1
        collision = check_collision(z_detect(1:2,j), TV_x(j), TV_y(j), TV_th(j), TV.width, TV.length, r);
        horizon_collision = [horizon_collision, collision];
    end

    % Lock the strategy if more than 3 steps are colliding
    if sum(horizon_collision) >= 3 && max(score) > 0.55 || strategy_lock
        strategy_idx = last_idx;
        strategy_lock = true;
    else
        strategy_idx = max_idx;
        last_idx = max_idx;
        strategy_lock = false;
    end
    
    % Generate hyperplane constraints
    hyp = cell(N+1,1);
    for j = 1:N+1
        ref = z_detect(1:2, j);
        collision = horizon_collision(j);
        if collision
            if strategy_idx == 1
                dir = [0; 1];
            elseif strategy_idx == 2
                dir = [0; -1];
            else
                dir = [EV_x-TV_x(j); EV_y-TV_y(j)];
                dir = dir/(norm(dir));
            end
            % ==== Unbiased Tight HPP
            [hyp_xy, hyp_w, hyp_b] = get_extreme_pt_hyp_tight(ref, dir, TV_x(j), TV_y(j), TV_th(j), ...
                TV.width, TV.length, r);
            % =====
            hyp{j}.w = [hyp_w; zeros(n_z-length(hyp_w),1)];
            hyp{j}.b = hyp_b;
            hyp{j}.pos = hyp_xy;
        else
            hyp{j}.w = zeros(n_z,1);
            hyp{j}.b = 0;
            hyp{j}.pos = nan;
        end
    end
    
    % Generate target vehicle obstacle descriptions
    tv_obs(1,:) = get_car_poly_obs(TV_pred, TV.width, TV.length);
    
    if ~obca_mpc_safety && yield
        % Compute the distance threshold for applying braking assuming max
        % decceleration is applied
        rel_vx = TV_v(1)*cos(TV_th(1)) - EV_v*cos(EV_th);
        min_ts = ceil(-rel_vx/abs(a_lim(1))/dt); % Number of timesteps requred for relative velocity to be zero
        v_brake = abs(rel_vx)+[0:min_ts]*dt*a_lim(1); % Velocity when applying max decceleration
%         brake_thresh = sum(abs(v_brake)*dt) + abs(TV_v(1)*cos(TV_th(1)))*(min_ts+1)*dt + 2*r; % Distance threshold for safety controller to be applied
        brake_thresh = sum(abs(v_brake)*dt) + 4*r;
        d = norm(TV_pred(1:2,1) - EV_curr(1:2), 2); % Distance between ego and target vehicles
        if  d <= brake_thresh
            % If distance between cars is within the braking threshold,
            % activate safety controller
            obca_mpc_safety = true;
            fprintf('EV is within braking distance threshold, activating safety controller\n')
        end
    end

    % HPP OBCA MPC
    % Initialize prediction guess for warm start
    if i == 1
        z_ws = z_ref;
        u_ws = zeros(n_u, N);
        u_prev = zeros(n_u, 1);
    else
        z_ws = [z_preds(:,2:end,i-1) EV_dynamics.f_dt(z_preds(:,end,i-1), u_preds(:,end,i-1))];
        u_ws = [u_preds(:,2:end,i-1) u_preds(:,end,i-1)];
        u_prev = u_traj(:,i-1);
    end
    
    obca_mpc_ebrake = false;
    status_sol = [];
    [status_ws, obca_controller] = obca_controller.solve_ws(z_ws, u_ws, tv_obs);
    if status_ws.success
        ws_solve_times(i) = status_ws.solve_time;
        [z_obca, u_obca, status_sol, obca_controller] = obca_controller.solve(z_traj(:,i), u_prev, z_ref, hyp);
    end

    if ~status_ws.success || ~status_sol.success
        if safety(i-1)
            obca_mpc_safety = true;
            fprintf('Strategy OBCA not feasible, maintaining the safety control\n')
        else
            % If OBCA MPC is infeasible, activate ebrake controller
            obca_mpc_ebrake = true;
            fprintf('Strategy OBCA not feasible, activating emergency brake\n')
        end
    else
        opt_solve_times(i) = status_sol.solve_time;
    end
    
    if obca_mpc_safety
        safety_control = safety_control.set_acc_ref(TV_v(1)*cos(TV_th(1)));
        [u_safe, safety_control] = safety_control.solve(z_traj(:,i), TV_pred, u_prev);
        % Assume safety control is applied for one time step then no
        % control action is applied for rest of horizon
        u_pred = [u_safe zeros(n_u, N-1)];
        z_pred = [z_traj(:,i) zeros(n_z, N)];
        % Simulate this policy
        for j = 1:N
            z_pred(:,j+1) = EV_dynamics.f_dt(z_pred(:,j), u_pred(:,j));
        end
        fprintf('Applying safety control\n')
    elseif obca_mpc_ebrake
        [u_ebrake, ebrake_control] = ebrake_control.solve(z_traj(:,i), TV_pred, EV.inputs(:,end));
        % Assume ebrake control is applied for one time step then no
        % control action is applied for rest of horizon
        u_pred = [u_ebrake zeros(n_u, N-1)];
        z_pred = [z_traj(:,i) zeros(n_z, N)];
        % Simulate this policy
        for j = 1:N
            z_pred(:,j+1) = EV_dynamics.f_dt(z_pred(:,j), u_pred(:,j));
        end
        fprintf('Applying ebrake control\n')
    else
        z_pred = z_obca;
        u_pred = u_obca;
    end
    
    % Simulate system forward using first predicted input
    z_traj(:,i+1) = EV_dynamics.f_dt(z_traj(:,i), u_pred(:,1));
    u_traj(:,i) = u_pred(:,1);

    total_times(i) = toc;
    
    % Save data
    z_preds(:,:,i) = z_pred;
    u_preds(:,:,i) = u_pred;
    
    z_refs(:,:,i) = z_ref;
    hyps{i} = hyp;
    
    % Check the collision at the current time step
    collide(i) = check_current_collision(z_traj(1:3, i), TV_pred(1:3, 1), EV);

    safety(i) = obca_mpc_safety;
    ebrake(i) = obca_mpc_ebrake;
    
    scores(:,i) = score;
    strategy_idxs(i) = strategy_idx;
    strategy_locks(i) = strategy_lock;
    
    ws_stats{i} = status_ws;
    sol_stats{i} = status_sol;
end

fprintf('\n=================== Complete ==================\n')
fprintf('Output log saved in: %s.txt, data saved in: %s.mat\n', filename, filename)

save(sprintf('../data/%s.mat', filename), 'exp_params', 'OEV', 'TV', ...
    'z_traj', 'u_traj', 'z_preds', 'u_preds', 'z_refs', 'ws_stats', 'sol_stats', ...
    'scores', 'strategy_idxs', 'strategy_locks', 'hyps', 'collide', 'safety', 'ebrake', ...
    'ws_solve_times', 'opt_solve_times', 'total_times')

diary off