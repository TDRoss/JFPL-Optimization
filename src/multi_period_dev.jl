using CSV, DataFrames, JuMP, HiGHS, HTTP, JSON, Profile, Statistics
using Base.Iterators: product

include("data_parser.jl")


function get_random_id(n::Int)
    chars = join([uppercase, lowercase, "0123456789"])
    return join(rand(chars, n))
end


function xmin_to_prob(xmin; sub_on=0.5, sub_off=0.3)
    start = clamp((xmin - 25 * sub_on) / (90 * (1-sub_off) + 65 * sub_off - 25 * sub_on), 0.001, 0.999)
    return start + (1-start) * sub_on
end

function get_dict_combinations(my_dict::Dict)
    
    for (key, value) in my_dict
        if isnothing(value) || isempty(value)
            my_dict[key] = [nothing]
        end
    end
    
    all_combs = [Dict(zip(keys(my_dict), values)) for values in product(values(my_dict)...)]
    feasible_combs = []
    
    feasible_combs = filter(all_combs) do comb
        c_values = [v for v in values(comb) if !isnothing(v)]
        length(c_values) == length(Set(c_values))
    end
    
    return feasible_combs
end

function get_my_data(session, team_id::Int)
    r = HTTP.get(session, "https://fantasy.premierleague.com/api/my-team/$team_id/")
    d = JSON.parse(String(r.body))
    d["team_id"] = team_id
    return d
end

function generate_team_json(team_id::Int)
    BASE_URL = "https://fantasy.premierleague.com/api"
    session = HTTP.Session()
    
    static_url = "$BASE_URL/bootstrap-static/"
    static = JSON.parse(String(HTTP.get(session, static_url).body))
    next_gw = [x for x in static["events"] if x["is_next"]][1]["id"]
    
    start_prices = Dict(x["id"] => x["now_cost"] - x["cost_change_start"] for x in static["elements"])
    
    gw1_url = "$BASE_URL/entry/$team_id/event/1/picks/"
    gw1 = JSON.parse(String(HTTP.get(session, gw1_url).body))
    
    transfers_url = "$BASE_URL/entry/$team_id/transfers/"
    transfers = reverse(JSON.parse(String(HTTP.get(session, transfers_url).body)))
    
    chips_url = "$BASE_URL/entry/$team_id/history/"
    chips = JSON.parse(String(HTTP.get(session, chips_url).body))["chips"]
    fh = [x for x in chips if x["name"] == "freehit"]
    if !isempty(fh)
        fh = fh[1]["event"]
    end
    wc_gws = [x.event for x in chips if x.name == "wildcard"]

    squad = Dict(x["element"] => start_prices[x["element"]] for x in gw1["picks"])

    itb = 1000 - sum(values(squad))
    for t in transfers
        if t["event"] == fh
            continue
        end
        itb += t["element_out_cost"]
        itb -= t["element_in_cost"]
        delete!(squad, t["element_out"])
        squad[t["element_in"]] = t["element_in_cost"]
    end

    fts = calculate_fts(transfers, next_gw, fh, wc_gws)
    my_data = Dict(
        "chips" => [],
        "picks" => [],
        "team_id" => team_id,
        "transfers" => Dict(
            "bank" => itb,
            "limit" => fts,
            "made" => 0
        )
    )
    for (player_id, purchase_price) in squad
        now_cost = [x for x in static["elements"] if x["id"] == player_id][1]["now_cost"]
        diff = now_cost - purchase_price
        selling_price = diff > 0 ? purchase_price + div(diff, 2) : now_cost

        push!(my_data["picks"], Dict(
            "element" => player_id,
            "purchase_price" => purchase_price,
            "selling_price" => selling_price
        ))
    end

    return my_data
end

function calculate_fts(transfers::Vector{Dict{String, Int}}, next_gw::Int, fh::Int, wc_gws::Int)
    n_transfers = Dict(gw => 0 for gw in 2:(next_gw - 1))
    for t in transfers
        n_transfers[t["event"]] += 1
    end
    fts = Dict(gw => 0 for gw in 2:next_gw)
    fts[2] = 1
    for i in 3:next_gw
        if (i - 1) == fh
            fts[i] = fts[i-1]
            continue
        end
        if i-1 in wc_gws
            fts[i] = fts[i-1]
            continue
        end
        fts[i] = fts[i - 1]
        fts[i] -= n_transfers[i - 1]
        fts[i] = max(fts[i], 0)
        fts[i] += 1
        fts[i] = min(fts[i], 5)
    end
    return fts[next_gw]
end


function prep_data(my_data::Dict{String, Any}, options::Dict{String, Any})
    BASE_URL = "https://fantasy.premierleague.com/api"
    r = HTTP.get("$BASE_URL/bootstrap-static/")
    fpl_data = JSON.parse(String(r.body))

    gw = 0
    for e in fpl_data["events"]
        if e["is_next"]
            gw = e["id"]
            break
        end
    end

    horizon = get(options, "horizon", 3)

    element_data = DataFrame(fpl_data["elements"])
    team_data = DataFrame(fpl_data["teams"])
    elements_team = innerjoin(element_data, team_data, on = "team" => "id", makeunique=true)

    datasource = get(options, "datasource", "review")
    data_weights = get(options, "data_weights", Dict("review" => 100))

    data = read_data(options, datasource, weights=data_weights)

    data .= coalesce.(data, 0)
    if hasproperty(data, :ID)
        data[!, :review_id] = data[!, :ID]
    else
        data[!, :review_id] = 1:nrow(data)
    end

    if get(options, "export_data", "") != "" && datasource == "mixed"
        CSV.write("../data/$(options["export_data"])", data)
    end

    merged_data = innerjoin(elements_team, data, on = :id => :review_id)
    sort!(merged_data,:id)

    # Check if data exists
    for week in gw:min(38, gw + horizon - 1)
        if "$(week)_Pts" ∉ names(data)
            throw(ArgumentError("$(week)_Pts is not inside prediction data, change your horizon parameter or update your prediction data"))
        end
    end

    original_keys = names(merged_data)
    key_list = filter(k -> occursin("_Pts", k), original_keys)
    min_keys = filter(k -> occursin("_xMins", k), original_keys)
    merged_data[!, :total_ev] =  [sum(row[key_list]) for row in eachrow(merged_data)]
    merged_data[!, :total_min] = [sum(row[min_keys]) for row in eachrow(merged_data)]

    sort!(merged_data, :total_ev, rev=true)



    locked_next_gw = [isa(i, Vector) ? Int(i[1]) : Int(i) for i in get(options, "locked_next_gw", [])]
    safe_players_due_price = Int[]

    for (pos, vals) in get(options, "pick_prices", Dict())
        isnothing(vals) || vals == "" && continue
        price_vals = [parse(Float64, i) for i in split(vals, ',')]
        pp = merged_data[
            (merged_data.Pos .== pos) .& 
            (in.(merged_data.now_cost ./ 10, Ref(price_vals))), 
            :review_id
        ]
        append!(safe_players_due_price, pp)
    end

    initial_squad = [Int(i["element"]) for i in my_data["picks"]]
    safe_players = vcat(
        initial_squad, 
        get(options, "locked", []), 
        get(options, "keep", []), 
        locked_next_gw, 
        safe_players_due_price
    )

    # Filter players by xMin
    xmin_lb = get(options, "xmin_lb", 1)
    println(size(merged_data, 1), " total players (before)")
    filter!(row -> row[:total_min] >= xmin_lb || row[:id] in safe_players, merged_data)

    # Filter by ev per price
    ev_per_price_cutoff = get(options, "ev_per_price_cutoff", 0)
    for bt in get(options, "booked_transfers", [])
        if haskey(bt, "transfer_in")
            push!(safe_players, bt["transfer_in"])
        end
        if haskey(bt, "transfer_out")
            push!(safe_players, bt["transfer_out"])
        end
    end
    if ev_per_price_cutoff != 0
        cutoff = quantile(merged_data[!, :total_ev] ./ merged_data[!, :now_cost], ev_per_price_cutoff/100)
        filter!(row -> (row[:total_ev] / row[:now_cost] > cutoff) || (row[:id] in safe_players), merged_data)
    end

    println(size(merged_data, 1), " total players (after)")
    

    if get(options, "randomized", false)
        rng = MersenneTwister(get(options, "seed", nothing))
        gws = gw:min(38, gw + horizon - 1)
        for w in gws
            column_pts = Symbol("$(w)_Pts")
            column_xmins = Symbol("$(w)_xMins")
            noise = merged_data[!, column_pts] .* (92 .- merged_data[!, column_xmins]) ./ 134 .* randn(rng, size(merged_data, 1))
            merged_data[!, column_pts] .+= noise
        end
    end

    type_data = DataFrame(fpl_data["element_types"])
    sort!(type_data, :id)

    buy_price = Dict(row[:id] => row[:now_cost] / 10 for row in eachrow(merged_data))
    sell_price = Dict(i["element"] => i["selling_price"] / 10 for i in my_data["picks"])
    price_modified_players = Int[]

    preseason = get(options, "preseason", false)
    if !preseason
        for i in my_data["picks"]
            if buy_price[i["element"]] != sell_price[i["element"]]
                push!(price_modified_players, i["element"])
                println("Added player ", i["element"], " to list, buy price ", buy_price[i["element"]], " sell price ", sell_price[i["element"]])
            end
        end
    end

    itb = my_data["transfers"]["bank"] / 10
    ft_base = Nothing
    if isnothing(my_data["transfers"]["limit"])
        ft = 1
        ft_base = 1
    else
        ft = my_data["transfers"]["limit"] - my_data["transfers"]["made"]
        ft_base = my_data["transfers"]["limit"]
    end
    ft = max(ft, 0)

    # If wildcard is active
    for c in my_data["chips"]
        if c["name"] == "wildcard" && c["status_for_entry"] == "active"
            options["use_wc"] = gw
            if get(options, "chip_limits", Dict("wc" => 0))["wc"] == 0
                options["chip_limits"]["wc"] = 1
            end
            break
        end
    end

    # Fixture info
    team_code_dict = Dict(row.id => row.name for row in eachrow(team_data))
    r = HTTP.get("https://fantasy.premierleague.com/api/fixtures/")
    fixture_data = JSON.parse(String(r.body))
    fixtures = [Dict("gw" => f["event"], "home" => team_code_dict[f["team_h"]], "away" => team_code_dict[f["team_a"]]) for f in fixture_data]

    return Dict(
        "merged_data" => merged_data,
        "team_data" => team_data,
        "my_data" => my_data,
        "type_data" => type_data,
        "next_gw" => gw,
        "initial_squad" => initial_squad,
        "sell_price" => sell_price,
        "buy_price" => buy_price,
        "price_modified_players" => price_modified_players,
        "itb" => itb,
        "ft" => ft,
        "ft_base" => ft_base,
        "fixtures" => fixtures
    )
end
    
function solve_multi_period_fpl(data, options)

    try
        commit_hash = readchomp(`git rev-parse --short HEAD`)
        commit_count = readchomp(`git rev-list --count HEAD`)
        version = "$(commit_count) - $(commit_hash)"
        println("Version: $version")
    catch e
        @warn "Failed to get Git version: $(e)"
    end

    # Arguments
    # problem_id = get_random_id(5)
    horizon = get(options, "horizon", 3)
    objective = get(options, "objective", "decay")
    decay_base = get(options, "decay_base", 0.84)
    bench_weights = get(options, "bench_weights", Dict("0" => 0.03, "1" => 0.21, "2" => 0.06, "3" => 0.002))
    bench_weights = Dict(parse(Int,key) => value for (key, value) in bench_weights)
    ft_value = get(options, "ft_value", 1.5)
    ft_value_list = get(options,"ft_value_list", Dict())
    # ft_gw_value = Dict()
    ft_use_penalty = get(options, "ft_use_penalty", nothing)
    itb_value = get(options, "itb_value", 0.08)

    ft = get(data, "ft", 1)
    ft_base = get(data, "ft_base",1)
    if ft <= 0
        ft = 0
    end

    chip_limits = get(options, "chip_limits", Dict())
    allowed_chip_gws = get(options, "allowed_chip_gws", Dict())
    forced_chip_gws = get(options,"forced_chip_gws", Dict())
    run_chip_combinations = get(options,"run_chip_combinations", nothing)
    booked_transfers = get(options, "booked_transfers", [])
    preseason = get(options, "preseason", false)

    itb_loss_per_transfer = get(options, "itb_loss_per_transfer", nothing)
    if itb_loss_per_transfer === nothing 
        itb_loss_per_transfer = 0
    end

    # Data
    problem_name = objective == "regular" ? "mp_h$(horizon)_regular" : "mp_h$(horizon)_o$(first(objective))_d$(decay_base)"
    merged_data = data["merged_data"]
    team_data = data["team_data"]
    type_data = data["type_data"]
    next_gw = data["next_gw"]
    initial_squad = data["initial_squad"]
    itb = data["itb"]
    fixtures = data["fixtures"]
    if preseason
        itb = 100
        threshold_gw = 2
    else
        threshold_gw = next_gw
    end

    # Sets
    players = merged_data[:, :id]
    playerinex = Dict(value => index for (index,value) in enumerate(players))
    element_types = type_data[:,:id]
    teams = team_data[:,:name]
    last_gw = next_gw + horizon -1
    if last_gw > 38
        last_gw = 38
        horizon = 39 - next_gw
    end
    gameweeks = collect(next_gw:last_gw)
    all_gw = [next_gw-1; gameweeks]
    order = collect(0:3)
    price_modified_players = data["price_modified_players"]
    ft_states = [0, 1, 2, 3, 4, 5]

    # Model
    model = Model(HiGHS.Optimizer)
    set_attribute(model, "presolve", "on")


    # Variables
    @variable(model, squad[players, all_gw], Bin)
    @variable(model, squad_fh[players, gameweeks], Bin)
    @variable(model, lineup[players, gameweeks], Bin)
    @variable(model, captain[players, gameweeks], Bin)
    @variable(model, vicecap[players, gameweeks], Bin)
    @variable(model, bench[players, gameweeks, order], Bin)
    @variable(model, transfer_in[players, gameweeks], Bin)
    @variable(model, transfer_out_first[price_modified_players, gameweeks], Bin)
    @variable(model, transfer_out_regular[players, gameweeks], Bin)
    @variable(model, aux[gameweeks], Bin)
    @variable(model, use_wc[gameweeks], Bin)
    @variable(model, use_bb[gameweeks], Bin)
    @variable(model, use_fh[gameweeks], Bin)
    @variable(model, use_tc[players, gameweeks], Bin)
    transfer_out = Dict((p, w) => transfer_out_regular[p,w] + (p in price_modified_players ? transfer_out_first[p,w] : 0) for p in players, w in gameweeks)
    @variable(model, in_the_bank[all_gw] >= 0)
    @variable(model, 0 <= free_transfers[all_gw] <= 5, Int)
    @variable(model, ft_above_ub[gameweeks], Bin)
    @variable(model, ft_below_lb[gameweeks], Bin)
    @variable(model, free_transfers_state[gameweeks, ft_states], Bin)
    @variable(model, penalized_transfers[gameweeks] >= 0, Int)
    @variable(model, 0 <= transfer_count[gameweeks] <= 15, Int)


    # Dictionaries
    lineup_type_count = Dict((t, w) => sum(lineup[p, w] for p in players if merged_data[playerinex[p], "element_type"] == t) 
    for t in element_types for w in gameweeks)
    squad_type_count = Dict((t, w) => sum(squad[p, w] for p in players if merged_data[playerinex[p], "element_type"] == t) 
    for t in element_types for w in gameweeks)
    squad_fh_type_count = Dict((t, w) => sum(squad_fh[p, w] for p in players if merged_data[playerinex[p], "element_type"] == t) 
    for t in element_types for w in gameweeks)
    player_type = Dict(p => merged_data[playerinex[p], "element_type"] for p in players)
    sell_price = data["sell_price"]
    buy_price = data["buy_price"]
    sold_amount = Dict(w => sum(sell_price[p] * transfer_out_first[p, w] for p in price_modified_players; init=0) +
    sum(buy_price[p] * transfer_out_regular[p, w] for p in players; init= 0) 
    for w in gameweeks)
    fh_sell_price = Dict(p => p in price_modified_players ? sell_price[p] : buy_price[p] for p in players)
    bought_amount = Dict(w => sum(buy_price[p] * transfer_in[p, w] for p in players) for w in gameweeks)
    points_player_week = Dict((p, w) => merged_data[playerinex[p], "$(w)_Pts"] for p in players for w in gameweeks)
    minutes_player_week = Dict((p, w) => merged_data[playerinex[p], "$(w)_xMins"] for p in players for w in gameweeks)
    player_team = Dict(p => merged_data[playerinex[p], "name"] for p in players)
    squad_count = Dict(w => sum(squad[p, w] for p in players) for w in gameweeks)
    squad_fh_count = Dict(w => sum(squad_fh[p, w] for p in players) for w in gameweeks)
    number_of_transfers = Dict(w => sum(transfer_out[p, w] for p in players) for w in gameweeks)
    # number_of_transfers[next_gw-1] = 1
    transfer_diff = Dict(w => number_of_transfers[w] - free_transfers[w] - 15 * use_wc[w] for w in gameweeks)


    use_tc_gw = Dict(w => sum(use_tc[p,w] for p in players) for w in gameweeks)

    # Chip combinations
    if run_chip_combinations !== nothing
        chip_combinations = get_dict_combinations(run_chip_combinations)
        if length(chip_combinations) > 0
            if all(isnothing, values(chip_combinations[1]))
                # No possible chip combination
            else
                println("You have active chip combinations, iteration parameter will be overridden")
                options["iteration"] = length(chip_combinations)
                options["iteration_criteria"] = "chip_combinations"
            

                current_chips = chip_combinations[1]
                pairs = [
                    Dict("chip" => "wc", "variable" => use_wc),
                    Dict("chip" => "fh", "variable" => use_fh),
                    Dict("chip" => "bb", "variable" => use_bb),
                    Dict("chip" => "tc", "variable" => use_tc_gw)
                ]
                for pair in pairs
                    chip = pair["chip"]
                    variable = pair["variable"]
                    if haskey(current_chips, chip)
                        @constraint(model, variable[current_chips[chip]] == 1, base_name="cc_$chip")
                        options["chip_limits"][chip] = 1
                    else
                        @constraint(model, sum(variable[w] for w in gameweeks) == 0, base_name="cc_$chip")
                        options["chip_limits"][chip] = 0
                    end
                end
            end
        end
    end
    # Initial conditions
    @constraint(model, [p in initial_squad], squad[p, next_gw-1] == 1, base_name="initial_squad_players")
    @constraint(model, [p in setdiff(players,initial_squad)], squad[p, next_gw-1] == 0, base_name="initial_squad_others")
    @constraint(model, in_the_bank[next_gw-1] == itb, base_name="initial_itb")
    @constraint(model, free_transfers[next_gw] == ft * (1-use_wc[next_gw]) + ft_base * use_wc[next_gw], base_name="initial_ft")
    @constraint(model, [w in gameweeks[gameweeks .> next_gw]], free_transfers[w] >= 1, base_name="future_ft_limit")

    # Constraints
    @constraint(model, [w in gameweeks], squad_count[w] == 15)
    @constraint(model, [w in gameweeks], squad_fh_count[w] == 15 * use_fh[w])
    @constraint(model, [w in gameweeks], sum(lineup[p,w] for p in players) == 11 + 4 * use_bb[w])
    @constraint(model, [w in gameweeks], sum(bench[p,w,0] for p in players if player_type[p] == 1) == 1 - use_bb[w])
    @constraint(model, [w in gameweeks, o in 1:3], sum(bench[p,w,o] for p in players) == 1 - use_bb[w])
    @constraint(model, [w in gameweeks], sum(captain[p,w] for p in players) == 1)
    @constraint(model, [w in gameweeks], sum(vicecap[p,w] for p in players) == 1)
    @constraint(model, [p in players, w in gameweeks], lineup[p,w] <= squad[p,w] + use_fh[w])
    @constraint(model, [p in players, w in gameweeks, o in order], bench[p,w,o] <= squad[p,w] + use_fh[w])
    @constraint(model, [p in players, w in gameweeks], lineup[p,w] <= squad_fh[p,w] + 1 - use_fh[w])
    @constraint(model, [p in players, w in gameweeks, o in order], bench[p,w,o] <= squad_fh[p,w] + 1 - use_fh[w])
    @constraint(model, [p in players, w in gameweeks], captain[p,w] <= lineup[p,w])
    @constraint(model, [p in players, w in gameweeks], vicecap[p,w] <= lineup[p,w])
    @constraint(model, [p in players, w in gameweeks], captain[p,w] + vicecap[p,w] <= 1)
    @constraint(model, [p in players, w in gameweeks], lineup[p,w] + sum(bench[p,w,o] for o in order) <= 1)
    @constraint(model, [t in element_types, w in gameweeks], lineup_type_count[t,w] >= type_data[t, "squad_min_play"])
    @constraint(model, [t in element_types, w in gameweeks], lineup_type_count[t,w] <= type_data[t, "squad_max_play"] + use_bb[w])
    @constraint(model, [t in element_types, w in gameweeks], squad_type_count[t,w] == type_data[t, "squad_select"])
    @constraint(model, [t in element_types, w in gameweeks], squad_fh_type_count[t,w] == type_data[t, "squad_select"] * use_fh[w])
    @constraint(model, [t in teams, w in gameweeks], sum(squad[p,w] for p in players if player_team[p] == t) <= 3, base_name="team_limit")
    @constraint(model, [t in teams, w in gameweeks], sum(squad_fh[p,w] for p in players if player_team[p] == t) <= 3 * use_fh[w], base_name="team_limit_fh")

    ## Transfer constraints
    @constraint(model, [p in players, w in gameweeks], squad[p,w] == squad[p,w-1] + transfer_in[p,w] - transfer_out[p,w])
    @constraint(model, [w in gameweeks], in_the_bank[w] == in_the_bank[w-1] + sold_amount[w] - bought_amount[w] - (w > next_gw ? transfer_count[w] * itb_loss_per_transfer : 0))
    @constraint(model, [w in gameweeks], sum(fh_sell_price[p] * squad[p,w-1] for p in players) + in_the_bank[w-1] >= sum(fh_sell_price[p] * squad_fh[p,w] for p in players))
    @constraint(model, [p in players, w in gameweeks], transfer_in[p,w] <= 1-use_fh[w])
    @constraint(model, [p in players, w in gameweeks], transfer_out[p,w] <= 1-use_fh[w])

    ## Free transfer constraints
    # 2024-2025 variation: min 1 / max 5 / roll over WC & FH
    @expression(model, raw_gw_ft[w in gameweeks], 
    free_transfers[w] - transfer_count[w] + 1 - use_wc[w] - use_fh[w])

    @constraint(model, newft1[w in gameweeks; w+1 in gameweeks],
    free_transfers[w+1] <= raw_gw_ft[w] + 16 * ft_below_lb[w])

    @constraint(model, newft2[w in gameweeks; w+1 in gameweeks],
    free_transfers[w+1] <= 1 + 4 * (1 - ft_below_lb[w]))

    @constraint(model, newft3[w in gameweeks; w+1 in gameweeks && w > 1],
    free_transfers[w+1] >= raw_gw_ft[w] - 2 * ft_above_ub[w])

    @constraint(model, newft4[w in gameweeks; w+1 in gameweeks && w > 1],
    free_transfers[w+1] >= 5 - 5 * (1 - ft_above_ub[w]))

    @constraint(model, ftsc1[w in gameweeks],
    free_transfers[w] == sum(free_transfers_state[w,s] * s for s in ft_states))

    @constraint(model, ftsc2[w in gameweeks],
    sum(free_transfers_state[w,s] for s in ft_states) == 1)

    # @constraint(model, [w in gameweeks[gameweeks .> threshold_gw]] ,free_transfers[w] == aux[w] + 1)
    # @constraint(model, [w in gameweeks[gameweeks .> threshold_gw]] , free_transfers[w-1] - number_of_transfers[w-1] - 2 * use_wc[w-1] - 2 * use_fh[w-1] <= 2 * aux[w])
    # @constraint(model, [w in gameweeks[gameweeks .> threshold_gw]] , free_transfers[w-1] - number_of_transfers[w-1] - 2 * use_wc[w-1] - 2 * use_fh[w-1] >= aux[w] + (-14)*(1-aux[w]))
    
    if preseason && threshold_gw in gameweeks
        @constraint(model, free_transfers[threshold_gw] == 1)
    end
    @constraint(model, [w in gameweeks], penalized_transfers[w] >= transfer_diff[w])

    # Only one chip can be used in any gameweek
    @constraint(model, [w in gameweeks], use_wc[w] + use_fh[w] + use_bb[w] + use_tc_gw[w] <= 1)
    # If wc is used in the previous gameweek, then aux cannot be set to 1 in the current gameweek
    @constraint(model, [w in gameweeks[gameweeks .> next_gw]], aux[w] <= 1-use_wc[w-1])
    # If fh is used in the previous gameweek, then aux cannot be set to 1 in the current gameweek
    @constraint(model, [w in gameweeks[gameweeks .> next_gw]], aux[w] <= 1-use_fh[w-1])

    if ~isnothing(options["use_wc"])
        @constraint(model, use_wc[options["use_wc"]] == 1)
        chip_limits["wc"] = 1
    end
    
    if ~isnothing(options["use_bb"])
        @constraint(model, use_bb[options["use_bb"]] == 1)
        chip_limits["bb"] = 1
    end
    
    if ~isnothing(options["use_fh"])
        @constraint(model, use_fh[options["use_fh"]] == 1)
        chip_limits["fh"] = 1
    end

    if ~isnothing(options["use_tc"])
        @constraint(model, use_tc_gw[options["use_tc"]] == 1)
        chip_limits["tc"] = 1
    end

    @constraint(model, sum(use_wc[w] for w in gameweeks) <= get(chip_limits, "wc", 0))
    @constraint(model, sum(use_bb[w] for w in gameweeks) <= get(chip_limits, "bb", 0))
    @constraint(model, sum(use_fh[w] for w in gameweeks) <= get(chip_limits, "fh", 0))
    @constraint(model, sum(use_tc_gw[w] for w in gameweeks) <= get(chip_limits, "tc", 0))
    @constraint(model, [p in players, w in gameweeks], squad_fh[p, w] <= use_fh[w])

    if length(get(allowed_chip_gws, "wc", [])) > 0
        gws_banned = [w for w in gameweeks if w ∉ allowed_chip_gws["wc"]]
        @constraint(model, [w in gws_banned], use_wc[w] == 0)
    end

    if length(get(allowed_chip_gws, "fh", [])) > 0
        gws_banned = [w for w in gameweeks if w ∉ allowed_chip_gws["fh"]]
        @constraint(model, [w in gws_banned], use_fh[w] == 0)
    end

    if length(get(allowed_chip_gws, "bb", [])) > 0
        gws_banned = [w for w in gameweeks if w ∉ allowed_chip_gws["bb"]]
        @constraint(model, [w in gws_banned], use_bb[w] == 0)
    end

    if !isempty(get(allowed_chip_gws, "tc", []))
        gws_banned = [w for w in gameweeks if w ∉ allowed_chip_gws[:tc]]
        @constraint(model, [w in gws_banned], use_tc_gw[w] == 0, base_name="banned_tc_gws")
    end
    
    if !isempty(get(forced_chip_gws, "wc", []))
        @constraint(model, sum(use_wc[w] for w in forced_chip_gws[:wc]) == 1, base_name="force_wc_gw")
        chip_limits[:wc] = 1
    end
    
    if !isempty(get(forced_chip_gws, "fh", []))
        @constraint(model, sum(use_fh[w] for w in forced_chip_gws[:fh]) == 1, base_name="force_fh_gw")
        chip_limits[:fh] = 1
    end
    
    if !isempty(get(forced_chip_gws, "bb", []))
        @constraint(model, sum(use_bb[w] for w in forced_chip_gws[:bb]) == 1, base_name="force_bb_gw")
        chip_limits[:bb] = 1
    end
    
    if !isempty(get(forced_chip_gws, "tc", []))
        @constraint(model, sum(use_tc_gw[w] for w in forced_chip_gws[:tc]) == 1, base_name="force_tc_gw")
        chip_limits[:tc] = 1
    end

    # Multiple-sell fix
    @constraint(model, [p in price_modified_players, w in gameweeks], transfer_out_first[p, w] + transfer_out_regular[p, w] <= 1)
    @constraint(model, [p in price_modified_players, wbar in gameweeks], 
        horizon * sum(transfer_out_first[p, w] for w in gameweeks if w <= wbar) >=
        sum(transfer_out_regular[p, w] for w in gameweeks if w >= wbar)
    )
    @constraint(model, [p in price_modified_players], sum(transfer_out_first[p, w] for w in gameweeks) <= 1)

    # Transfer in/out fix
    @constraint(model, [p in players, w in gameweeks], transfer_in[p, w] + transfer_out[p, w] <= 1)

    # Tr Count Constraints
    ft_penalty = Dict(w => 0 for w in gameweeks)
    @constraint(model, [w in gameweeks], transfer_count[w] >= number_of_transfers[w] - 15 * use_wc[w])
    @constraint(model, [w in gameweeks], transfer_count[w] <= number_of_transfers[w])
    @constraint(model, [w in gameweeks], transfer_count[w] <= 15 * (1 - use_wc[w]))
    if ft_use_penalty !== nothing
        ft_penalty = Dict(w => ft_use_penalty * transfer_count[w] for w in gameweeks)
    end

    # Optional constraints
    if !isempty(get(options, "banned", []))
        println("OC - Banned")
        banned_players = options["banned"]
        @constraint(model, [p in banned_players], sum(squad[p, w] for w in gameweeks) == 0, base_name = "ban_player")
        @constraint(model, [p in banned_players], sum(squad_fh[p, w] for w in gameweeks) == 0, base_name = "ban_player_fh")
    end

    if !isempty(get(options, "banned_next_gw", []))
        println("OC - Banned Next GW")
        banned_next_gw = options["banned_next_gw"]
        @constraint(model, [p in banned_next_gw], squad[p, gameweeks[1]] == 1,base_name="ban_player_specified_gw")
    end

    if !isempty(get(options, "locked", []))
        println("OC - Locked")
        locked_players = options["locked"]
        @constraint(model, [p in locked_players, w in gameweeks], squad[p, w] + squad_fh[p, w] == 1, base_name = "lock_player")
    end

    if !isempty(get(options, "locked_next_gw", []))
        println("OC - Locked Next GW")
        locked_next_gw = options["locked_next_gw"]
        @constraint(model, [p in locked_next_gw], squad[p, gameweeks[1]] == 1, base_name = "lock_player_specified_gw")
    end

    if get(options, "no_future_transfer", false)
        println("OC - No Future Tr")
        use_wc_val = get(options, "use_wc", nothing)
        @constraint(model, sum(transfer_in[p, w] for p in players for w in gameweeks if w > next_gw && w != use_wc_val) == 0, base_name= "no_future_transfer")
    end

    if get(options, "no_transfer_last_gws", nothing) !== nothing
        println("OC - No Tr Last GW")
        no_tr_gws = options["no_transfer_last_gws"]
        if horizon > no_tr_gws
            @constraint(model,[w in gameweeks[gameweeks .> last_gw - no_tr_gws]], sum(transfer_in[p, w] for p in players) <= 15 * use_wc[w], base_name = "tr_ban_gws")
        end
    end

    if get(options, "num_transfers", nothing) !== nothing
        println("OC - Num Transfers")
        @constraint(model, sum(transfer_in[p, next_gw] for p in players) == options["num_transfers"], base_name="tr limit")
    end


    if get(options, "hit_limit", nothing) !== nothing
        println("OC - Hit Limit")
        @constraint(model, sum(penalized_transfers[w] for w in gameweeks) <= int(options["hit_limit"]), base_name = "horizon_hit_limit")
    end

    if get(options, "weekly_hit_limit", nothing) !== nothing
        println("OC - Weekly Hit Limit")
        weekly_hit_limit = parse(Int, options["weekly_hit_limit"])
        @constraint(model, gw_hit_lim[w in gameweeks], penalized_transfers[w] <= int(weekly_hit_limit), base_name ="gw_hit_lim")
    end

    # if haskey(options, "ft_custom_value") && options["ft_custom_value"] !== nothing
    #     ft_custom_value = Dict(parse(Int, key) => value for (key, value) in get(options, "ft_custom_value", Dict()))
    #     ft_gw_value = merge(Dict(gw => ft_value for gw in gameweeks), ft_custom_value)
    # end

    if get(options, "future_transfer_limit", nothing) !== nothing
        println("OC - Future Transfer Limit")
        @constraint(model, 
            sum(transfer_in[p,w] for p in players for w in gameweeks if w > next_gw && w != get(options, "use_wc", 0)) <= options["future_transfer_limit"],
        base_name = "future_tr_limit")
    end

    if !isempty(get(options, "no_transfer_gws", []))
        println("OC - No Transfer GWs")
        if length(options["no_transfer_gws"]) > 0
            @constraint(model, sum(transfer_in[p, w] for p in players for w in options["no_transfer_gws"]) == 0, base_name = "banned_gws_for_tr")
        end
    end

    if !isempty(get(options, "no_transfer_by_position", []))
        println("OC - No Transfer By Position")
        if length(options["no_transfer_by_position"]) > 0
            # ignore w=1 as you must transfer in a full squad
            @constraint(model, 
                [p in players, w in gameweeks; w > 1 && merged_data[playerinex[p], :Pos] in options["no_transfer_by_position"]],
                transfer_in[p,w] <= use_wc[w], base_name="no_tr_by_pos"     
            )
        end
    end

    max_defs_per_team = get(options, "max_defenders_per_team", 3)

    if max_defs_per_team < 3  # only add constraints if necessary
        println("OC - Max Defs Per Team")
        # Constraint for regular squad
        @constraint(model, 
            [t in teams, w in gameweeks],
            sum(squad[p,w] for p in players if player_team[p] == t && merged_data[playerinex[p], :Pos] in ["G", "D"]) <= max_defs_per_team,
            base_name="defenders_per_team_limit"
        )
        
        # Constraint for free hit squad
        @constraint(model, 
            [t in teams, w in gameweeks],
            sum(squad_fh[p,w] for p in players if player_team[p] == t && merged_data[playerinex[p], :Pos] in ["G", "D"]) <= max_defs_per_team * use_fh[w],
            base_name="defenders_per_team_limit_fh"
        )
    end

    btprinted = false
    for booked_transfer in booked_transfers
        if !btprinted
            prtinln("OC - Booked Transfers")
            btprinted = true
        end

        transfer_gw = get(booked_transfer, "gw", nothing)

        if transfer_gw === nothing
            continue
        end

        player_in = get(booked_transfer, "transfer_in", nothing)
        player_out = get(booked_transfer, "transfer_out", nothing)

        if player_in !== nothing
            @constraint(model, transfer_in[player_in, transfer_gw] == 1)
        end
        if player_out !== nothing
            @constraint(model, transfer_out[player_out, transfer_gw] == 1)
        end
    end

    # No opposing play
    cp_penalty = Dict()
    if get(options, "no_opposing_play", false) == true
        println("OC - No Opposing Play")
        gw_opp_teams = Dict(w => [(f["home"], f["away"]) for f in fixtures if f["gw"] == w] ∪ 
                         [(f["away"], f["home"]) for f in fixtures if f["gw"] == w] for w in gameweeks)
        for gw in gameweeks
            gw_games = [i for i in fixtures if i["gw"] == gw]
            if get(options,"opposing_play_group", "all") == "all"
                opposing_players = [(p1, p2) for p1 in players for p2 in players if (player_team[p1], player_team[p2]) in gw_opp_teams[gw]]
                @constraint(model, [(p1, p2) in opposing_players], lineup[p1, gw] + lineup[p2, gw] <= 1,base_name = "no_opp_$(gw)")
            elseif get(options, "opposing_play_group", nothing) == "position"
                opposing_positions = [(1,3), (1,4), (2,3), (2,4), (3,1), (4,1), (3,2), (4,2)]  # gk vs mid, gk vs fwd, def vs mid, def vs fwd
                opposing_players = [(p1, p2) for p1 in players for p2 in players
                    if (player_team[p1], player_team[p2]) in gw_opp_teams[gw] && 
                       (player_type[p1], player_type[p2]) in opposing_positions]
                opposing_players = [(p1, p2) for f in gw_games for p1 in players if player_team[p1] == f["home"] for p2 in players if player_team[p2] == f["away"] && (player_type[p1], player_type[p2]) in opposing_positions]
                @constraint(model, [(p1, p2) in opposing_players], lineup[p1, gw] + lineup[p2, gw] <= 1,base_name = "no_opp_$(gw)")
            end
        end
    elseif get(options, "no_opposing_play", nothing) == "penalty"
        println("OC - Penalty Opposing Play")
        gw_opp_teams = Dict(w => [(f["home"], f["away"]) for f in fixtures if f["gw"] == w] ∪ 
                                [(f["away"], f["home"]) for f in fixtures if f["gw"] == w] for w in gameweeks)
        
        if get(options, "opposing_play_group", nothing) == "all"
            cp_list = [(p1, p2, w)
                for p1 in players
                for p2 in players
                for w in gameweeks
                if (player_team[p1], player_team[p2]) in gw_opp_teams[w] &&
                minutes_player_week[p1,w] > 0 && minutes_player_week[p2,w] > 0
            ]
        elseif get(options, "opposing_play_group", "position") == "position"
            opposing_positions = [(1,3),(1,4),(2,3),(2,4),(3,1),(4,1),(3,2),(4,2)]
            cp_list = [
                (p1, p2, w)
                for p1 in players
                for p2 in players
                for w in gameweeks
                if (player_team[p1], player_team[p2]) in gw_opp_teams[w] &&
                   minutes_player_week[p1,w] > 0 && minutes_player_week[p2,w] > 0 &&
                   (player_type[p1], player_type[p2]) in opposing_positions
            ]
        end
        
        @variable(model, cp_pen_var[cp_list], Bin)
        opposing_play_penalty = get(options, "opposing_play_penalty", 0.5)
        cp_penalty = Dict(w => opposing_play_penalty * sum(cp_pen_var[(p1,p2,w1)] for (p1,p2,w1) in cp_list if w1 == w) for w in gameweeks)

        @constraint(model, [t in cp_list], lineup[t[1],t[3]] + lineup[t[2],t[3]] <= 1 + cp_pen_var[t])
        @constraint(model, [t in cp_list], cp_pen_var[t] <= lineup[t[1],t[3]])
        @constraint(model, [t in cp_list], cp_pen_var[t] <= lineup[t[2],t[3]])
    end

    if get(options, "double_defense_pick", false)
        println("OC - Double Defense Pick")

        team_players = Dict(t => [p for p in players if player_team[p] == t] for t in teams)
        gk_df_players = Dict(t => [p for p in team_players[t] if player_type[p] == 1 || player_type[p] == 2] for t in teams)
        weekly_sum = Dict((t,w) => sum(lineup[p,w] for p in gk_df_players[t]) for t in teams, w in gameweeks)
        
        @variable(model, def_aux[teams, gameweeks], binary=true)
        @constraint(model, [(t,w) in keys(weekly_sum)], weekly_sum[t,w] <= 3 * def_aux[t,w])
        @constraint(model, [(t,w) in keys(weekly_sum)], weekly_sum[t,w] >= 2 - 3 * (1 - def_aux[t,w]))
    end    
    

    # Pick prices
    if get(options, "pick_prices", nothing) ∉ [nothing, Dict("G" => "", "D" => "", "M" => "", "F" => "")]
        println("OC - Pick Prices")
        buffer = 0.2
        price_choices = options["pick_prices"]
        for (pos, val) in price_choices
            if val == ""
                continue
            end
            price_points = parse.(Float64, split(val, ","))
            value_dict = Dict(i => count(j -> j == i, price_points) for i in Set(price_points))
            con_iter = 0
            for (key, count) in value_dict
                target_players = [p for p in players if merged_data[playerinex[p], "Pos"] == pos && buy_price[p] >= key - buffer && buy_price[p] <= key + buffer]
                @constraint(model, [w in gameweeks] ,sum(squad[p, w] for p in target_players) >= count)
                con_iter += 1
            end
        end
    end

    # No GK rotation after
    if get(options, "no_gk_rotation_after", nothing) !== nothing
        println("OC - No GK Rotation")
        target_gw = parse(Int, options["no_gk_rotation_after"])
        players_gk = [p for p in players if player_type[p] == 1]
        for p in players_gk
            @constraint(model, [w in gameweeks[gameweeks .> target_gw]], lineup[p, w] >= lineup[p, target_gw] - use_fh[w])
        end
    end

    # No chip in specific gameweeks
    if length(get(options,"no_chip_gws",[])) > 0
        println("OC - No Chip GWs")
        no_chip_gws = options["no_chip_gws"]
        @constraint(model, sum(use_bb[w] + use_wc[w] + use_fh[w] for w in no_chip_gws) == 0)
    end

    # Only booked transfers
    if get(options, "only_booked_transfers", false)
        println("OC - Only Booked Transfers")
        forced_in = []
        forced_out = []
        for bt in get(options, "booked_transfers", [])
            if bt["gw"] == next_gw
                if haskey(bt, "transfer_in")
                    push!(forced_in, bt["transfer_in"])
                end
                if haskey(bt, "transfer_out")
                    push!(forced_out, bt["transfer_out"])
                end
            end
        end
        in_players = Dict(p => (p in forced_in ? 1 : 0) for p in players)
        out_players = Dict(p => (p in forced_out ? 1 : 0) for p in players)
        @constraint(model, [p in players], transfer_in[p, next_gw] == in_players[p])
        @constraint(model, [p in players], transfer_out[p, next_gw] == out_players[p])
    end

    # # Have 2 free transfers in specific gameweeks
    # if haskey(options, "have_2ft_in_gws")
    #     for gw in options["have_2ft_in_gws"]
    #         @constraint(model, free_transfers[gw] == 2)
    #     end
    # end
    if !isempty(get(options,"force_ft_state_lb", []))
        println("OC - Force FT State LB")
        for (gw, ft_pos) in options["force_ft_state_lb"]
            @constraint(model, free_transfers[gw] >= ft_pos, base_name="cft_lb_$(gw)")
        end
    end
    
    if !isempty(get(options,"force_ft_state_ub",[]))
        println("OC - Force FT State UB")
        for (gw, ft_pos) in options["force_ft_state_ub"]
            @constraint(model, free_transfers[gw] <= ft_pos, base_name="cft_ub_$(gw)")
        end
    end

    # No transfers except wildcard
    if get(options, "no_trs_except_wc", false)
        println("OC - No Trs Except WC")
        @constraint(model, [w in gameweeks], number_of_transfers[w] <= 15 * use_wc[w])
    end

    # FT gain
    ft_state_value = Dict()
    for s in ft_states
        ft_state_value[s] = get(ft_state_value, s-1, 0) + get(ft_value_list, string(s), ft_value)
    end
    println("Using FT state values of $(sort(collect(ft_state_value)))")

    gw_ft_value = Dict(w => sum(ft_state_value[s] * free_transfers_state[w,s] for s in ft_states) for w in gameweeks)
    gw_ft_gain = Dict(w => gw_ft_value[w] - get(gw_ft_value, w-1, 0) for w in gameweeks)



    # Objectives
    hit_cost = get(options,"hit_cost", 4) 
    gw_xp = Dict(w => sum(points_player_week[p, w] * (lineup[p, w] + captain[p, w] + 0.1 * vicecap[p, w] + use_tc[p, w] + sum(bench_weights[o] * bench[p, w, o] for o in order)) for p in players) for w in gameweeks)
    gw_total = Dict(w => gw_xp[w] - hit_cost * penalized_transfers[w] + gw_ft_gain[w] - ft_penalty[w] + itb_value * in_the_bank[w] - get(cp_penalty, w, 0) for w in gameweeks)

    if objective == "regular"
        total_xp = sum(gw_total[w] for w in gameweeks)
        @objective(model, Max, total_xp)
    else
        decay_objective = sum(gw_total[w] * decay_base^(w - next_gw) for w in gameweeks)
        @objective(model, Max, decay_objective)
    end

    report_decay_base = get(options, "report_decay_base", [])
    decay_metrics = Dict(i => sum(gw_total[w] * i^(w - next_gw) for w in gameweeks) for i in report_decay_base)

    iteration = get(options, "iteration", 1)
    iteration_criteria = get(options, "iteration_criteria", "this_gw_transfer_in")
    solutions = []

    for iter in 1:iteration

        optimize!(model)
        # DataFrame generation
        column_names = ["id", "week", "name", "pos", "type", "team", "buy_price", "sell_price", "xP", "xMin", "squad", "lineup", "bench", "captain", "vicecaptain", "transfer_in", "transfer_out", "multiplier", "xp_cont", "chip", "ITB","iter"]
        picks_df = DataFrame([name => [] for name in column_names])

        for w in gameweeks
            for p in players
                if value(squad[p,w]) + value(squad_fh[p,w]) + value(transfer_out[p,w]) > 0.5
                    lp = merged_data[playerinex[p], :]
                    is_captain = value(captain[p,w]) > 0.5 ? 1 : 0
                    is_squad = (value(use_fh[w]) < 0.5 && value(squad[p,w]) > 0.5) || (value(use_fh[w]) > 0.5 && value(squad_fh[p,w]) > 0.5) ? 1 : 0
                    is_lineup = value(lineup[p,w]) > 0.5 ? 1 : 0
                    is_vice = value(vicecap[p,w]) > 0.5 ? 1 : 0
                    is_tc = value(use_tc[p,w]) > 0.5 ? 1 : 0
                    is_transfer_in = value(transfer_in[p,w]) > 0.5 ? 1 : 0
                    is_transfer_out = value(transfer_out[p,w]) > 0.5 ? 1 : 0
                    bench_value = -1
                    for o in order
                        if value(bench[p,w,o]) > 0.5
                            bench_value = o
                        end
                    end
                    position = type_data[lp["element_type"], "singular_name_short"]
                    player_buy_price = is_transfer_in == 0 ? 0 : buy_price[p]
                    player_sell_price = is_transfer_out == 0 ? 0 : (p in price_modified_players && value(transfer_out_first[p,w]) > 0.5 ? sell_price[p] : buy_price[p])
                    multiplier = 1 * (is_lineup == 1) + 1 * (is_captain == 1) + 1 * (is_tc == 1)
                    xp_cont = points_player_week[p,w] * multiplier
                    current_iter = iter + 1

                    # chip
                    chip_text = if value(use_wc[w]) > 0.5
                        "WC"
                    elseif value(use_fh[w]) > 0.5
                        "FH"
                    elseif value(use_bb[w]) > 0.5
                        "BB"
                    elseif value(use_tc[p, w]) > 0.5
                        "TC"    
                    else
                        ""
                    end

                    push!(picks_df, [p, w, lp["web_name"], position, lp["element_type"], lp["name"], player_buy_price, player_sell_price, round(points_player_week[p,w], digits=2), minutes_player_week[p,w], is_squad, is_lineup, bench_value, is_captain, is_vice, is_transfer_in, is_transfer_out, multiplier, xp_cont, chip_text, round(value(in_the_bank[w]),digits=2), current_iter])
                end
            end
        end
        
        # push!(picks_df,picks)
        # sort!(picks_df, [:week, :lineup, :type, :xP], rev=[false, true, false, false])
        sort!(picks_df, [:week, :squad, :lineup, :bench, :type], rev=[false, true, true, false, false])
        total_xp = sum((value(lineup[p,w]) + value(captain[p,w])) * points_player_week[p,w] for p in players, w in gameweeks)

        

        # Writing summary
        summary_of_actions = ""
        move_summary = Dict("chip" => [],"buy" => [], "sell" => [])
        cumulative_xpts = 0

        lineup_players =[]
        bench_players = []
        for w in gameweeks
            summary_of_actions *= "** GW $w:\n"
            chip_decision = (value(use_wc[w]) > 0.5 ? "WC" : "") * (value(use_fh[w]) > 0.5 ? "FH" : "") * (value(use_bb[w]) > 0.5 ? "BB" : "") * (value(use_tc_gw[w]) > 0.5 ? "TC" : "")
            if chip_decision != ""
                summary_of_actions *= "CHIP $chip_decision\n"
                push!(move_summary["chip"], chip_decision * string(w))
            end
            summary_of_actions *= "ITB=$(round(value(in_the_bank[w]),digits=2)), FT=$(value(free_transfers[w])), PT=$(value(penalized_transfers[w])), NT=$(value(number_of_transfers[w]))\n"
            
            for p in players
                if value(transfer_in[p,w]) > 0.5
                    summary_of_actions *= "Buy $p - $(merged_data[playerinex[p], "web_name"])\n"
                    if w == next_gw
                        push!(move_summary["buy"], merged_data[playerinex[p], "web_name"])
                    end
                end
                if value(transfer_out[p,w]) > 0.5
                    summary_of_actions *= "Sell $p - $(merged_data[playerinex[p], "web_name"])\n"
                    if w == next_gw
                        push!(move_summary["sell"], merged_data[playerinex[p], "web_name"])
                    end
                end
            end
            
            lineup_players = filter(row -> row[:week] == w && row[:lineup] == 1, picks_df)
            bench_players = filter(row -> row[:week] == w && row[:bench] >= 0, picks_df)
            

            summary_of_actions *= "---\nLineup: \n"

            function get_display(row)
                return "$(row[:name]) ($(row[:xP])$(row[:captain] == 1 ? ", C" : "")$(row[:vicecaptain] == 1 ? ", V" : ""))"
            end

            for type in [1,2,3,4]
                type_players = filter(r -> r[:type] == type, lineup_players)
                entries = get_display.(eachrow(type_players))
                summary_of_actions *= "\t" * join(entries, ", ") * "\n"
            end
            summary_of_actions *= "Bench: \n\t" * join(bench_players[!,:name], ", ") * "\n"
            summary_of_actions *= "Lineup xPts: " * string(round(sum(lineup_players[!,:xp_cont]), digits=2)) * "\n---\n\n"

            cumulative_xpts += round(sum(lineup_players[!,:xp_cont]), digits=2)
        end

       

        println("Cumulative xPts: ", round(cumulative_xpts, digits=2), "\n---\n\n")

        buy_decisions = join(move_summary["buy"], ", ")
        sell_decisions = join(move_summary["sell"], ", ")
        chip_decisions = join(move_summary["chip"], ", ")
        if buy_decisions == ""
            buy_decisions = "-"
        end
        if sell_decisions == ""
            sell_decisions = "-"
        end
        if chip_decisions == ""
            chip_decisions = "-"
        end

        # Add current solution to a list, and add a new cut

        push!(solutions, Dict(
        "iter" => iter,
        "model" => model,
        "picks" => picks_df,
        "total_xp" => total_xp,
        "summary" => summary_of_actions,
        "buy" => buy_decisions,
        "sell" => sell_decisions,
        "chip" => chip_decisions,
        "score" => objective_value(model),
        "decay_metrics" => Dict(key => value(val) for (key, val) in decay_metrics)
        ))

        if iteration == 1
            return solutions
        end

        iter_diff = get(options,"iteration_difference",1)

        if iteration_criteria == "this_gw_transfer_in"
            actions = sum([1 - transfer_in[p, next_gw] for p in players if value(transfer_in[p, next_gw]) > 0.5]) +
                    sum([transfer_in[p, next_gw] for p in players if value(transfer_in[p, next_gw]) < 0.5])
            @constraint(model, actions >= 1)
        elseif iteration_criteria == "this_gw_transfer_out"
            actions = sum([1 - transfer_out[p, next_gw] for p in players if value(transfer_out[p, next_gw]) > 0.5]) +
                    sum([transfer_out[p, next_gw] for p in players if value(transfer_out[p, next_gw]) < 0.5])
            @constraint(model, actions >= 1)
        elseif iteration_criteria == "this_gw_transfer_in_out"
            actions = sum([1 - transfer_in[p, next_gw] for p in players if value(transfer_in[p, next_gw]) > 0.5]) +
                    sum([transfer_in[p, next_gw] for p in players if value(transfer_in[p, next_gw]) < 0.5]) +
                    sum([1 - transfer_out[p, next_gw] for p in players if value(transfer_out[p, next_gw]) > 0.5]) +
                    sum([transfer_out[p, next_gw] for p in players if value(transfer_out[p, next_gw]) < 0.5])
            @constraint(model, actions >= 1)
        elseif iteration_criteria == "chip_gws"
            actions = sum([1 - use_wc[w] for w in gameweeks if value(use_wc[w]) > 0.5]) +
                    sum([use_wc[w] for w in gameweeks if value(use_wc[w]) < 0.5]) +
                    sum([1 - use_bb[w] for w in gameweeks if value(use_bb[w]) > 0.5]) +
                    sum([use_bb[w] for w in gameweeks if value(use_bb[w]) < 0.5]) +
                    sum([1 - use_fh[w] for w in gameweeks if value(use_fh[w]) > 0.5]) +
                    sum([use_fh[w] for w in gameweeks if value(use_fh[w]) < 0.5])

            @constraint(model, actions >= 1)
        elseif iteration_criteria == "horizon-buy-sell"
            actions = sum(1 - transfer_in[p, w] for p in players, w in gameweeks if value(transfer_in[p, w]) > 0.5) +
                        sum(transfer_in[p, w] for p in players, w in gameweeks if value(transfer_in[p, w]) < 0.5) +
                        sum(1 - transfer_out[p, w] for p in players, w in gameweeks if value(transfer_out[p, w]) > 0.5) +
                        sum(transfer_out[p, w] for p in players, w in gameweeks if value(transfer_out[p, w]) < 0.5)
        
            @constraint(model, actions >= 1)
        elseif iteration_criteria == "target_gws_transfer_in"
            target_gws = get(options, "iteration_target", [next_gw])
            transferred_players = [(p, w) for p in players for w in target_gws if value(transfer_in[p,w]) > 0.5]
            remaining_players = [(p, w) for p in players for w in target_gws if value(transfer_in[p,w]) < 0.5]
            actions = sum([1 - transfer_in[p,w] for (p, w) in transferred_players]) +
                    sum([transfer_in[p,w] for (p, w) in remaining_players])
            @constraint(model, actions >= 1)
        elseif iteration_criteria == "this_gw_lineup"
            selected_lineup = [p for p in players if lineup[p,next_gw].value > 0.5]
            @constraint(model, sum(lineup[p, next_gw] for p in selected_lineup) <= length(selected_lineup) - iter_diff, base_name="cutoff_$iter")
        elseif iteration_criteria == "chip_combinations"
            current_chips = get(chip_combinations, iter + 1, nothing)
            isnothing(current_chips) && return
    
            pairs = [
                (:wc, use_wc),
                (:fh, use_fh),
                (:bb, use_bb),
                (:tc, use_tc_gw)
            ]
    
            for (chip, variable) in pairs
                constraint_name = Symbol("cc_$chip")
                
                if haskey(model, constraint_name)
                    delete(model, model[constraint_name])
                end
    
                if haskey(current_chips, chip)
                    @constraint(model, variable[current_chips[chip]] == 1, base_name=constraint_name)
                    options[:chip_limits][chip] = 1
                else
                    @constraint(model, sum(variable[w] for w in gameweeks) == 0, base_name=constraint_name)
                    options[:chip_limits][chip] = 0
                end
            end
        end

    end

    return solutions

end






