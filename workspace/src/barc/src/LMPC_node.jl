#!/usr/bin/env julia

using RobotOS
@rosimport barc.msg: ECU, pos_info, Encoder, Ultrasound, Z_KinBkMdl, Logging
@rosimport data_service.msg: TimeData
@rosimport geometry_msgs.msg: Vector3
rostypegen()
using barc.msg
using data_service.msg
using geometry_msgs.msg
using JuMP
using Ipopt
using JLD

include("LMC_lib/classes.jl")
include("LMC_lib/coeffConstraintCost.jl")
include("LMC_lib/solveMpcProblem.jl")
include("LMC_lib/functions.jl")

function SE_callback(msg::pos_info,s_start_update::Array{Float64},coeffCurvature_update::Array{Float64,1},z_est::Array{Float64,1},x_est::Array{Float64,1},
                        coeffX::Array{Float64,1},coeffY::Array{Float64,1})         # update current position and track data
    # update mpc initial condition
    z_est[:]                  = [msg.s,msg.ey,msg.epsi,msg.v]     # use z_est as pointer
    s_start_update[1]         = msg.s_start
    coeffCurvature_update[:]  = msg.coeffCurvature
    x_est[:]                  = [msg.x,msg.y,msg.psi,msg.v]
    coeffX[:]                 = msg.coeffX
    coeffY[:]                 = msg.coeffY
end

function main()
    println("now starting the node")

    buffersize                  = 1000       # size of oldTraj buffers

    # Create data to be saved
    log_oldTraj = zeros(buffersize,4,2,20)  # max. 10 laps
    log_t       = zeros(10000,1)
    log_state   = zeros(10000,4)
    log_pred_z  = zeros(10000,4)
    log_cost    = zeros(10000,6)

    # Define and initialize variables
    oldTraj                     = OldTrajectory()
    posInfo                     = PosInfo()
    mpcCoeff                    = MpcCoeff()
    lapStatus                   = LapStatus(1,1)
    mpcSol                      = MpcSol()
    trackCoeff                  = TrackCoeff()      # info about track (at current position, approximated)
    modelParams                 = ModelParams()
    mpcParams                   = MpcParams()

    z_est                       = zeros(4)
    x_est                       = zeros(4)
    coeffX                      = zeros(9)
    coeffY                      = zeros(9)
    s_start_update              = [0.0]
    cmd                         = ECU(0.0,0.0)

    InitializeParameters(mpcParams,trackCoeff,modelParams,posInfo,oldTraj,mpcCoeff,lapStatus,buffersize)

    log_coeff_Cost  = zeros(mpcCoeff.order+1,2,10000)
    log_coeff_Const = zeros(mpcCoeff.order+1,2,3,10000)
    log_sol_z       = zeros(mpcParams.N+1,4,10000)
    log_sol_u       = zeros(mpcParams.N,2,10000)

    coeffCurvature_update       = zeros(trackCoeff.nPolyCurvature+1)
    log_curv                    = zeros(10000,trackCoeff.nPolyCurvature+1)
    log_s_start                 = zeros(10000)
    log_state_x                 = zeros(10000,4)
    log_coeffX                  = zeros(10000,9)
    log_coeffY                  = zeros(10000,9)
    # Initialize ROS node and topics
    init_node("mpc_traj")
    loop_rate = Rate(10)
    pub                         = Publisher("ecu", ECU, queue_size=10)
    pub2                        = Publisher("logging", Logging, queue_size=10)
    # The subscriber passes 3 arguments (s_start, coeffCurvature and z_est) which are updated by the callback function:
    s1                          = Subscriber("pos_info", pos_info, SE_callback, (s_start_update,coeffCurvature_update,z_est,x_est,coeffX,coeffY,),queue_size=10)

    println("Finished initialization.")
    # Lap parameters
    switchLap                   = false     # initialize lap lap trigger
    s_lapTrigger                = 0.3       # next lap is triggered in the interval s_start in [0,s_lapTrigger]
    
    # buffer in current lap
    zCurr                       = zeros(10000,4)    # contains state information in current Lap (max. 10'000 steps)
    uCurr                       = zeros(10000,2)    # contains input information

    zCurr_export                = zeros(buffersize,4)
    uCurr_export                = zeros(buffersize,2)

    
    # DEFINE MODEL ***************************************************************************
    # ****************************************************************************************
    println("Building model...")

    z_Init          = zeros(4)

    mdl             = MpcModel()
    InitializeModel(mdl,mpcParams,modelParams,trackCoeff,z_Init)

    # Initial solve:
    println("Initial solve...")
    solve(mdl.mdl)
    solve(mdl.mdl)
    println("Finished.")

    pred_z = zeros(4)

    k = 0

    # Precompile functions
    coeffConstraintCost(oldTraj,mpcCoeff,posInfo,mpcParams)
    extendOldTraj(oldTraj,posInfo,zCurr)
    lapStatus.currentIt = 100
    saveOldTraj(oldTraj,zCurr,uCurr,lapStatus,buffersize,modelParams.dt)
    lapStatus.currentIt = 0
    mpcCoeff.coeffCost  = zeros(mpcCoeff.order+1,2)         # ... and set them back to zeros
    mpcCoeff.coeffConst = zeros(mpcCoeff.order+1,2,3)
    println("Finished precompiling.")

    # Start node
    while ! is_shutdown()
        if z_est[1] > 0         # check if data has been received (s > 0)

            # publish command from last calculation
            cmd.motor = mpcSol.a_x
            cmd.servo = mpcSol.d_f
            publish(pub, cmd)        

            # ============================= Initialize iteration parameters =============================
            lapStatus.currentIt += 1                            # count iteration

            i                   = lapStatus.currentIt           # current iteration number, just to make notation shorter
            zCurr[i,:]          = z_est                         # update state information: s, e_y, e_psi, v (actually predicted by Kalman filter!)
            posInfo.s           = z_est[1]                      # update position info
            posInfo.s_start     = s_start_update[1]
            trackCoeff.coeffCurvature = coeffCurvature_update

            # ======================================= Lap trigger =======================================
            # This part takes pretty long (about 0.6 seconds on my Mac) and should be faster!
            if (posInfo.s_start + posInfo.s)%posInfo.s_target <= s_lapTrigger && switchLap      # if we are switching to the next lap...
                # ... then select and save data
                println("Saving data")
                tic()
                saveOldTraj(oldTraj,zCurr,uCurr,lapStatus,buffersize,modelParams.dt)
                log_oldTraj[:,:,:,lapStatus.currentLap] = oldTraj.oldTraj[:,:,:]
                zCurr[1,:] = zCurr[i,:]         # reset counter to 1 and set current state
                uCurr[1,:] = uCurr[i+1,:]       # ... and input
                i                     = 1       
                lapStatus.currentLap += 1       # start next lap
                lapStatus.currentIt   = 1       # reset current iteration
                switchLap = false

                tt = toq()
                println("Saved data, t = $tt")
                println("======================================== NEXT LAP ========================================")
                println("cost: $(oldTraj.oldCost)")
                println("oldTraj.oldTraj[:,1,1]:")
                println(oldTraj.oldTraj[:,1,1])
                println("oldTraj.oldTraj[:,1,2]:")
                println(oldTraj.oldTraj[:,1,2])
            elseif (posInfo.s_start+posInfo.s)%posInfo.s_target > s_lapTrigger
                switchLap = true
            end

            # if we are at least in the 2nd lap, concatenate the beginning to the end of the previous track
            if lapStatus.currentLap > 1 && lapStatus.currentIt == 80
                extendOldTraj(oldTraj,posInfo,zCurr)
            end

            #  ======================================= Calculate input =======================================
            println("======================================== NEW ITERATION # $i ========================================")
            println("Current Lap: $(lapStatus.currentLap), It: $(lapStatus.currentIt)")
            println("State Nr. $i    = $z_est")
            println("Coeff Curvature = $(trackCoeff.coeffCurvature)")
            println("s               = $(posInfo.s)")
            println("s_start         = $(posInfo.s_start)")
            println("s_total         = $((posInfo.s+posInfo.s_start)%posInfo.s_target)")

            # Find coefficients for cost and constraints

            if lapStatus.currentLap > 1
                tic()
                coeffConstraintCost(oldTraj,mpcCoeff,posInfo,mpcParams)
                tt = toq()
                println("Finished coefficients, t = $tt s")
            end

            # Solve the MPC problem
            tic()
            solveMpcProblem(mdl,mpcSol,mpcCoeff,mpcParams,trackCoeff,lapStatus,posInfo,modelParams,zCurr[i,:]',uCurr[i,:]')
            #solveMpcProblem(mdl,mpcSol,mpcCoeff,mpcParams,trackCoeff,lapStatus,posInfo,modelParams,pred_z,uCurr[i,:]')

            tt = toq()
            # Write in current input information
            uCurr[i+1,:]  = [mpcSol.a_x mpcSol.d_f]
            println("Finished solving, status: $(mpcSol.solverStatus), u = $(uCurr[i+1,:]), t = $tt s")

            zCurr[i,1] = (posInfo.s_start + posInfo.s)%posInfo.s_target   # save absolute position in s (for oldTrajectory)
            println("\n")
            #println("Starting logging")
            
            # Logging
            k = k + 1       # counter
            log_state[k,:]          = z_est
            log_t[k]                = time()
            log_sol_z[:,:,k]        = mpcSol.z
            log_sol_u[:,:,k]        = mpcSol.u
            log_coeff_Cost[:,:,k]   = mpcCoeff.coeffCost
            log_coeff_Const[:,:,:,k] = mpcCoeff.coeffConst
            log_cost[k,:]           = mpcSol.cost
            log_curv[k,:]           = trackCoeff.coeffCurvature
            log_s_start[k]          = posInfo.s_start
            log_pred_z[k,:]         = pred_z
            log_state_x[k,:]        = x_est
            #log_coeffX[k,:]         = coeffX
            #log_coeffY[k,:]         = coeffY
            #println("Finished logging")

            # publish command from last calculation
            #cmd.motor = mpcSol.a_x
            #cmd.servo = mpcSol.d_f
            #publish(pub, cmd) 
            #println("z_pred = $(pred_z')")
        else
            println("No estimation data received!")
        end
        rossleep(loop_rate)
    end
    # Save simulation data to file

    log_path = "$(homedir())/simulations/output_LMPC.jld"
    save(log_path,"oldTraj",log_oldTraj,"state",log_state[1:k,:],"t",log_t[1:k],"sol_z",log_sol_z[:,:,1:k],"sol_u",log_sol_u[:,:,1:k],
                    "cost",log_cost[1:k,:],"curv",log_curv[1:k,:],"coeffCost",log_coeff_Cost,"coeffConst",log_coeff_Const,
                    "s_start",log_s_start[1:k],"pred_z",log_pred_z[1:k,:],"x_est",log_state_x[1:k,:],"coeffX",log_coeffX[1:k,:],"coeffY",log_coeffY[1:k,:])
    println("Exiting LMPC node. Saved data.")

end

if ! isinteractive()
    main()
end
