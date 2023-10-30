using CSV, DataFrames, JuMP, Gurobi, HTTP, JSON, Profile, Random

function get_data(team_id,gw)
	#Data
	r = HTTP.get("https://fantasy.premierleague.com/api/bootstrap-static/")
	fpl_data = JSON.Parser.parse(String(r.body))
	element_data = DataFrame(fpl_data["elements"])
	team_data = DataFrame(fpl_data["teams"])
    elements_team = outerjoin(element_data,team_data, on=:team =>:id, makeunique=true)
    review_data = CSV.read("../data/fplreview.csv",DataFrame)
    merged_data = dropmissing(outerjoin(elements_team,review_data, on= [:name => :Team, :web_name=>:Name]))
    next_gw = parse(Int64,(split(names(review_data)[7],"_")[1]))
    sort!(merged_data,:id)
	type_data = DataFrame(fpl_data["element_types"])

    r = HTTP.get("https://fantasy.premierleague.com/api/entry/$team_id/event/$gw/picks/")
    picks_data = JSON.Parser.parse(String(r.body))
    initial_squad = DataFrame(picks_data["picks"])[!,:element]
	r = HTTP.get("https://fantasy.premierleague.com/api/entry/$team_id/")
    general_data = JSON.Parser.parse(String(r.body))
    itb = general_data["last_deadline_bank"] / 10


    return merged_data, team_data, type_data, next_gw, initial_squad, itb
end

function get_transfer_history(team_id,last_gw)
    transfers = []
    for gw in last_gw:-1:1
        r = HTTP.get("https://fantasy.premierleague.com/api/entry/$team_id/event/$gw/picks/")
        res = JSON.Parser.parse(String(r.body))
        transfer = res["entry_history"]["event_transfers"]
        chip = res["active_chip"]
        push!(transfers,transfer)

        if transfer > 1 || (~isnothing(chip) && (chip != "3xc" || chip != "bboost"))
            break
        end
    end
    return transfers

end


function get_rolling(team_id,last_gw)
    transfers = get_transfer_history(team_id,last_gw)
    rolling = 0

    for transfer in reverse(transfers)
        rolling = min(max(rolling + 1 - transfer,0),1)
    end

    return rolling#, transfers[1]
end

function solve_decision_support(indata, options)
    #Data
    merged_data = indata["merged_data"]
    team_data = indata["team_data"]
    type_data = indata["type_data"]
    next_gw = indata["next_gw"]
    initial_squad = indata["initial_squad"]
    itb = indata["itb"]
    ft = indata["ft"]


    #Options
    horizon = get(option,"horizon", min(3, 38-next_gw+1))
    objective = get(option,"objective", "regular")
    decay_base = get(option,"decay_base", 0.84)
    nosols = get(option,"number_of_solutions",1)

    problem_name = "ds_h$(horizon)_$(randstring(5))"

    teams = team_data[:,:name]
	nplayers = length(merged_data[:,:id])
	gameweeks = next_gw:(next_gw+horizon)
	
    model = Model(Gurobi.Optimizer)
	# set_silent(model)
	element_types = type_data[:,:id]
	
    @variable(model,squad[1:nplayers,1:(horizon+1)],Bin)
	@variable(model,lineup[1:nplayers,1:horizon],Bin)
	@variable(model,captain[1:nplayers,1:horizon],Bin)
	@variable(model,vicecap[1:nplayers,1:horizon],Bin)
	@variable(model,transfer_in[1:nplayers,1:horizon],Bin)
	@variable(model,transfer_out[1:nplayers,1:horizon],Bin)
	@variable(model,in_the_bank[1:(horizon+1)], lower_bound = 0)
	@variable(model,free_transfers[1:(horizon+1)],Int,lower_bound = 1, upper_bound = 2)
	@variable(model,peanalized_transfers[1:horizon],Int,lower_bound = 0)
	@variable(model,aux[1:horizon],Bin)


	#Dictionaries
	lineup_type_count = collect.((sum(lineup[merged_data[:,:element_type] .== t,w]) for t in element_types) for w in 1:horizon)
	lineup_type_count = reduce(hcat,lineup_type_count)
	squad_type_count = 	collect.((sum(squad[merged_data[:,:element_type] .== t,w]) for t in element_types) for w in 1:horizon)
	squad_type_count = reduce(hcat,squad_type_count)
	player_price = merged_data[!,:now_cost]./10
	sold_amount = collect(sum(player_price .* transfer_out[:,w]) for w in 1:horizon)
	bought_amount = collect(sum(player_price .* transfer_in[:,w]) for w in 1:horizon)
	points_player_week = collect(merged_data[:,"$(w)_Pts"] for w in gameweeks)
	points_player_week = reduce(hcat,points_player_week)
	squad_count = collect(sum(squad[:,w]) for w in 1:horizon)
	number_of_transfers = collect(sum(transfer_out[:,w]) for w in 1:horizon)
	prepend!(number_of_transfers,1)
	transfer_diff = number_of_transfers .- free_transfers



	#Initial Conditions
	for p in 1:nplayers
		if p in	initial_squad
			@constraint(model,squad[p,1] == 1)
		else
			@constraint(model,squad[p,1] == 0)
		end
	end
	# @constraint(model, squad[initial_squad,1] .== 1)
	# @constraint(model, squad[(1:nplayers)[1:nplayers .∉	Ref(initial_squad)] ,1] .== 0)
	@constraint(model, in_the_bank[1] == itb)
	@constraint(model, free_transfers[1] == ft)
	@constraint(model, squad_count .== 15)


	#Constraints
	for w in 1:horizon
		@constraint(model,sum(lineup[:,w]) == 11)
		@constraint(model,sum(captain[:,w]) == 1)
		@constraint(model,sum(vicecap[:,w]) == 1)
		@constraint(model,lineup[:,w] .<= squad[:,w])
		@constraint(model,captain[:,w] .<= lineup[:,w])
		@constraint(model,vicecap[:,w] .<= lineup[:,w])
		@constraint(model,captain[:,w] .+ vicecap[:,w] .<= 1)
	

		for t in element_types
			@constraint(model, type_data[t,:squad_min_play] <= lineup_type_count[t,w] <= type_data[t,:squad_max_play])
			@constraint(model, squad_type_count[t,w] == type_data[t,:squad_select])
		end
		for t in teams
			@constraint(model, sum(squad[:,w+1].*(merged_data[:,"name"] .== t)) <=3)
		end
		##Transfer Constraints
		@constraint(model, squad[:,w+1] .== squad[:,w] .+ transfer_in[:,w] .- transfer_out[:,w])
		@constraint(model, in_the_bank[w+1] .== in_the_bank[w] .+ sold_amount[w] .- bought_amount[w])
	end
	#Free Transfer Constraints
	@constraint(model, free_transfers[2:end] .== aux .+ 1)
	@constraint(model, free_transfers[1:end-1] .- number_of_transfers[1:end-1] .<= 2 .* aux)
	@constraint(model, free_transfers[1:end-1] .- number_of_transfers[1:end-1] .>= aux .- 14 .* (1 .- aux))
	@constraint(model, peanalized_transfers .>= transfer_diff[2:end])


	gw_xp = collect(sum(points_player_week[:,w] .* (lineup[:,w] .+ captain[:,w] .+ 0.1 .* vicecap[:,w])) for w in 1:horizon)
	gw_total = gw_xp .- 4 .* peanalized_transfers

	if objective == "regular"
		regular_objective = sum(gw_total)
		@objective(model,Max,regular_objective)
	else
		decay_objective = sum(gw_total .* decay_base .^ (0:horizon-1))
		@objective(model,Max,decay_objective)
	end


    results = []

    for it in range(nosols)

        optimize!(model)

        nodenames = ["gameweek", "name", "pos", "type" ,"team", "price", "xP", "lineup", "captain", "vicecap", "transfer_in", "transfer_out"]
        picks = DataFrame([name => [] for name in nodenames])
        for w in 1:horizon
            optlineup = (1:nplayers)[(value.(lineup)[:,w]) .> 0.5]
            optsquad = (1:nplayers)[(value.(squad)[:,w]).> 0.5]
            optcap = (1:nplayers)[(value.(captain)[:,w]).> 0.5]
            optvicecap = (1:nplayers)[(value.(vicecap)[:,w]).> 0.5]
            for p in round.(Int,optsquad .+ value.(transfer_out)[w])
                p == optcap[1] ? is_captain = 1 : is_captain = 0
                p == optvicecap[1] ? is_vicecap = 1 : is_vicecap = 0
                p in optlineup ? in_lineup = 1 : in_lineup = 0
                p in value.(transfer_in)[:,w] ? is_transfer_in = 1 : is_transfer_in = 0
                p in value.(transfer_out)[:,w] ? is_transfer_out = 1 : is_transfer_out = 0
                push!(picks,[gameweeks[w], merged_data[p,:web_name], merged_data[p,:Pos], merged_data[p,:element_type],merged_data[p,:name], player_price[p], round(points_player_week[p,w],digits=2), in_lineup, is_captain, is_vicecap, is_transfer_in, is_transfer_out])		
            end
        end
        sort!(picks,[:gameweek, :lineup, :type, :xP], rev=[false, true, false, false])
        total_xp = sum((picks[:,:lineup] .+ picks[:,:captain]) .* picks[:,:xP])

        summary_of_actions = ""
        for w in 1:horizon
            summary_of_actions *= "** GW$(gameweeks[w]):\n"
            summary_of_actions *= "ITB = $(round(value.(in_the_bank)[w],digits=2)), FT = $(value.(free_transfers)[w]), PT = $(value.(peanalized_transfers)[w])\n"
            
            for p in 1:nplayers
                if value.(transfer_in)[p,w] >= 0.5
                    summary_of_actions *= "Buy $p - $(merged_data[p,:web_name])\n"
                end
                if value.(transfer_out)[p,w] >= 0.5
                    summary_of_actions *= "Sell $p - $(merged_data[p,:web_name])\n"
                end
                
            end
        end
        
    end

    return picks, total_xp, summary_of_actions
end


# if abspath(PROGRAM_FILE) == @__FILE__
gw = 7
team_id = 2949515
ft = get_transfer_history(team_id,gw) + 1
merged_data, team_data, type_data, next_gw, initial_squad, itb = get_data(team_id,gw-1)
indata = Dict("merged_data" => merged_data, "team_data" => team_data, "type_data" => type_data, "next_gw" => next_gw, "initial_squad" => initial_squad, "itb"=>itb, "ft"=>ft)
optdata = Dict( horizon, objective ="regular", decay_base=0.84)
picks, total_xp, summary_of_actions =  solve_multi_period_fpl(indata, 4, "decay")

print(picks)
print(summary_of_actions)
CSV.write("optimal_plan_decay.csv", picks)

# t = @elapsed begin
# 	budget_range = 80:5:121
# 	merged_data, team_data, type_data, next_gw = get_data(team_id,gw-1)
# 	results = DataFrame(budget=[], total_xP=[]);
# 	Threads.@threads for budget in budget_range
# 		r =  solve_single_period_fpl(merged_data, team_data, type_data, next_gw, budget)
# 		push!(results,[budget,r])
# 	end
# 	println(results)
# end
# 	println(t)
# end