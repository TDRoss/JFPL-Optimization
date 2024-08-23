# JFPL Optimization

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

This is an algorithm for selecting/planning Fantasy Premier League picks using mathematical optimization.

The code is a Julia implementation of a [Python FPL optimization repository](https://github.com/sertalpbilal/FPL-Optimization-Tools)

The algorithm relies on [JuMP](https://github.com/jump-dev/JuMP.jl) to easily swap between different solvers.

## Installation

- Clone the repository
```shell
git clone https://github.com/TDRoss/JFPL-Optimization JFPL-Optimization
```
- Navigate to the run directory
```shell
cd JFPL-Optimization/run
```
- Launch Julia then enter the package REPL mode by pressing \']\'. Activate the project environment
```julia
activate .
```
(Note that on Windows launching Julia may start in your home directory. Check with `pwd()`. You may need to navigate back to `JFPL-Optimization/run` using `cd()`)

- Install dependencies (this can take a while)
```julia
instantiate
```

- Download FPLReview projections and save it in the directory `/data` and rename the projections file to `fplreview.csv`

- Log in FPL from your browser and open
  https://fantasy.premierleague.com/api/my-team/MY_TEAM_ID/
  after replacing `MY_TEAM_ID` with your team id.
  Copy the content of the page into `data/team.json` file, by creating one.

Note: the HiGHS (default) and CBC solvers are installed with this project. If you would like to try other solvers, please see the JuMP [documentation](https://jump.dev/JuMP.jl/stable/packages/solvers/) on what is available and their installation dependencies.


## Instructions

### Multi-period GW optimization


- Edit content of `data/regular_settings.json` file

  ``` json
	{
	    "horizon": 8,
	    "decay_base": 0.84,
	    "ft_value": 0.8,
	    "ft_use_penalty": 1,
	    "itb_value": 0.08,
	    "itb_loss_per_transfer": 0,
	    "no_future_transfer": false,
	    "no_transfer_last_gws": null,
	    "have_2ft_in_gws": [],
	    "randomized": false,
	    "xmin_lb": 2,
	    "ev_per_price_cutoff": 20,
      "banned": [],
      "banned_next_gw": [],
      "locked": [],
      "locked_next_gw": [],
	    "single_solve": false,
      "forced_chip_gws": {"bb": [], "wc": [], "fh": [], "tc": []},
      "run_chip_combinations": {"bb": [], "wc": [], "fh": [], "tc": []},
	    "num_transfers": null,
	    "hit_limit": null,
      "hit_cost": 4,
      "ft_custom_value": null,
	    "use_wc": null,
	    "use_bb": null,
	    "use_fh": null,
	    "chip_limits": {"bb": 0, "wc": 0, "fh": 0, "tc": 0},
	    "no_chip_gws": [],
	    "allowed_chip_gws": {"bb": [], "wc": [], "fh": [], "tc": []},
	    "future_transfer_limit": null,
	    "no_transfer_gws": [],
	    "booked_transfers": [],
	    "only_booked_transfers": false,
	    "no_trs_except_wc": false,
	    "preseason": false,
	    "no_opposing_play": false,
	    "pick_prices": {"G": "", "D": "", "M": "", "F": ""},
	    "no_gk_rotation_after": null,
	    "iteration": 1,
	    "iteration_criteria": "this_gw_transfer_in",
	    "iteration_target": [],
      "report_decay_base": [0.85, 0.9, 0.95, 1.0, 1.017],
	    "datasource" : "review",
	    "data_weights": {"review": 40, "review-odds": 30, "mikkel": 30, "kiwi": 0},
	    "export_data": "final.csv",
	    "team_data": "json",
	    "team_id": null
	}
  ```

  - `horizon`: length of planning horizon
  - `decay_base`: value assigned to decay rate of expected points
  - `ft_value`: value assigned to the extra free transfer
  - `ft_use_penalty`: penalty on objective function when an FT is used
  - `itb_value`: value assigned to having 1.0 extra budget
  - `itb_loss_per_transfer`: reduction in ITB amount per scheduled transfers in future
  - `no_future_transfer`: `true` or `false` whether you want to plan future transfers or not
  - `no_transfer_last_gws`: the number of gws at the end of the period you want to ban transfers
  - `have_2ft_in_gws`: list of GWs where you want to have 2 FTs, for example  
    `"have_2ft_in_gws":[38]` will force solver to have 2 FTs at the beginning of GW38
  - `randomized`: `true` or `false` whether you would like to add random noise to EV
  - `xmin_lb`: cut-off for dropping players below this many minutes expectation
  - `ev_per_price_cutoff`: cut-off percentile for dropping players based on total EV per price (e.g. `20` means drop players below 20% percentile)
  - `bench_weights`: percentage weights in objective for bench players (gk and 3 outfield). Example: {"0":0.01,"1":0.3,"2":0.1,"3":0.05},
  - `banned`: list of player IDs to be banned over the entire horizon
  - `banned_next_gw`: list of player IDs to be banned for the next gameweek. Alternatively, you can supply an `[ID, gameweek]` list as an element of the list to ban a player just for one specific gameweek. E.g. `[100, [200, 32]]` bans player with ID 100 for the next gameweek, and bans player with ID 200 for gameweek 32
  - `locked`: list of player IDs to always have during the horizon (e.g. `233` for Salah)
  - `locked_next_gw`: List of player IDs to force just for the next gameweek. See `banned_next_gw` for extended usage
  - `future_transfer_limit`: upper bound how many transfers are allowed in future GWs
  - `no_transfer_gws`: list of GW numbers where transfers are not allowed
  - `booked_transfers`: list of booked transfers for future gameweeks, needs to have a `gw` key and at least one of `transfer_in` or `transfer_out` with the player ID. For example, to book a transfer of buying Kane (427) on GW5 and selling him on GW7, use  
    `"booked_transfers": [{"gw": 5, "transfer_in": 427}, {"gw": 7, "transfer_out": 427}]`
  - `only_booked_transfers`: (for next GW) use only booked transfers
  - `use_wc`: GW to use wildcard (fixed)
  - `use_bb`: GW to use bench boost (fixed)
  - `use_fh`: GW to use free hit (fixed)
  - `use_tc`: GW to use triple captain (fixed)
  - `chip_limits`: how many chips of each kind can be used by solver (you need to set it to at least 1 when force using a chip)
  - `no_chip_gws`: list of GWs to ban solver from using a chip
  - `allowed_chip_gws`: dictionary of list of GWs to allow chips to be used. For example  
    `"allowed_chip_gws": {"wc": [27,31]}`  
    will allow solver to use WC in GW27 and GW31, but not in another GW
  - `forced_chip_gws`: dictionary of list of GWs to force chips to be used. Instead of 'allowing' chips, it makes sure that chips are used
  - `run_chip_combinations`: generates a list of chip combinations to be tried one-by-one, instead of leaving to the solver  
  - `num_transfers`: fixed number of transfers for this GW
  - `hit_limit`: limit on total hits can be taken by the solver for entire horizon
  - `hit_cost`: cost of a hit, 4 points by default but can be overriden to reduce hits suggested
  - `ft_custom_value`: value of keeping your 2nd free transfer before a GW. For example  
    `"ft_custom_value": {"35": 2, "38": 0.5}`  
    will set value of 2nd FT for GW35 to 2 EV, and for GW38 to 0.5 EV
  - `preseason`: solve flag for GW1 where team data is not important
  - `no_trs_except_wc`: when `true` prevents solver to make transfers except using wildcard
  - `no_opposing_play`: `true` if you do not want to have players in your lineup playing against each other in a GW
  - `opposing_play_group`: `all` if you do not want any type of opposing players or `position` if you only don't want your offense playing against your defense
  - `pick_prices`: price points of players you want to force in a comma separated string
    For example, to force two 11.5M forwards, and one 8M midfielder, use
    `"pick_prices": {"G": "", "D": "", "M": "8", "F": "11.5,11.5"}`
  - `no_gk_rotation_after`: use same lineup GK after given GW, e.g. setting this value to `26` means all GWs after 26 will use same lineup GK
  - `iteration`: number of different solutions to be generated, the criteria is controlled by `iteration_criteria`
  - `iteration_criteria`: rule on separating what a different solution mean  
    - `this_gw_transfer_in` will force to replace players to buy current GW in each solution
    - `this_gw_transfer_out` will force to replace players to sell current GW in each solution
    - `this_gw_transfer_in_out` will force to replace players to buy or sell current GW in each solution
    - `chip_gws` will force to replace GWs where each chip is being used
    - `target_gws_transfer_in` will force to replace players to buy in target GW (provided by `iteration_target` parameter)
    - `this_gw_lineup` will force to replace at least N players in your lineup
    - `iteration_difference`: number of players to be different (only available for `this_gw_lineup` criteria for now)
  - `iteration_target`: list of GWs where plans will be forced to replace in each iteration
  - `report_decay_base`: list of decay bases to be measured and reported at the end of the solve 
  - `datasource` : `review`, `kiwi`, `mikkel` or `avg` specifies the data to be used.  
    - `review` requires `fplreview.csv` file
    - `review-odds` requires `fplreview-odds.csv` file
    - `kiwi` requires `kiwi.csv` file
    - `mikkel` requires `TransferAlgorithm.csv`, file
    - `mixed` requires an additional parameter `data_weights`, and any corresponding files mentioned above
  
    under `data` folder to be present
  - `data_weights`: weight percentage for each data source, given as a dictionary, where keys should be one of valid data sources
  - `export_data`: option for exporting final data as a CSV file (when using `mixed` data)
  - `team_data`: option for using `team_id` value rather than the `team.json` file. Uses `team.json` by default, set value to `ID` to use `team_id`. Note that with this method, any transfers already made this gameweek won't be taken into account, so they must be added to `booked_transfers`
  - `team_id`: the team_id to optimise for. Requires `team_data` to be set to `ID`

- Run the multi-period optimization
From the bash command line in the `/run` directory
	``` shell
	julia --project=.  solve_regular.jl
	```

- Find the optimal plans under `/data/results` directory with timestamp

## Sensitivity Analysis

If you want to run sensitivity analysis:

0\. Make sure that `/data/results` directory is empty (doesn't include old files)

1\. Go to the `/run` directory and enter:

```shell
julia --project=. simulations.jl
```

When called from the terminal, it will ask you to give the number of runs (how many times you want to solve) and the number of parallel jobs. If you are not sure, use 1 for parallel jobs.

You can also pass parameters from the command line as:

  ```shell
  julia --project=. simulations.jl --no 10 --parallel 4
  ```

2\. After optimizations are completed, run:

  ``` shell
  julia --project=. sensitivity.jl
  ```

  to get a summary of results.

  Similarly, you can give gameweek and wildcard parameters from the command line, such as

  ``` shell
  julia --project=. sensitivity.jl --gw 1 --wildcard Y
  ``` 

# License

[Apache-2.0 License](LICENSE)
