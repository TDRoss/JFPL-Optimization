using JuMP, SCIP, Juniper

function team_selector(points, position; verbose = true)

    TEAM_POSITION_CONSTRAINTS = [(1,1), (3,5), (2,5), (1,3)]
    
    positions_onehot = map(x-> Int.(position .== x), 1:4)
    
    model = Model(SCIP.Optimizer)
    
    @variable(model, team[1:length(points)], Bin)
    @variable(model, captain[1:length(points)], Bin)
        
    # Objective: maximize points
    @objective(model, Max, (points' * team) + 1*(points' * captain))
    
    #Only chose 11 players
    @constraint(model, sum(team) == 11)
    
    #Only chose 1 captain
    @constraint(model, sum(captain) == 1)
    
    #Make sure the captain is playing
    @NLconstraint(model, sum((team[i] * captain[i]) for i in 1:length(points)) == 1)
    
    #Satisfy the position constraints
    for j in 1:4
      @constraint(model, positions_onehot[j]' * team >= TEAM_POSITION_CONSTRAINTS[j][1])
      @constraint(model, positions_onehot[j]' * team <= TEAM_POSITION_CONSTRAINTS[j][2])
    end
    
    # Solve problem!
    optimize!(model)
    
    if verbose
        println("Objective is: ", objective_value(model))
    end
    Test.@test termination_status(model) == MOI.OPTIMAL
    Test.@test primal_status(model) == MOI.FEASIBLE_POINT


    results = Array{Dict{String, Any}}(undef, result_count(model))
    for i in 1:result_count(model)
      results[i] = Dict("Team" => value.(team; result = i),
                        "Captain" => value.(captain; result = i),
                        "ExpPoints" => objective_value(model; result = i))
    end

    return model, results
end


function squad_selector(points, cost, position, teams, subweights, verbose = true)

    positions_onehot = map(x-> Int.(position .== x), 1:4)
    teams_onehot = map(x-> Int.(teams .== x), 1:20)
    
    budget = 1000

    model = Model(SCIP.Optimizer)

    @variable(model, squad[1:length(points)], Bin)
    @variable(model, team[1:length(points)], Bin)
    @variable(model, captain[1:length(points)], Bin)
        
    # Objective: maximize points 

    @objective(model, Max, (points' * team) + 
                            1 * (points' * captain) +
                            subweights * ((points' * squad) - (points' * team)))

    # Constraint: total cost within budget
    @constraint(model, (cost' * squad) <= budget)
    
    # Constraint: only chose TEAMSIZE players
    @constraint(model, sum(squad) == 15)
    @constraint(model, sum(team) == 11)
    @constraint(model, sum(captain) == 1)
    
    # Non linear constraint: make sure the team is from the squad and the captain is in the team
    @NLconstraint(model, sum((squad[i] * team[i]) for i in 1:length(points)) == 11)
    @NLconstraint(model, sum((team[i] * captain[i]) for i in 1:length(points)) == 1)
    
    # Constraint: No more than three players from one team    
    for t in 1:20
        @constraint(model, (teams_onehot[t]' * squad) <= 3)
    end
    
    # Satisfy the position constraints
    SQUAD_POSITION_CONSTRAINTS = [2, 5, 5, 3]
    TEAM_POSITION_CONSTRAINTS = [(1,1), (3,5), (2,5), (1,3)]
    for j in 1:4
      @constraint(model, positions_onehot[j]' * squad == SQUAD_POSITION_CONSTRAINTS[j])
      @constraint(model, positions_onehot[j]' * team >= TEAM_POSITION_CONSTRAINTS[j][1])
      @constraint(model, positions_onehot[j]' * team <= TEAM_POSITION_CONSTRAINTS[j][2])
    end
    
    # Solve problem!
    optimize!(model)
    
    if verbose
        println("Objective is: ", objective_value(model))
    end
    #Test.@test termination_status(model) == MOI.OPTIMAL
    #Test.@test primal_status(model) == MOI.FEASIBLE_POINT
    println(termination_status(model))
    println(primal_status(model))

    results = Array{Dict{String, Any}}(undef, result_count(model))
    for i in 1:result_count(model)
      results[i] = Dict("Team" => value.(team; result = i),
                        "Captain" => value.(captain; result = i),
                        "ExpPoints" => objective_value(model; result = i),
                        "Squad" => value.(squad; result = i))
    end

    return model, results
end

function transfer_test(points, cost, position, teams, subweights, currentSquad, ntransfers, verbose = true)

    positions_onehot = map(x-> Int.(position .== x), 1:4)
    teams_onehot = map(x-> Int.(teams .== x), 1:20)
    
    budget = 1000

    model = Model(SCIP.Optimizer)

    @variable(model, squad[1:length(points)], Bin)
    @variable(model, team[1:length(points)], Bin)
    @variable(model, captain[1:length(points)], Bin)
        
    # Objective: maximize points 

    @objective(model, Max, (points' * team) + 
                            1 * (points' * captain) +
                            0.1 * ((points' * squad) - (points' * team)))

    # Constraint: total cost within budget
    @constraint(model, (cost' * squad) <= budget)
    
    # Constraint: only chose TEAMSIZE players
    @constraint(model, sum(squad) == 15)
    @constraint(model, sum(team) == 11)
    @constraint(model, sum(captain) == 1)
    @constraint(model, 15 - (currentSquad' * squad) <= ntransfers)
    
    # Non linear constraint: make sure the team is from the squad and the captain is in the team
    @NLconstraint(model, sum((squad[i] * team[i]) for i in 1:length(points)) == 11)
    @NLconstraint(model, sum((team[i] * captain[i]) for i in 1:length(points)) == 1)
    
    # Constraint: No more than three players from one team    
    for t in 1:20
        @constraint(model, (teams_onehot[t]' * squad) <= 3)
    end
    
    # Satisfy the position constraints
    SQUAD_POSITION_CONSTRAINTS = [2, 5, 5, 3]
    TEAM_POSITION_CONSTRAINTS = [(1,1), (3,5), (2,5), (1,3)]
    for j in 1:4
      @constraint(model, positions_onehot[j]' * squad == SQUAD_POSITION_CONSTRAINTS[j])
      @constraint(model, positions_onehot[j]' * team >= TEAM_POSITION_CONSTRAINTS[j][1])
      @constraint(model, positions_onehot[j]' * team <= TEAM_POSITION_CONSTRAINTS[j][2])
    end
    
    # Solve problem!
    optimize!(model)
    
    if verbose
        println("Objective is: ", objective_value(model))
    end
    #Test.@test termination_status(model) == MOI.OPTIMAL
    #Test.@test primal_status(model) == MOI.FEASIBLE_POINT
    println(termination_status(model))
    println(primal_status(model))

    results = Array{Dict{String, Any}}(undef, result_count(model))
    for i in 1:result_count(model)
      results[i] = Dict("Team" => value.(team; result = i),
                        "Captain" => value.(captain; result = i),
                        "ExpPoints" => objective_value(model; result = i),
                        "Squad" => value.(squad; result = i))
    end

    return model, results


    
end
