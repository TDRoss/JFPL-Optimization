using Distributed
using ArgParse




function run_sensitivity(options = nothing)
    if isnothing(options) || isnothing(options["count"])
        println("How many simulations would you like to run? ")
        runs = readline()
    else
        runs = options[:runs]
    end
    if isnothing(options) || isnothing(options["processes"])
        println("How many processes you want to run in parallel? ")
        processes = readline()
    else
        processes = options[:processes]
    end

    runs = parse(Int,runs)
    processes = parse(Int, processes)
    all_jobs = [Dict("run_no" => string(i+1), "randomized" => true) for i in 1:runs]
    if length(workers()) > 1
        rmprocs(workers())
    end
    addprocs(processes)
    @everywhere include("solve_regular.jl")
    start_time = time()
    
    # Parallel execution
   @elapsed @sync @distributed for job in all_jobs
        solve_regular(job)
    end
    end_time = time()

    println("\nTotal time taken is ", (end_time - start_time) / 60, " minutes")
    if length(workers()) > 1
        rmprocs(workers())
    end    
    
end


if abspath(PROGRAM_FILE) == @__FILE__ 
    
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--no"
            arg_type = Int
            help = "Number of runs"
        "--parallel"
            arg_type = Int
            help = "Number of parallel runs"
    end
    parsed_args = parse_args(ARGS, s)
    options = Dict()
    options["count"] = parsed_args["no"]
    options["processes"] = parsed_args["parallel"]

    run_sensitivity(options)
end

