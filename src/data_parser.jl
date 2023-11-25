using HTTP, CSV, DataFrames, JSON, Unicode, StringDistances

function token_set_ratio(s1::String, s2::String)
    tokens1 = unique(split(lowercase(s1)))
    tokens2 = unique(split(lowercase(s2)))
    
    intersection = intersect(tokens1, tokens2)
    combined = union(tokens1, tokens2)
    
    ratio = length(intersection) / length(combined)
    
    return round(ratio * 100)  # Multiply by 100 to get percentage similarity
end

function read_data(options, source; weights=nothing)
    if source == "review"
        data = CSV.File(get(options, "data_path", "../data/fplreview.csv")) |> DataFrame
        data[!,:review_id] = data[!,:ID]
        return data
    elseif source == "review-odds"
        data = CSV.File(get(options, "data_path", "../data/fplreview-odds.csv")) |> DataFrame
        data[!,:review_id] = data[!,:ID]
        return data
    elseif source == "kiwi"
        kiwi_data = CSV.File(get(options, "kiwi_data_path", "../data/kiwi.csv")) |> DataFrame
        kiwi_data[!,:review_id] = kiwi_data[!,:ID]
        return rename_kiwi_columns(kiwi_data)
    elseif source == "mikkel"
        convert_mikkel_to_review(get(options, "mikkel_data_path", "../data/TransferAlgorithm.csv")) # assuming convert_mikkel_to_review is defined
        data = CSV.File("../data/mikkel.csv") |> DataFrame
        data[!,:ID] = data[!,:review_id]
        return data
    elseif source == "mixed"
        all_data = []
        for (name, weight) in weights
            if weight == 0
                continue
            end
            df = read_data(options, name) 
    
            # Drop players without data
            first_gw_col = findfirst(c -> occursin("_Pts", c), names(df))
    
            # Drop missing ones
            df = df[.!ismissing.(df[:, first_gw_col]), :]
    
            # Add weight columns
            for col in filter(c -> occursin("_Pts", c), names(df))
                df[!, split(col, '_')[1] * "_weight"] .= weight
            end
    
            push!(all_data, df)
        end
    end

    # Update EV by weight
    new_data = []
    for d in all_data
        # Find the columns that end with '_Pts'
        pts_columns = [i for i in names(d) if occursin("_Pts", i)]
        # Find the columns that end with '_xMins'
        min_columns = [i for i in names(d) if occursin("_xMins", i)]
    
        # Generate weights columns for points
        weights_cols = [split(i, '_')[1] * "_weight" for i in pts_columns]
        # Element-wise multiplication
        for col in pts_columns
            d[!, col] = d[!, col] .* d[!, Symbol(weights_cols[findfirst(==(col), pts_columns)])]
        end
    
        # Generate weights columns for minutes
        weights_cols = [split(i, '_')[1] * "_weight" for i in min_columns]
        # Element-wise multiplication
        for col in min_columns
            d[!, col] = d[!, col] .* d[!, Symbol(weights_cols[findfirst(==(col), min_columns)])]
        end
    
        push!(new_data, copy(d))
    end

    combined_data = vcat(new_data...)
    combined_data[!,:real_id] = combined_data[!,:review_id]

    key_dict = Dict()
    for i in names(combined_data)
        if occursin("_weight", String(i))
            key_dict[i] = sum
        elseif occursin("_xMins", String(i)) || occursin("_Pts", String(i))
            key_dict[i] = sum
        else
            key_dict[i] = first
        end
    end

    key_exprs = [(Symbol(key) => value => Symbol(key)) for (key, value) in key_dict]
    grouped_data = combine(groupby(combined_data, :real_id), key_exprs...)
    final_data = grouped_data[grouped_data[!,:review_id] .!= 0, :]

    # adjust by weight sum for each player
    for c in names(final_data)
        if occursin("_Pts", String(c)) || occursin("_xMins", String(c))
            gw = split(String(c), "_")[1]
            final_data[:, c] .= final_data[:, c] ./ final_data[:, Symbol(gw * "_weight")]
        end
    end
    
    
    r = HTTP.get("https://fantasy.premierleague.com/api/bootstrap-static/")
    sitedata = JSON.parse(String(r.body))
    players_data = sitedata["elements"]
    existing_ids = final_data[!, "review_id"]
    element_type_dict = Dict(1 => 'G', 2 => 'D', 3 => 'M', 4 => 'F')
    teams_data = sitedata["teams"]
    team_code_dict = Dict()
    for team in teams_data
        team_code_dict[team["code"]] = team
    end

    missing_players = DataFrame()
    
    for p in players_data
        if p["id"] in existing_ids
            continue
        end
        push!(missing_players, 
            (fpl_id = p["id"], 
             review_id = p["id"], 
             ID = p["id"], 
             real_id = p["id"], 
             team = "",
             Name = p["web_name"], 
             Pos = element_type_dict[p["element_type"]], 
             Value = p["now_cost"] / 10, 
             Team = team_code_dict[p["team_code"]]["name"], 
             Missing = 1)
        )
    end
    
    final_data = vcat(final_data, missing_players)
    for col in names(final_data)
        if !(col in names(missing_players))
            final_data[!, col] .= coalesce.(final_data[!, col], 0)
        end
    end
    
    return final_data
end

function fix_name_dialect(name::String)
    new_name = join([c for c in Unicode.normalize(name, stripmark=true)])
    new_name = replace(new_name, "Ø" => "O")
    new_name = replace(new_name, "ø" => "o")
    return replace(new_name, "ã" => "a")
end

function get_best_score(r::Dict{String, Int})
    return max(r["wn_score"], r["cn_score"])
end


function fix_mikkel(file_address::String)
    df = CSV.File(file_address; encoding="latin1") |> DataFrame
    # Fix column names
    rename!(df, strip.(names(df)))
    
    r = HTTP.get("https://fantasy.premierleague.com/api/bootstrap-static/")
    data = JSON.parse(String(r.body))
    players = data["elements"]
    
    mikkel_team_dict = Dict(
        "BHA" => "BRI",
        "CRY" => "CPL",
        "NFO" => "NOT",
        "SOU" => "SOT",
        "WHU" => "WHM",
        "SHU" => "SHE"
    )
    
    teams = data["teams"]
    for t in teams
        t["mikkel_short"] = get(mikkel_team_dict, t["short_name"], t["short_name"])
    end

    df[!, "BCV_clean"] = replace.(string.(df[!, "BCV"]), r"\((.*)\)" => s"-\\1")
    df[!, "BCV_numeric"] = tryparse.(Int, df[!, "BCV_clean"])
    # drop -1 BCV
    df = df[df[!, "BCV_numeric"] .!= -1, :]
    df_cleaned = df[.!(df[!, "Player"] .== "0" .| ismissing.(df[!, "No."]) .| ismissing.(df[!, "BCV_numeric"])), :]
    df_cleaned[!, "Clean_Name"] = fix_name_dialect.(df_cleaned[!, "Player"])
    mikkel_team_fix = Dict("WHU" => "WHM", "SHU" => "SHE")
    df_cleaned[!, "Team"] = replace.(df_cleaned[!, "Team"], mikkel_team_fix)
    df_cleaned[!, "Position"] = replace.(df_cleaned[!, "Position"], "GK" => "G")

    # Drop players without team name
    dropmissing!(df_cleaned, :Team)

    element_type_dict = Dict(1 => 'G', 2 => 'D', 3 => 'M', 4 => 'F')
    team_code_dict = Dict(i["code"] => i for i in teams)

    player_names = [Dict(
        "id" => e["id"],
        "web_name" => e["web_name"],
        "combined" => e["first_name"] * " " * e["second_name"],
        "team" => team_code_dict[e["team_code"]]["mikkel_short"],
        "position" => element_type_dict[e["element_type"]]
    ) for e in players]

    for target in player_names
        target["wn"] = fix_name_dialect(target["web_name"])
        target["cn"] = fix_name_dialect(target["combined"])
    end

    entries = []
    for player in eachrow(df_cleaned)
        possible_matches = [i for i in player_names if i["team"] == player.Team && i["position"] == player.Position]
        for target in possible_matches
            p = player.Clean_Name
            target["wn_score"] = token_set_ratio(p, target["wn"]) 
            target["cn_score"] = token_set_ratio(p, target["cn"])
        end

        best_match = maximum(possible_matches, key=get_best_score)
        push!(entries, merge(Dict("player_input" => player.Player, "team_input" => player.Team, "position_input" => player.Position), best_match))
    end

    entries_df = DataFrame(entries)
    entries_df[!, "score"] = maximum.(entries_df[!, ["wn_score", "cn_score"]], dims=2)
    entries_df[!, "name_team"] = entries_df[!, "player_input"] .* " @ " .* entries_df[!, "team_input"]
    entry_dict = Dict(entries_df.name_team .=> entries_df.id)
    fpl_name_dict = Dict(entries_df.id .=> entries_df.web_name)
    score_dict = Dict(entries_df.name_team .=> entries_df.score)
    df_cleaned[!, "name_team"] = df_cleaned[!, "Player"] .* " @ " .* df_cleaned[!, "Team"]
    df_cleaned[!, "FPL ID"] = getindex.(Ref(entry_dict), df_cleaned[!, "name_team"])
    df_cleaned[!, "fpl_name"] = getindex.(Ref(fpl_name_dict), df_cleaned[!, "FPL ID"])
    df_cleaned[!, "score"] = getindex.(Ref(score_dict), df_cleaned[!, "name_team"])

    # Check for duplicate IDs
    duplicate_rows = df_cleaned[!, "FPL ID"] .∈ unique(df_cleaned[df_cleaned.duplicated("FPL ID"), "FPL ID"])
    if nrow(df_cleaned[duplicate_rows, :]) > 0
        println("WARNING: There are players with duplicate IDs, lowest name match accuracy (score) will be dropped")
        println(first(df_cleaned[duplicate_rows, ["Player", "fpl_name", "score"]], 5))
    end
    sort!(df_cleaned, :score, rev=true)
    unique!(df_cleaned, :["FPL ID"])
    sort!(df_cleaned)

    println(size(df, 1), " ", size(df_cleaned, 1))

    existing_ids = df_cleaned[!, "FPL ID"]
    missing_players = DataFrame()
    for p in players
        if p["id"] in existing_ids
            continue
        end
        push!(missing_players, Dict(
            "Position" => element_type_dict[p["element_type"]],
            "Player" => p["web_name"],
            "Price" => p["now_cost"] / 10,
            "FPL ID" => p["id"],
            "Weighted minutes" => 0,
            "Missing" => 1
        ))
    end

    df_full = vcat(df_cleaned, missing_players)


    return df_full
end
    
function convert_mikkel_to_review(target)
    raw_data = fix_mikkel(target)

    static_url = "https://fantasy.premierleague.com/api/bootstrap-static/"
    r = HTTP.get(static_url)
    r_json = JSON.parse(String(r.body))
    teams = r_json["teams"]

    rename!(raw_data, strip.(names(raw_data)))

    raw_data[!, "Price"] .= coalesce.(parse.(Float64, raw_data[!, "Price"]), NaN)
    df_clean = raw_data[raw_data[!, "Price"] .< 20, :]
    df_clean[!, "Weighted minutes"] .= coalesce.(df_clean[!, "Weighted minutes"], "90")
    df_clean[!, "review_id"] = Int.(df_clean[!, "FPL ID"])

    pos_fix = Dict("GK" => "G")
    df_clean[!, "Pos"] .= df_clean[!, "Position"]
    df_clean[!, "Pos"] .= get.(pos_fix, df_clean[!, "Pos"], df_clean[!, "Pos"])

    df_clean[df_clean[!, "Pos"] .∈ ["G", "D"], "Weighted minutes"] .= "90"

    gws = []
    for i in names(df_clean)
        if occursin(r"^\d+$", i)
            push!(gws, i)
            df_clean[!, "$i_Pts"] = coalesce.(parse.(Float64, replace.(strip.(df_clean[!, i]), "-" => "0")), NaN)
            df_clean[!, "$i_xMins"] = coalesce.(parse.(Float64, replace.(strip.(df_clean[!, "Weighted minutes"]), "-" => "0")), NaN)
        end
    end

    df_clean[!, "Name"] .= df_clean[!, "Player"]
    df_clean[!, "Value"] .= df_clean[!, "Price"]

    df_final = df_clean[:, ["review_id", "Name", "Pos", "Value", [string(gw, "_", tag) for gw in gws for tag in ["Pts", "xMins"]]...]]
    df_final[!, "Name"] .= get.(player_names, df_final[!, "review_id"], df_final[!, "Name"])

    player_ids = [x["id"] for x in r_json["elements"]]
    player_names = Dict(x["id"] => x["web_name"] for x in r_json["elements"])
    player_pos = Dict(x["id"] => x["element_type"] for x in r_json["elements"])
    player_price = Dict(x["id"] => x["now_cost"]/10 for x in r_json["elements"])
    pos_no = Dict(1 => "G", 2 => "D", 3 => "M", 4 => "F")

    values = []
    existing_players = df_final[!, "review_id"]
    for i in player_ids
        if !(i in existing_players)
            entry = Dict("review_id" => i, "Name" => player_names[i], "Pos" => pos_no[player_pos[i]], "Value" => player_price[i], [string(gw, "_", tag) => 0 for gw in gws for tag in ["Pts", "xMins"]]...)
            push!(values, entry)
        end
    end

    team_dict = Dict(i["code"] => i["name"] for i in teams)
    player_teams = Dict(i["id"] => team_dict[i["team_code"]] for i in r_json["elements"])
    df_final[!, "Team"] = get.(player_teams, df_final[!, "review_id"], "")
    df_final[!, "fpl_id"] = df_final[!, "review_id"]
    df_final[!, "Name"] = get.(player_names, df_final[!, "review_id"], df_final[!, "Name"])

    CSV.write("../data/mikkel.csv", df_final)
end


function rename_kiwi_columns(review_data::DataFrame)
    # Rename column headers if the projections are from FPL Kiwi
    new_colnames = String[]
    for col_name in names(review_data)
        if occursin(' ', col_name)
            kiwi_category = split(col_name, ' ')[1]
            if kiwi_category == "xMin"
                kiwi_category = "xMins"
            elseif kiwi_category == "xPts"
                kiwi_category = "Pts"
            end
            kiwi_week = split(col_name, ' ')[2]
            push!(new_colnames, "$(kiwi_week)_$(kiwi_category)")
        else
            push!(new_colnames, col_name)
        end
    end
    rename!(review_data, Symbol.(new_colnames))
    return review_data
end

function get_kiwi_review_avg(gw::Int, review_data::DataFrame, kiwi_data::DataFrame)
    # Join the DataFrames on the 'ID' column
    joined = innerjoin(kiwi_data, review_data, on = :ID, makeunique=true)

    fplrev_gws = gw:min(39, gw+5)
    for current_gw in fplrev_gws
        xpts_col = "xPts $current_gw"
        # Check if the current GW data is present in kiwi_data
        if hasproperty(kiwi_data, Symbol(xpts_col))
            joined[:"$current_gw avg pts"] = (joined[Symbol("xPts $current_gw")] + joined[Symbol("$current_gw_Pts")]) / 2
            joined[:"$current_gw avg mins"] = (joined[Symbol("xMin $current_gw")] + joined[Symbol("$current_gw_xMins")]) / 2
        else
            joined[:"$current_gw avg pts"] = joined[Symbol("$current_gw_Pts")]
            joined[:"$current_gw avg mins"] = joined[Symbol("$current_gw_xMins")]
        end
    end

    # Define the columns to keep in the final DataFrame
    cols = [:Pos_rev, :ID_rev, :Name_rev, :BV, :SV, :Team_rev]
    append!(cols, sort(vcat(["$gw avg pts" for gw in fplrev_gws], ["$gw avg mins" for gw in fplrev_gws])))

    new_df = select(joined, Symbol.(cols))
    rename!(new_df, names(review_data))

    return new_df
end