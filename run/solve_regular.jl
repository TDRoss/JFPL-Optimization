using Random
using JSON
using ArgParse
using Dates
using DataFrames
using PrettyTables
include("../src/data_parser.jl")
include("../src/multi_period_dev.jl")

function get_random_id(n::Int)
    return join(rand(vcat('a':'z', 'A':'Z', '0':'9'), n))
end

function solve_regular(runtime_options::Union{Dict, Nothing}=nothing)

    base_folder = joinpath(pwd(), "..", "src")
    push!(LOAD_PATH, base_folder)

    options = JSON.parsefile(joinpath("..", "data", "regular_settings.json"))

    s = ArgParseSettings(add_help=false)
    for (key, value) in options
        if isa(value, Union{Array, Dict})
            continue
        end
        add_arg_table!(s, key, Dict(:default => value, :arg_type => typeof(value)))
    end

    args = parse_args(ARGS, s)
    options = merge(options, args)

    if !isnothing(runtime_options)
        merge!(options, runtime_options)
    end

    if get(options, "preseason", false)
        my_data = Dict(
            "picks" => [],
            "chips" => [],
            "transfers" => Dict("limit" => nothing, "cost" => 4, "bank" => 1000, "value" => 0)
        )
    elseif get(options, "use_login", false)
        session, team_id = connect()
        if isnothing(session) && isnothing(team_id)
            exit(0)
        end
    else
        if lowercase(get(options, "team_data", "json")) == "id"
            team_id = get(options, "team_id", nothing)
            if isnothing(team_id)
                println("You must supply your team_id in data/regular_settings.json")
                exit(0)
            end
            my_data = generate_team_json(team_id)
        else
            try
                open("../data/team.json", "r") do f
                    my_data = JSON.parse(f)
                end
            catch e
                if isa(e, SystemError)
                    println("""You must either:
                            1. Download your team data from https://fantasy.premierleague.com/api/my-team/YOUR-TEAM-ID/ and
                                save it under data folder with name 'team.json', or
                            2. Set "team_data" in regular_settings to "ID", and set the "team_id" value to your team's ID""")
                    exit(0)
                end
            end
        end
    end

    data = prep_data(my_data, options)

    response = solve_multi_period_fpl(data, options)
    run_id = get_random_id(5)

    for result in response
        iter = result["iter"]
        println(result["summary"])
        time_now = now()
        stamp = Dates.format(time_now, "Y-m-d_H-M-S")
        
        if !isdir("../data/results/")
            mkdir("../data/results/")
        end
        CSV.write("../data/results/regular_$(stamp)_$(run_id)_$(iter).csv", result["picks"])
    end

    result_table = DataFrame(response)
    println(result_table[:, [:iter, :sell, :buy, :score]])

    # Detailed print
    h1 = Highlighter(f = (data, i, j) -> (data[i,j] == "Roll"), crayon = Crayon(foreground = :yellow))
    h2 = Highlighter(f = (data, i, j) -> (j == 5), crayon = Crayon(foreground = :blue))
    for result in response
        picks = result["picks"]
        gws = unique(picks[!, "week"])
        println("Solution ", result["iter"])
    #     for gw in gws
    #         line_text = ""
    #         chip_text = picks[picks.week .== gw, :chip][1]
    #         if chip_text != ""
    #             line_text *= "($chip_text) "
    #         end
    #         sell_text = join(picks[(picks[!, "week"] .== gw) .& (picks[!, "transfer_out"] .== 1), "name"], ", ")
    #         buy_text = join(picks[(picks[!, "week"] .== gw) .& (picks[!, "transfer_in"] .== 1), "name"], ", ")
    #         if sell_text != ""
    #             line_text *= sell_text * " -> " * buy_text
    #         else
    #             line_text *= "Roll"
    #         end
    #         println("\tGW$gw: $line_text")
    #     end
    # end

        sell_text = [join(picks[(picks[!, "week"] .== gw) .& (picks[!, "transfer_out"] .== 1), "name"], "\n") for gw in gws]
        buy_text = [join(picks[(picks[!, "week"] .== gw) .& (picks[!, "transfer_in"] .== 1), "name"], "\n") for gw in gws]
        sell_text[sell_text.==""] .= "Roll"
        buy_text[buy_text.==""] .= "Roll"
        itb_text = [string(picks[picks[!,"week"] .== gw, "ITB"][1]) for gw in gws]
        chip_text = [picks[picks.week .== gw, :chip][1] for gw in gws]
        if all(s -> s == "", chip_text)
            header = ["", "Transfer Out", "Transfer In", "ITB"]
            text_data = [["GW$(gws[i])", sell_text[i], buy_text[i], itb_text[i]] for i in eachindex(gws)]
        else
            header = ["", "Transfer Out", "Transfer In", "ITB", "Chips"]
            text_data = [["GW$(gws[i])", sell_text[i], buy_text[i], itb_text[i], chip_text[i]] for i in eachindex(gws)]
        end
        text_matrix = reduce(vcat, map(row -> reshape(row, 1, length(row)), text_data))
        pretty_table(text_matrix; header=header, alignment=:c, crop = :none, highlighters=(h1,h2),tf=tf_unicode_rounded, linebreaks=true, body_hlines=collect(eachindex(gws)))
    end


    # Link to FPL.Team
    get_fplteam_link(options, response)

end



function get_fplteam_link(options, response)
    
    println("\nYou can see the solutions on a planner using the following FPL.Team links:")
    team_id = get(options, "team_id", 1)
    if team_id === nothing
        println("(Do not forget to add your team ID to regular_settings.json file to get a custom link.)")
    end
    
    url_base = "https://fpl.team/plan/$team_id/?"

    for result in response
        result_url = url_base
        picks = result["picks"]
        gws = unique(picks[!, "week"])
        
        for gw in gws
            lineup_players = join(picks[(picks[!, "week"] .== gw) .& (picks[!, "lineup"] .> 0.5), "id"], ",")
            bench_players = join(picks[(picks[!, "week"] .== gw) .& (picks[!, "bench"] .> -0.5), "id"], ",")
            cap = picks[(picks[!, "week"] .== gw) .& (picks[!, "captain"] .> 0.5), "id"][1]
            vcap = picks[(picks[!, "week"] .== gw) .& (picks[!, "vicecaptain"] .> 0.5), "id"][1]
            chip = picks[picks[!, "week"] .== gw, "chip"][1]

            sold_players = sort(picks[(picks[!, "week"] .== gw) .& (picks[!, "transfer_out"] .> 0.5), "id"], rev=true)
            bought_players = sort(picks[(picks[!, "week"] .== gw) .& (picks[!, "transfer_in"] .> 0.5), "id"], rev=true)

            if gw == 1
                sold_players = []
                bought_players = []
            end
            
            tr_string = join(["$i,$j" for (i, j) in zip(sold_players, bought_players)], ";")
            tr_string = isempty(tr_string) ? ";" : tr_string

            sub_text = if gw == 1
                ";"
            else
                prev_lineup = sort(picks[(picks[!, "week"] .== gw - 1) .& (picks[!, "lineup"] .> 0.5), "id"], rev=true)
                now_bench = sort(picks[(picks[!, "week"] .== gw) .& (picks[!, "bench"] .> -0.5), "id"], rev=true)
                lineup_to_bench = [i for i in prev_lineup if i in now_bench]
                prev_bench = sort(picks[(picks[!, "week"] .== gw - 1) .& (picks[!, "bench"] .> -0.5), "id"], rev=true)
                now_lineup = sort(picks[(picks[!, "week"] .== gw) .& (picks[!, "lineup"] .> 0.5), "id"], rev=true)
                bench_to_lineup = [i for i in prev_bench if i in now_lineup]
                join(["$i,$j" for (i, j) in zip(lineup_to_bench, bench_to_lineup)], ";")
            end
            sub_text = isempty(sub_text) ? ";" : sub_text

            gw_params = "lineup$gw=$lineup_players&bench$gw=$bench_players&cap$gw=$cap&vcap$gw=$vcap&chip$gw=$chip&transfers$gw=$tr_string&subs$gw=$sub_text&opt=true"
            result_url *= (gw == gws[1] ? "" : "&") * gw_params
        end
        println("Solution ", result["iter"], ": ", result_url)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__    
    solve_regular()
end
