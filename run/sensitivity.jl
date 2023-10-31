using CSV, DataFrames, ArgParse

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
        no_plans = 0

        for filepath in readdir(directory)
            if endswith(filepath, ".csv")
                plan = CSV.File(joinpath(directory, filepath)) |> DataFrame
                buy_names = filter(row -> row[:week] == gw && row[:transfer_in] == 1, plan).name |> collect
                sell_names = filter(row -> row[:week] == gw && row[:transfer_out] == 1, plan).name |> collect

                if isempty(buy_names)
                    push!(buys, "No transfer")
                else
                    push!(buys, join(buy_names, ", "))
                end

                if isempty(sell_names)
                    push!(sells, "No transfer")
                else
                    push!(sells, join(sell_names, ", "))
                end

                no_plans += 1
            end
        end

        buy_sum = combine(groupby(DataFrame(player=buys), :player), nrow => :PSB)
        sell_sum = combine(groupby(DataFrame(player=sells), :player), nrow => :PSB)

        buy_sum[!, :PSB] = ["$(round(buy_sum[x, :PSB] / no_plans * 100))%" for x in 1:nrow(buy_sum)]
        sell_sum[!, :PSB] = ["$(round(sell_sum[x, :PSB] / no_plans * 100))%" for x in 1:nrow(sell_sum)]

        println("Buy:")
        println(join([join(row, "  ") for row in eachrow(buy_sum)], "\n"))
        println()
        
        println("Sell:")
        println(join([join(row, "  ") for row in eachrow(sell_sum)], "\n"))
        

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

