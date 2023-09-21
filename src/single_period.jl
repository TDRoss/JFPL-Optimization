using CSV, DataFrames, JuMP, SCIP, HTTP, JSON, Profile

function get_data()
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
    return merged_data, team_data, type_data, next_gw
end

function solve_single_period_fpl(merged_data, team_data, type_data, next_gw ,budget)
    teams = team_data[:,:name]
	nplayers = length(merged_data[:,:id])


    model = Model(SCIP.Optimizer)
	set_silent(model)
	element_types = type_data[:,:id]
	
    @variable(model,squad[1:nplayers],Bin)
	@variable(model,lineup[1:nplayers],Bin)
	@variable(model,captain[1:nplayers],Bin)
	@variable(model,vicecap[1:nplayers],Bin)

	@constraint(model, sum(squad) == 15)
	@constraint(model, sum(lineup) == 11)
	@constraint(model, sum(captain) == 1)
	@constraint(model, sum(vicecap) == 1)
	@constraint(model, lineup .<= squad)
	@constraint(model, captain .<= lineup)
	@constraint(model, vicecap .<= lineup)
	@constraint(model, captain .+ vicecap .<= 1)
    lineup_type_count = 	Dict(t => sum(lineup[p] for p in 1:nplayers if merged_data[p,:element_type] == t) for t in element_types)
	squad_type_count = 	Dict(t => sum(squad[p] for p in 1:nplayers if merged_data[p,:element_type] == t) for t in element_types)
    for t in element_types
        @constraint(model, type_data[t,:squad_min_play] <= lineup_type_count[t] <= type_data[t,:squad_max_play])
        @constraint(model, squad_type_count[t] == type_data[t,:squad_select])
    end
    price = sum(merged_data[:,:now_cost].*squad./10)
    @constraint(model,price<=budget)
    for t in teams
        @constraint(model, sum(squad.*(merged_data[:,"name"] .== t)) <=3)
    end
    total_points = sum(merged_data[:,"$(next_gw)_Pts"] .* (lineup .+ captain .+ 0.1.*vicecap))
    @objective(model,Max,total_points)
    optimize!(model)
    optlineup = (1:nplayers)[(value.(lineup)) .> 0.5]
	optsquad = (1:nplayers)[(value.(squad)).> 0.5]
	optcap = (1:nplayers)[(value.(captain)).> 0.5]
	optvicecap = (1:nplayers)[(value.(vicecap)).> 0.5]
    picks = DataFrame(name = [], pos = [], team = [], price = [], xP = [], lineup = [], captain = [], vicecap = [])
	for p in optsquad
		p == optcap[1] ? is_captain = 1 : is_captain = 0
		p == optvicecap[1] ? is_vicecap = 1 : is_vicecap = 0
		p in optlineup ? in_lineup = 1 : in_lineup = 0
				
		push!(picks,[merged_data[p,:web_name], merged_data[p,:Pos], merged_data[p,:name], merged_data[p,:now_cost]/10, merged_data[p,"$(next_gw)_Pts"], in_lineup, is_captain, is_vicecap])		
	end
	total_xp = sum((picks[:,:lineup] .+ picks[:,:captain]) .* picks[:,:xP])
    return total_xp
end


# if abspath(PROGRAM_FILE) == @__FILE__
t = @elapsed begin
	budget_range = 80:5:121
	merged_data, team_data, type_data, next_gw = get_data()
	results = DataFrame(budget=[], total_xP=[]);
	Threads.@threads for budget in budget_range
		r =  solve_single_period_fpl(merged_data, team_data, type_data, next_gw, budget)
		push!(results,[budget,r])
	end
	println(results)
end
	println(t)
# end