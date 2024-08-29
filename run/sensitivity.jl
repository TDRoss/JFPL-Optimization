using CSV, DataFrames, ArgParse, Glob, Statistics, PrettyTables

function read_sensitivity(options)
    directory = "../data/results/"

    if isnothing(options["gw"])
        print("What GW are you assessing? ")
        gw = parse(Int, readline())
        print("Is this a wildcard or preseason (GW1) solve? (y/n) ")
        situation = readline()
    else
        gw = options["gw"]
        situation = get(options, "situation", "n")
    end

    println()

    if situation in ["N", "n"]
        buys = []
        sells = []
        move = []
        no_plans = 0
        
        for filename in glob("*.csv", directory)
            plan = CSV.read(filename, DataFrame)
            iter = 0
            try
                iter = plan[1, :iter]
            catch

            end
            if isempty(filter(row -> row.week == gw && row.transfer_in == 1, plan).name)
                push!(buys, Dict("move" => "No transfer", "iter" => iter))
                push!(sells, Dict("move" => "No transfer", "iter" => iter))
                push!(move, Dict("move" => "No transfer", "iter" => iter))
            else
                buy_list = filter(row -> row.week == gw && row.transfer_in == 1, plan).name
                buy = join(buy_list, ", ")
                push!(buys, Dict("move" => buy, "iter" => iter))
        
                sell_list = filter(row -> row.week == gw && row.transfer_out == 1, plan).name
                sell = join(sell_list, ", ")
                push!(sells, Dict("move" => sell, "iter" => iter))
                push!(move, Dict("move" => "$(sell) -> $(buy)", "iter" => iter))
            end
            no_plans += 1
        end
        
        iter_scoring = Dict(1 => 3, 2 => 2, 3 => 1)
        
        buy_df = DataFrame(buys)
        buy_pivot = unstack(buy_df, :move, :iter, :iter, fill = 0, renamecols = x -> "iter_$x", combine= sum)
        iters = sort(unique(buy_df.iter))
        buy_pivot.PSB = sum.(eachrow(buy_pivot[:, [Symbol("iter_$i") for i in iters]])) / sum(sum.(eachrow(buy_pivot[:, [Symbol("iter_$i") for i in iters]])))
        buy_pivot.PSB = map(x -> "$(round(Int, x * 100))%", buy_pivot.PSB)
        buy_pivot.Score = [sum(row[Symbol("iter_$i")] * get(iter_scoring, i, 0) for i in iters) for row in eachrow(buy_pivot)]
        sort!(buy_pivot, :Score, rev=true)
        
        sell_df = DataFrame(sells)
        sell_pivot = unstack(sell_df, :move, :iter, :iter, fill = 0, renamecols = x -> "iter_$x", combine = sum)
        iters = sort(unique(sell_df.iter))
        sell_pivot.PSB = sum.(eachrow(sell_pivot[:, [Symbol("iter_$i") for i in iters]])) / sum(sum.(eachrow(sell_pivot[:, [Symbol("iter_$i") for i in iters]])))
        sell_pivot.PSB = map(x -> "$(round(Int, x * 100))%", sell_pivot.PSB)
        sell_pivot.Score = [sum(row[Symbol("iter_$i")] * get(iter_scoring, i, 0) for i in iters) for row in eachrow(sell_pivot)]
        sort!(sell_pivot, :Score, rev=true)
        
        move_df = DataFrame(move)
        move_pivot = unstack(move_df, :move, :iter, :iter, fill = 0, renamecols = x -> "iter_$x", combine = sum)
        iters = sort(unique(move_df.iter))
        move_pivot.PSB = sum.(eachrow(move_pivot[:, [Symbol("iter_$i") for i in iters]])) / sum(sum.(eachrow(move_pivot[:, [Symbol("iter_$i") for i in iters]])))
        move_pivot.PSB = map(x -> "$(round(Int, x * 100))%", move_pivot.PSB)
        move_pivot.Score = [sum(row[Symbol("iter_$i")] * get(iter_scoring, i, 0) for i in iters) for row in eachrow(move_pivot)]
        sort!(move_pivot, :Score, rev=true)

 
        println("Buy:")
        show(buy_pivot,maximum_columns_width = 0)
        println()
        
        println("Sell:")
        show(sell_pivot,maximum_columns_width = 0)
        

    elseif situation in ["Y", "y"]
    
        goalkeepers = String[]
        defenders = String[]
        midfielders = String[]
        forwards = String[]
        
        no_plans = 0
        
        for filename in readdir(directory)
            if occursin(".csv", filename)  # Ensure it's a CSV file
                plan = CSV.read(joinpath(directory, filename), DataFrame)
                append!(goalkeepers, plan[(plan.week .== gw) .& (plan.pos .== "GKP") .& (plan.transfer_out .!= 1), :name])
                append!(defenders, plan[(plan.week .== gw) .& (plan.pos .== "DEF") .& (plan.transfer_out .!= 1), :name])
                append!(midfielders, plan[(plan.week .== gw) .& (plan.pos .== "MID") .& (plan.transfer_out .!= 1), :name])
                append!(forwards, plan[(plan.week .== gw) .& (plan.pos .== "FWD") .& (plan.transfer_out .!= 1), :name])
                no_plans += 1
            end
        end
        
        keepers = combine(groupby(DataFrame(player=goalkeepers), :player), nrow => :PSB)
        defs = combine(groupby(DataFrame(player=defenders), :player), nrow => :PSB)
        mids = combine(groupby(DataFrame(player=midfielders), :player), nrow => :PSB)
        fwds = combine(groupby(DataFrame(player=forwards), :player), nrow => :PSB)

        for df in [keepers, defs, mids, fwds]
            sort!(df, order(:PSB, rev=true))
            df[!, :PSB] .= round.(df.PSB ./ no_plans * 100, digits=0)
            df[!, :PSB] .= string.(df.PSB, "%")
        end
        
        println("Goalkeepers:")
        println(keepers)
        println()
        println("Defenders:")
        println(defs)
        println()
        println("Midfielders:")
        println(mids)
        println()
        println("Forwards:")
        println(fwds)
        
        return Dict("keepers" => keepers, "defs" => defs, "mids" => mids, "fwds" => fwds)
        
    else
        println("Invalid input, please enter 'y' for a wildcard or 'n' for a regular transfer plan.")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__    
    s = ArgParseSettings(description="Summarize sensitivity analysis results")

    @add_arg_table! s begin
        "--gw"
            arg_type = Int
            help = "Numeric value for 'gw'"
        "--wildcard"
            help = "'Y' if using wildcard, 'N' otherwise"
    end

    parsed_args = parse_args(ARGS, s)
    gw_value = get(parsed_args, "gw", nothing)
    is_wildcard = get(parsed_args, "wildcard", nothing)

    read_sensitivity(Dict("gw" => gw_value, "situation" => is_wildcard))
end

