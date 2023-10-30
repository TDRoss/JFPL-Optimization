using Distributed
using ArgParse
include("solve_regular.jl")


function run_sensitivity(options = nothing)
    if isnothing(options["count"])
        println("How many simulations would you like to run? ")
        runs = readline()
    else
        runs = options[:runs]
    end
    if isnothing(options["processes"])
        println("How many processes you want to run in parallel? ")
        processes = readline()
    else
        processes = options[:processes]
    end

    runs = parse(Int,runs)
    processes = parse(Int, processes)
    all_jobs = [Dict("run_no" => string(i+1), "randomized" => true) for i in 1:runs]

    # addprocs(processes)

    start_time = time()
    # Parallel execution
    # results = @distributed (vcat) for job in all_jobs
    solve_regular(all_jobs[1])
    # end
    end_time = time()

    println("\nTotal time taken is ", (end_time - start_time) / 60, " minutes")
        
    #     # for i in 1:runs
    #     # x = zeros(10)
    #     @sync for i in 1:runs
    #         @async begin
    # # Parallel execution
    # results = @distributed (vcat) for job in all_jobs
    #     solve_regular(job)
    # end
    #         end
    
    
end


function main()
    options = nothing

    try
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
        if haskey(parsed_args, "no")
            options["count"] = parsed_args["no"]
        end
        if haskey(parsed_args, "parallel")
            options["processes"] = parsed_args["parallel"]
        end
    catch
        # Just handle the error and proceed
    end

    run_sensitivity(options)
end

main()

